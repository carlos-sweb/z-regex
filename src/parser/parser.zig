//! Recursive descent parser for regex patterns
//!
//! This module implements a parser that converts tokens from the lexer
//! into an Abstract Syntax Tree (AST).
//!
//! Grammar (precedence from lowest to highest):
//!   pattern      ::= alternation
//!   alternation  ::= sequence ('|' sequence)*
//!   sequence     ::= term*
//!   term         ::= atom quantifier?
//!   quantifier   ::= '*' | '+' | '?' | '{' n (',' m?)? '}'
//!   atom         ::= char | '.' | group | charclass | anchor | escape
//!   group        ::= '(' pattern ')'
//!   charclass    ::= '[' '^'? charclass_item+ ']'
//!   charclass_item ::= char | char '-' char
//!   anchor       ::= '^' | '$' | '\b' | '\B'

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer_mod = @import("lexer.zig");
const ast_mod = @import("ast.zig");
const properties = @import("../unicode/properties.zig");

const Lexer = lexer_mod.Lexer;
const Token = lexer_mod.Token;
const TokenType = lexer_mod.TokenType;
const Node = ast_mod.Node;
const NodeType = ast_mod.NodeType;

/// Byte ranges (inclusive, ASCII-only -- see KNOWN_LIMITATIONS.md) making up
/// the shorthand character classes. Shared between standalone usage (e.g.
/// bare `\d`) and splicing a shorthand into an enclosing `[...]` (e.g.
/// `[a-c\d]`), so both stay consistent with each other.
const DIGIT_RANGES = [_][2]u8{.{ '0', '9' }};
const WORD_RANGES = [_][2]u8{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } };
/// \t \n \v \f \r (0x09-0x0D) and space. (JS's \s also matches several
/// non-ASCII Unicode space characters; not implemented here.)
const WHITESPACE_RANGES = [_][2]u8{ .{ 0x09, 0x0D }, .{ 0x20, 0x20 } };

/// Complement (within byte range 0-255) of a sorted, non-overlapping list of
/// inclusive ranges. `out` must have at least `ranges.len + 1` slots.
fn complementByteRanges(ranges: []const [2]u8, out: [][2]u8) [][2]u8 {
    var count: usize = 0;
    var next: u16 = 0;
    for (ranges) |r| {
        if (@as(u16, r[0]) > next) {
            out[count] = .{ @intCast(next), @intCast(r[0] - 1) };
            count += 1;
        }
        next = @max(next, @as(u16, r[1]) + 1);
    }
    if (next <= 255) {
        out[count] = .{ @intCast(next), 255 };
        count += 1;
    }
    return out[0..count];
}

/// Parse error with position information
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEOF,
    UnmatchedParen,
    UnmatchedBracket,
    InvalidCharRange,
    EmptyCharClass,
    InvalidQuantifier,
    EmptyGroup,
    EmptyAlternation,
    OutOfMemory,
    // Named capture groups
    DuplicateGroupName,
    UnknownGroupName,
    AlternationTooDeep,
    // Lexer errors
    InvalidEscape,
    InvalidRepeat,
    UnterminatedRepeat,
    InvalidGroupName,
    // Unicode property escapes (\p{...}/\P{...})
    UnknownUnicodeProperty,
    // `v`-mode (Unicode Sets) class set operations (`[A--B]` / `[A&&B]`)
    InvalidClassSetOperand,
    ChainedClassSetOperatorNotSupported,
};

/// A named capturing group's name and numeric group index, in the order the
/// names were encountered while parsing.
/// Maximum nesting depth of alternations (`|` inside `|` inside a group
/// inside `|`, ...) this parser's mutual-exclusion tracking supports for
/// duplicate named groups -- see `BranchStep`. A fixed cap keeps
/// `Parser`/`GroupNameEntry` allocation-free for this feature (like
/// `MAX_CLASS_RANGES` elsewhere in this codebase) instead of needing a heap
/// allocation (and therefore `Parser.deinit()`) for every pattern that goes
/// through `parseAlternation` at all -- i.e. every pattern, not just ones
/// with named groups. 32 levels of *nested* alternation (not a flat `a|b|c`
/// chain, which is one level regardless of branch count) is far beyond any
/// realistic pattern; exceeding it is `error.AlternationTooDeep`.
pub const MAX_ALTERNATION_DEPTH = 32;

pub const GroupNameEntry = struct {
    name: []const u8,
    index: u8,
    /// Snapshot of `Parser.branch_stack` at the moment this named group was
    /// created, outermost-first, `branch_path[0..branch_path_len]` valid.
    /// Used only to decide whether a *later* same-named group is allowed
    /// (JS permits duplicate names when every occurrence is in a mutually
    /// exclusive alternation branch).
    branch_path: [MAX_ALTERNATION_DEPTH]BranchStep = undefined,
    branch_path_len: usize = 0,
};

/// One step of a named group's position relative to the alternation
/// (`|`) nodes enclosing it: `alt_id` identifies a specific `parseAlternation`
/// call (every call gets a fresh id, whether or not it turns out to contain a
/// real `|`), and `branch_index` is which branch (0-based, left-to-right)
/// of that call's disjunction the group is inside. See
/// `branchPathsMutuallyExclusive` for how two groups' full paths are compared.
pub const BranchStep = struct { alt_id: u32, branch_index: u32 };

/// Whether two named groups' branch paths prove they can never both
/// participate in the same match -- i.e. JS's exception to "duplicate group
/// names are a SyntaxError": allowed when every duplicate occurs in a
/// different branch of some shared enclosing alternation. Walks both paths
/// outermost-first; the first point where they name the *same* alternation
/// (`alt_id`) but a *different* branch is a shared disjunction the two
/// groups take different arms of, which is sufficient on its own (whatever
/// either path does afterward is irrelevant, since that ancestor split
/// already guarantees only one side ever executes). If the paths never
/// diverge that way -- one is a prefix of the other, or they're identical,
/// or they diverge at *different* `alt_id`s (which, given how `branch_stack`
/// is built, means there's no shared alternation ancestor at all) -- the two
/// groups can coexist, so it's a conflict.
fn branchPathsMutuallyExclusive(a: []const BranchStep, b: []const BranchStep) bool {
    const min_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        if (a[i].alt_id != b[i].alt_id) return false;
        if (a[i].branch_index != b[i].branch_index) return true;
    }
    return false;
}

/// Parser for regex patterns
pub const Parser = struct {
    allocator: Allocator,
    lexer: *Lexer,
    current_token: Token,
    group_counter: u8,
    /// Names are slices into the original pattern (borrowed, valid only for
    /// the lifetime of the pattern passed to the lexer); callers that need
    /// them to outlive the parser must copy them (see `codegen/compiler.zig`).
    group_names: std.ArrayListUnmanaged(GroupNameEntry) = .empty,
    /// Live stack of the alternation branches currently being parsed --
    /// pushed/popped by `parseAlternation`, `branch_stack[0..branch_stack_len]`
    /// valid, snapshotted into a `GroupNameEntry.branch_path` whenever a
    /// named group is created. See `BranchStep`/`branchPathsMutuallyExclusive`.
    branch_stack: [MAX_ALTERNATION_DEPTH]BranchStep = undefined,
    branch_stack_len: usize = 0,
    /// Next fresh id to hand out to a `parseAlternation` call (see
    /// `BranchStep`). Every call gets one, whether or not it turns out to
    /// contain a real `|` -- see `branchPathsMutuallyExclusive`'s doc
    /// comment for why that's actually required for correctness, not just
    /// simplicity: two groups that share no real alternation ancestor must
    /// always disagree on `alt_id` the first time their paths diverge, and
    /// giving every call a globally unique id is what guarantees that.
    next_alt_id: u32 = 0,

    const Self = @This();

    /// Initialize a new parser
    pub fn init(allocator: Allocator, lexer: *Lexer) !Self {
        var self = Self{
            .allocator = allocator,
            .lexer = lexer,
            .current_token = undefined,
            .group_counter = 0,
        };
        // Prime the parser with the first token
        try self.advance();
        return self;
    }

    /// Free internal bookkeeping state (not the AST, which has its own
    /// `deinit`, and not the pattern-borrowed name strings).
    pub fn deinit(self: *Self) void {
        self.group_names.deinit(self.allocator);
    }

    /// Parse a complete regex pattern
    pub fn parse(self: *Self) !*Node {
        const root = try self.parseAlternation();

        // Ensure we consumed all tokens
        if (self.current_token.type != .eof) {
            root.deinit();
            return error.UnexpectedToken;
        }

        return root;
    }

    /// Advance to the next token
    fn advance(self: *Self) !void {
        self.current_token = try self.lexer.next();
    }

    /// Check if current token matches expected type
    fn check(self: Self, token_type: TokenType) bool {
        return self.current_token.type == token_type;
    }

    /// Consume token if it matches, otherwise error
    fn consume(self: *Self, token_type: TokenType) !Token {
        if (!self.check(token_type)) {
            return error.UnexpectedToken;
        }
        const token = self.current_token;
        try self.advance();
        return token;
    }

    /// Match and consume if token matches
    fn match(self: *Self, token_type: TokenType) !bool {
        if (self.check(token_type)) {
            try self.advance();
            return true;
        }
        return false;
    }

    // =========================================================================
    // Grammar Rules (Top-Down by Precedence)
    // =========================================================================

    /// Parse alternation: sequence ('|' sequence)*
    ///
    /// Every call reserves a fresh `alt_id` and pushes `(alt_id,
    /// branch_index)` onto `self.branch_stack` for the duration of parsing
    /// each branch (`left`, `right`, and each subsequent `next` in the
    /// `a|b|c|...` loop, 0-based left-to-right) -- whether or not a `|`
    /// actually follows, since a named group needs the id reserved even for
    /// a single-branch "alternation" to correctly conflict with a
    /// same-named group elsewhere that has no shared alternation ancestor
    /// at all (see `branchPathsMutuallyExclusive`). A named group created
    /// while a branch is being parsed snapshots the live stack at that
    /// moment into its `GroupNameEntry.branch_path`.
    fn parseAlternation(self: *Self) ParseError!*Node {
        const alt_id = self.next_alt_id;
        self.next_alt_id += 1;

        try self.pushBranch(alt_id, 0);
        var left = try self.parseSequence();
        self.popBranch();
        errdefer left.deinit();

        if (self.check(.pipe)) {
            // We have alternation
            try self.advance(); // consume '|'

            try self.pushBranch(alt_id, 1);
            var right = try self.parseSequence();
            self.popBranch();
            errdefer right.deinit();

            var alt = try Node.createAlternation(self.allocator, left, right);

            // Handle multiple alternations: a|b|c -> (a|(b|c))
            var branch_index: u32 = 2;
            while (self.check(.pipe)) {
                try self.advance(); // consume '|'

                try self.pushBranch(alt_id, branch_index);
                const next = try self.parseSequence();
                self.popBranch();
                errdefer next.deinit();
                branch_index += 1;

                alt = try Node.createAlternation(self.allocator, alt, next);
            }

            return alt;
        }

        return left;
    }

    /// Push one `BranchStep` onto `self.branch_stack`. See `parseAlternation`.
    fn pushBranch(self: *Self, alt_id: u32, branch_index: u32) !void {
        if (self.branch_stack_len >= MAX_ALTERNATION_DEPTH) return error.AlternationTooDeep;
        self.branch_stack[self.branch_stack_len] = .{ .alt_id = alt_id, .branch_index = branch_index };
        self.branch_stack_len += 1;
    }

    /// Pop the top of `self.branch_stack`. See `parseAlternation`.
    fn popBranch(self: *Self) void {
        self.branch_stack_len -= 1;
    }

    /// Parse sequence: term*
    fn parseSequence(self: *Self) ParseError!*Node {
        var seq = try Node.createSequence(self.allocator);
        errdefer seq.deinit();

        while (true) {
            // Check for sequence terminators
            if (self.check(.pipe) or self.check(.rparen) or self.check(.eof)) {
                break;
            }

            const term = try self.parseTerm();
            errdefer term.deinit();

            try seq.appendChild(term);
        }

        // If sequence has only one child, return the child directly
        if (seq.children.items.len == 1) {
            const child = seq.children.items[0];
            seq.children.clearRetainingCapacity();
            seq.deinit();
            return child;
        }

        // Empty sequence is valid (matches empty string)
        return seq;
    }

    /// Parse term: atom quantifier?
    fn parseTerm(self: *Self) ParseError!*Node {
        const atom = try self.parseAtom();
        errdefer atom.deinit();

        // Check for quantifier (greedy)
        if (self.check(.star)) {
            try self.advance();
            return Node.createQuantifier(self.allocator, .star, atom);
        } else if (self.check(.plus)) {
            try self.advance();
            return Node.createQuantifier(self.allocator, .plus, atom);
        } else if (self.check(.question)) {
            try self.advance();
            return Node.createQuantifier(self.allocator, .question, atom);
        } else if (self.check(.repeat)) {
            const token = self.current_token;
            if (token.repeat_min > token.repeat_max) {
                return error.InvalidQuantifier;
            }
            try self.advance();
            // Check if followed by '?' for lazy quantifier
            if (self.check(.question)) {
                try self.advance();
                return Node.createLazyRepeat(self.allocator, atom, token.repeat_min, token.repeat_max);
            }
            return Node.createRepeat(self.allocator, atom, token.repeat_min, token.repeat_max);
        }
        // Check for lazy quantifiers
        else if (self.check(.lazy_star)) {
            try self.advance();
            return Node.createQuantifier(self.allocator, .lazy_star, atom);
        } else if (self.check(.lazy_plus)) {
            try self.advance();
            return Node.createQuantifier(self.allocator, .lazy_plus, atom);
        } else if (self.check(.lazy_question)) {
            try self.advance();
            return Node.createQuantifier(self.allocator, .lazy_question, atom);
        }
        // Check for possessive quantifiers
        else if (self.check(.possessive_star)) {
            try self.advance();
            return Node.createQuantifier(self.allocator, .possessive_star, atom);
        } else if (self.check(.possessive_plus)) {
            try self.advance();
            return Node.createQuantifier(self.allocator, .possessive_plus, atom);
        } else if (self.check(.possessive_question)) {
            try self.advance();
            return Node.createQuantifier(self.allocator, .possessive_question, atom);
        }

        return atom;
    }

    /// Parse atom: char | '.' | group | charclass | anchor | escape
    fn parseAtom(self: *Self) ParseError!*Node {
        switch (self.current_token.type) {
            // Simple character
            .char => {
                const c = self.current_token.char_value;
                try self.advance();
                return Node.createChar(self.allocator, c);
            },

            // Escaped character
            .escaped_char => {
                const c = self.current_token.char_value;
                try self.advance();
                return Node.createChar(self.allocator, c);
            },

            // Escaped multi-byte code point (e.g. \u{1F600}): a sequence of
            // literal byte nodes, so the whole code point is quantified as a
            // single atomic unit (e.g. `\u{1F600}+` repeats all 4 bytes together).
            // `seq.char_value` is also set to the decoded code point -- an
            // ordinary multi-atom sequence (`"ab"`) never sets `char_value`
            // (it keeps the zero default), so `generateSequence` uses this as
            // an unambiguous "this sequence is one atomic multi-byte
            // character" marker, e.g. to look up its case-fold pair for
            // `case_insensitive` matching (see `generator.zig`).
            .multibyte_char => {
                const bytes = self.current_token.byte_seq;
                const len = self.current_token.byte_seq_len;
                try self.advance();
                if (len == 1) {
                    return Node.createChar(self.allocator, bytes[0]);
                }
                const seq = try Node.createSequence(self.allocator);
                errdefer seq.deinit();
                for (bytes[0..len]) |b| {
                    try seq.appendChild(try Node.createChar(self.allocator, b));
                }
                // The lexer only ever produces multibyte_char tokens after
                // successfully decoding them, so this can't fail here.
                seq.char_value = std.unicode.utf8Decode(bytes[0..len]) catch unreachable;
                return seq;
            },

            // Dot (any character)
            .dot => {
                try self.advance();
                return Node.createDot(self.allocator);
            },

            // Character classes
            .digit => {
                try self.advance();
                // \d is equivalent to [0-9]
                return Node.createCharRange(self.allocator, DIGIT_RANGES[0][0], DIGIT_RANGES[0][1]);
            },

            .word => {
                try self.advance();
                // \w is [a-zA-Z0-9_]
                return self.createRangesClassNode(&WORD_RANGES, false);
            },

            .whitespace => {
                try self.advance();
                // \s is [ \t\n\v\f\r]
                return self.createRangesClassNode(&WHITESPACE_RANGES, false);
            },

            // Negated character classes
            .not_digit => {
                try self.advance();
                // \D is equivalent to [^0-9]
                const node = try Node.createCharRange(self.allocator, DIGIT_RANGES[0][0], DIGIT_RANGES[0][1]);
                node.inverted = true;
                return node;
            },

            .not_word => {
                try self.advance();
                // \W is [^a-zA-Z0-9_]
                return self.createRangesClassNode(&WORD_RANGES, true);
            },

            .not_whitespace => {
                try self.advance();
                // \S is [^ \t\n\v\f\r]
                return self.createRangesClassNode(&WHITESPACE_RANGES, true);
            },

            // Unicode property escapes \p{Name} / \P{Name}
            .unicode_prop, .not_unicode_prop => {
                const name = self.lexer.pattern[self.current_token.name_start..self.current_token.name_end];
                const negated = self.current_token.type == .not_unicode_prop;
                try self.advance();
                return self.resolveUnicodePropertyNode(name, negated);
            },

            // Anchors
            .line_start => {
                try self.advance();
                return Node.createAnchor(self.allocator, .anchor_start);
            },

            .line_end => {
                try self.advance();
                return Node.createAnchor(self.allocator, .anchor_end);
            },

            .word_boundary => {
                try self.advance();
                return Node.createAnchor(self.allocator, .word_boundary);
            },

            .not_word_boundary => {
                try self.advance();
                return Node.createAnchor(self.allocator, .not_word_boundary);
            },

            // Groups
            .lparen => {
                try self.advance(); // consume '('

                self.group_counter += 1;
                const group_index = self.group_counter;

                const inner = try self.parseAlternation();
                errdefer inner.deinit();

                _ = try self.consume(.rparen);

                return Node.createGroup(self.allocator, inner, group_index);
            },

            // Named capturing group (?<name>...)
            .named_group_start => {
                const name = self.lexer.pattern[self.current_token.name_start..self.current_token.name_end];
                try self.advance(); // consume '(?<name>'

                // A duplicate name is only a SyntaxError if the two groups
                // *aren't* provably mutually exclusive (different branches
                // of a shared enclosing alternation) -- see
                // `branchPathsMutuallyExclusive`. `self.branch_stack[0..
                // self.branch_stack_len]` right now *is* this group's branch
                // path (its own content hasn't been parsed yet, so nothing
                // from inside it has pushed anything onto the stack).
                const current_path = self.branch_stack[0..self.branch_stack_len];
                for (self.group_names.items) |entry| {
                    if (std.mem.eql(u8, entry.name, name) and
                        !branchPathsMutuallyExclusive(entry.branch_path[0..entry.branch_path_len], current_path))
                    {
                        return error.DuplicateGroupName;
                    }
                }
                var new_entry = GroupNameEntry{ .name = name, .index = 0, .branch_path_len = current_path.len };
                @memcpy(new_entry.branch_path[0..current_path.len], current_path);

                self.group_counter += 1;
                const group_index = self.group_counter;
                new_entry.index = group_index;

                const inner = try self.parseAlternation();
                errdefer inner.deinit();

                _ = try self.consume(.rparen);

                try self.group_names.append(self.allocator, new_entry);

                return Node.createGroup(self.allocator, inner, group_index);
            },

            // Positive lookahead (?=...)
            .lookahead_start => {
                try self.advance(); // consume '(?='

                const inner = try self.parseAlternation();
                errdefer inner.deinit();

                _ = try self.consume(.rparen);

                return Node.createLookahead(self.allocator, inner, false);
            },

            // Negative lookahead (?!...)
            .negative_lookahead_start => {
                try self.advance(); // consume '(?!'

                const inner = try self.parseAlternation();
                errdefer inner.deinit();

                _ = try self.consume(.rparen);

                return Node.createLookahead(self.allocator, inner, true);
            },

            // Non-capturing group (?:...)
            .non_capturing_group_start => {
                try self.advance(); // consume '(?:'

                const inner = try self.parseAlternation();
                errdefer inner.deinit();

                _ = try self.consume(.rparen);

                // Note: We don't increment group_counter for non-capturing groups
                return Node.createNonCapturingGroup(self.allocator, inner);
            },

            // Positive lookbehind (?<=...)
            .lookbehind_start => {
                try self.advance(); // consume '(?<='

                const inner = try self.parseAlternation();
                errdefer inner.deinit();

                _ = try self.consume(.rparen);

                return Node.createLookbehind(self.allocator, inner, false);
            },

            // Negative lookbehind (?<!...)
            .negative_lookbehind_start => {
                try self.advance(); // consume '(?<!'

                const inner = try self.parseAlternation();
                errdefer inner.deinit();

                _ = try self.consume(.rparen);

                return Node.createLookbehind(self.allocator, inner, true);
            },

            // Character class
            .lbracket => {
                return self.parseCharClass();
            },

            // Literal '-'. The lexer always tokenizes '-' as .hyphen (it has
            // no notion of "inside a character class"); parseCharClass
            // handles it specially there, and outside a class it's just a
            // literal hyphen character.
            .hyphen => {
                try self.advance();
                return Node.createChar(self.allocator, '-');
            },

            // Backreference
            .back_ref => {
                const group = self.current_token.backref_group;
                try self.advance();
                return Node.createBackRef(self.allocator, group);
            },

            // Named backreference \k<name>
            .named_back_ref => {
                const name = self.lexer.pattern[self.current_token.name_start..self.current_token.name_end];
                try self.advance();

                for (self.group_names.items) |entry| {
                    if (std.mem.eql(u8, entry.name, name)) {
                        return Node.createBackRef(self.allocator, entry.index);
                    }
                }
                return error.UnknownGroupName;
            },

            else => {
                return error.UnexpectedToken;
            },
        }
    }

    /// Resolve a `\p{Name}`/`\P{Name}` escape's already-extracted `name` span
    /// to the right node type -- Script_Extensions (`Script_Extensions=`/
    /// `scx=` prefix), Script (`Script=`/`sc=` prefix), or General_Category /
    /// binary property (no recognized prefix, or a bare name). Shared by
    /// `parseAtom` (standalone `\p{...}`) and `parseCharClass` (`\p{...}` as
    /// a class member, e.g. `[\p{L}\d]`) so both stay in sync.
    fn resolveUnicodePropertyNode(self: *Self, name: []const u8, negated: bool) ParseError!*Node {
        if (properties.stripScriptExtensionsPrefix(name)) |script_name| {
            const idx = properties.resolveScript(script_name) orelse return error.UnknownUnicodeProperty;
            return Node.createUnicodeScriptExtensions(self.allocator, idx, negated);
        }

        if (properties.stripScriptPrefix(name)) |script_name| {
            const idx = properties.resolveScript(script_name) orelse return error.UnknownUnicodeProperty;
            return Node.createUnicodeScript(self.allocator, idx, negated);
        }

        const category = properties.resolveUnicodeProperty(name) orelse return error.UnknownUnicodeProperty;
        return Node.createUnicodeProperty(self.allocator, @intFromEnum(category), negated);
    }

    /// Parse character class: '[' '^'? charclass_item+ ']'
    ///
    /// The lexer has no built-in notion of "inside a class"; toggling
    /// `self.lexer.in_char_class` is entirely this function's
    /// responsibility. The token immediately following `[` is fetched by
    /// `consume(.lbracket)` while still in normal mode, so `^` is recognized
    /// as the negation marker (which `nextInClass` doesn't special-case). If
    /// that first token turns out not to be `^`, it was tokenized in the
    /// wrong mode (e.g. `*` would have come back as `.star` instead of a
    /// literal char) and must be re-fetched: rewind the lexer to that
    /// token's start position, switch modes, then advance again.
    fn parseCharClass(self: *Self) ParseError!*Node {
        // The token immediately after `[` is fetched by `consume(.lbracket)`
        // while still in normal (non-class) mode, purely to check whether
        // it's `^` -- if not, it's discarded and re-fetched in class mode
        // below (see the doc comment above). That speculative fetch must
        // not trip strict `unicode_mode` escape validation: some characters
        // (e.g. `-`) are a valid class-mode identity-escape but not a valid
        // normal-mode one, and an error here would abort before the
        // rewind-and-retry ever runs. The real, authoritative tokenization
        // happens after the rewind, with `unicode_mode` restored, so this
        // doesn't mask a genuinely invalid escape inside the class.
        const saved_unicode_mode = self.lexer.unicode_mode;
        self.lexer.unicode_mode = false;
        _ = try self.consume(.lbracket);
        self.lexer.unicode_mode = saved_unicode_mode;

        // Check for negation (^ at the start of character class)
        // Note: lexer tokenizes ^ as line_start, so we check for that
        var inverted = false;
        if (self.check(.line_start)) {
            inverted = true;
            self.lexer.in_char_class = true;
            try self.advance();
        } else {
            self.lexer.pos = self.current_token.position;
            self.lexer.in_char_class = true;
            try self.advance();
        }

        // `v`-mode only: the whole of operand1 is itself a nested bracketed
        // class (e.g. `[[a-z]&&[^x]]`) rather than a flat member list. Only
        // reachable when `v_mode` is on, since that's the only time `[`
        // tokenizes specially inside a class (see `nextInClass`) -- and
        // only when an operator actually follows, to keep this feature's
        // scope to exactly one operation (no bare `[[a-z]]` double-bracket
        // idiom, no chaining/deeper nesting; see `docs/KNOWN_LIMITATIONS.md`).
        if (self.lexer.v_mode and self.check(.lbracket)) {
            // `parseCharClass` always assumes it's entered with
            // `in_char_class` false, so its own `^`-negation lookahead (right
            // below this comment in the *nested* call) fetches the token
            // after `[` in normal mode -- without resetting it here first,
            // that lookahead would instead fetch via `nextInClass` (since
            // we're still logically inside this outer, already-open class),
            // which doesn't special-case `^` at all, silently losing a
            // nested `[^...]`'s negation.
            self.lexer.in_char_class = false;
            const nested = try self.parseCharClass();
            // No `errdefer nested.deinit()` here: `finishClassSetOp` takes
            // ownership immediately and has its own `errdefer` for it --
            // registering a second one here would double-free `nested` if
            // `finishClassSetOp` fails after its own cleanup already ran.

            // The nested call's own cleanup already fetched whatever
            // follows its `]` -- but in *normal* mode (same tradeoff as the
            // `^`-negation lookahead at the top of this function: the
            // nested call has no way to know it's still inside an outer,
            // still-open class body). Rewind and re-fetch in class mode so
            // `--`/`&&` tokenize correctly here rather than as literal
            // characters.
            self.lexer.pos = self.current_token.position;
            self.lexer.in_char_class = true;
            try self.advance();

            // No operator following a nested operand1 is out of this
            // feature's scope (no bare `[[a-z]]` double-bracket idiom) --
            // see `docs/KNOWN_LIMITATIONS.md`.
            if (!self.check(.class_minus_minus) and !self.check(.class_and_and)) {
                nested.deinit();
                return error.InvalidClassSetOperand;
            }
            return try self.finishClassSetOp(nested, inverted);
        }

        const class = try Node.createCharClass(self.allocator);
        // `class_owned` gates this errdefer off once ownership transfers to
        // `finishClassSetOp` below (which has its own `errdefer` for
        // whatever `left` it's given) -- otherwise both would fire on a
        // later failure there, double-freeing `class`.
        var class_owned = true;
        errdefer if (class_owned) class.deinit();
        class.inverted = inverted;

        while (!self.check(.rbracket) and !self.check(.eof) and
            !self.check(.class_minus_minus) and !self.check(.class_and_and))
        {
            if (self.isShorthandClassToken()) {
                // A shorthand class as a class member (e.g. `[a-c\d]`):
                // splice its members directly into the enclosing class. This
                // is correct under negation too, since JS defines a
                // character class as "union of ClassAtom sets, then apply
                // the outer negation" -- so a negated shorthand member
                // (`\D`/`\W`/`\S`) contributes its own complement, not a
                // second negation of the whole enclosing class.
                try self.appendShorthandToClass(class, self.current_token.type);
                try self.advance();
            } else if (self.check(.unicode_prop) or self.check(.not_unicode_prop)) {
                // \p{...}/\P{...} as a class member (e.g. `[\p{L}\d]`). Like
                // a negated shorthand (`\D`/`\W`/`\S`), a `\P{...}` member's
                // negation is its own -- it contributes the property's
                // complement to the union, not a second negation of the
                // whole enclosing class (that's `class.inverted`, applied
                // once at codegen time -- see `generateCharClass`).
                const name = self.lexer.pattern[self.current_token.name_start..self.current_token.name_end];
                const negated = self.current_token.type == .not_unicode_prop;
                try self.advance();
                const prop_node = try self.resolveUnicodePropertyNode(name, negated);
                errdefer prop_node.deinit();
                try class.appendChild(prop_node);
            } else if (self.isClassCharToken()) {
                const first_char = self.classCharValue();
                try self.advance();

                // Check for range
                if (self.check(.hyphen)) {
                    try self.advance(); // consume '-'

                    if (self.isClassCharToken()) {
                        const last_char = self.classCharValue();
                        try self.advance();

                        if (last_char < first_char) {
                            return error.InvalidCharRange;
                        }

                        const range = try Node.createCharRange(self.allocator, first_char, last_char);
                        errdefer range.deinit();
                        try class.appendChild(range);
                    } else {
                        // Hyphen at end or before ']', treat as literal
                        const first = try Node.createChar(self.allocator, first_char);
                        errdefer first.deinit();
                        try class.appendChild(first);

                        const hyphen_char = try Node.createChar(self.allocator, '-');
                        errdefer hyphen_char.deinit();
                        try class.appendChild(hyphen_char);
                    }
                } else {
                    // Single character
                    const char_node = try Node.createChar(self.allocator, first_char);
                    errdefer char_node.deinit();
                    try class.appendChild(char_node);
                }
            } else if (self.check(.hyphen)) {
                // Literal hyphen
                try self.advance();
                const hyphen = try Node.createChar(self.allocator, '-');
                errdefer hyphen.deinit();
                try class.appendChild(hyphen);
            } else {
                return error.UnexpectedToken;
            }
        }

        if (self.check(.class_minus_minus) or self.check(.class_and_and)) {
            // `class.inverted` was set to the *outer* `^` above (correct
            // for an ordinary class), but a flat operand1 (as opposed to a
            // nested `[...]` operand1 with its own independent `^`) is
            // never itself negated -- that outer negation belongs solely to
            // the set-op result (`outer_negated`, passed separately below).
            // Leaving it set here would double-count it: once via
            // `collectClassSetOperand` reading this flag as operand1's own
            // negation, and again via `outer_negated`.
            class.inverted = false;
            class_owned = false;
            return try self.finishClassSetOp(class, inverted);
        }

        self.lexer.in_char_class = false;
        _ = try self.consume(.rbracket);

        // `[^]` (an inverted class with no members) is JS's idiom for
        // "match anything" -- valid and meaningful. A non-inverted empty
        // class `[]` can never match anything; keep rejecting that case
        // (it's almost certainly a mistake), but let `[^]` through.
        if (class.children.items.len == 0 and !inverted) {
            return error.EmptyCharClass;
        }

        return class;
    }

    /// Finish parsing a `v`-mode class set operation (`[A--B]` / `[A&&B]`)
    /// once operand1 (`left`) and its enclosing class's own negation
    /// (`outer_negated`, from a leading `^` on the *outermost* bracket --
    /// distinct from either operand's own negation, if it's a `[^...]`
    /// nested class) are already parsed and `self.current_token` is the
    /// operator (`.class_minus_minus`/`.class_and_and`). Only ever called
    /// from `parseCharClass`, which already checked one of those two token
    /// types is current before calling this.
    fn finishClassSetOp(self: *Self, left: *Node, outer_negated: bool) ParseError!*Node {
        // `_owned` flags gate each errdefer off once the node becomes a
        // child of `node` below (whose own errdefer would otherwise also
        // free it via `node.deinit()`'s child walk, double-freeing it).
        var left_owned = true;
        errdefer if (left_owned) left.deinit();
        const op: ast_mod.ClassSetOp = if (self.check(.class_minus_minus)) .difference else .intersection;
        try self.advance(); // consume '--' or '&&'

        const right = try self.parseClassSetOperand();
        var right_owned = true;
        errdefer if (right_owned) right.deinit();

        // Exactly one operation, no chaining (`[A--B--C]`) -- see
        // `docs/KNOWN_LIMITATIONS.md` for why this scope was chosen.
        if (self.check(.class_minus_minus) or self.check(.class_and_and)) {
            return error.ChainedClassSetOperatorNotSupported;
        }

        self.lexer.in_char_class = false;
        _ = try self.consume(.rbracket);

        const node = try Node.createClassSetOp(self.allocator, op, outer_negated);
        errdefer node.deinit();
        // Flip each `_owned` flag only *after* `appendChild` succeeds: if it
        // fails, the node was never added to `node`'s children, so it must
        // still be freed by its own errdefer (flipping early would leak it,
        // since `node`'s own errdefer only walks children actually present).
        try node.appendChild(left);
        left_owned = false;
        try node.appendChild(right);
        right_owned = false;
        return node;
    }

    /// Parse a `v`-mode class set operation's second operand (the right-hand
    /// side of `--`/`&&`): either a nested `[...]` class (which may itself
    /// be `[^...]`-negated) or a bare `\p{...}`/`\P{...}` atom (e.g.
    /// `[\p{L}--\p{Lu}]`). No other operand shape is supported in this
    /// scope -- see `docs/KNOWN_LIMITATIONS.md`.
    fn parseClassSetOperand(self: *Self) ParseError!*Node {
        if (self.check(.lbracket)) {
            // Reset to normal mode before recursing, same reasoning as
            // operand1's nested case in `parseCharClass` -- otherwise a
            // negated nested operand (`[^x]`) silently loses its `^`.
            self.lexer.in_char_class = false;
            const nested = try self.parseCharClass();
            // Same rewind-and-re-fetch-in-class-mode fix as operand1's
            // nested case in `parseCharClass` -- the nested call's own
            // cleanup fetched whatever follows its `]` in normal mode,
            // which would misparse the outer class's closing `]` (or a
            // chained operator, correctly rejected below by the caller) as
            // literal characters instead.
            self.lexer.pos = self.current_token.position;
            self.lexer.in_char_class = true;
            try self.advance();
            return nested;
        }
        if (self.check(.unicode_prop) or self.check(.not_unicode_prop)) {
            const name = self.lexer.pattern[self.current_token.name_start..self.current_token.name_end];
            const negated = self.current_token.type == .not_unicode_prop;
            try self.advance();
            return self.resolveUnicodePropertyNode(name, negated);
        }
        return error.InvalidClassSetOperand;
    }

    /// Whether the current token can appear as a character-class member or
    /// range endpoint: a plain char, an escaped char (`\x41`, `\n`, ...), or
    /// a multi-byte Unicode code point (`\u{1F600}`, or a literal non-ASCII
    /// character in the pattern).
    fn isClassCharToken(self: *Self) bool {
        return self.check(.char) or self.check(.escaped_char) or self.check(.multibyte_char);
    }

    /// Whether the current token is a shorthand class (`\d`, `\D`, `\w`,
    /// `\W`, `\s`, `\S`) appearing as a member of an enclosing `[...]`.
    fn isShorthandClassToken(self: *Self) bool {
        return self.check(.digit) or self.check(.not_digit) or
            self.check(.word) or self.check(.not_word) or
            self.check(.whitespace) or self.check(.not_whitespace);
    }

    /// Append a shorthand class's members to an enclosing character class.
    /// Negated shorthands (`\D`/`\W`/`\S`) contribute their byte-range
    /// complement, not a `class.inverted` flip -- see `parseCharClass`.
    fn appendShorthandToClass(self: *Self, class: *Node, token_type: TokenType) !void {
        switch (token_type) {
            .digit => try self.appendRangesToClass(class, &DIGIT_RANGES),
            .word => try self.appendRangesToClass(class, &WORD_RANGES),
            .whitespace => try self.appendRangesToClass(class, &WHITESPACE_RANGES),
            .not_digit => {
                var buf: [DIGIT_RANGES.len + 1][2]u8 = undefined;
                try self.appendRangesToClass(class, complementByteRanges(&DIGIT_RANGES, &buf));
            },
            .not_word => {
                var buf: [WORD_RANGES.len + 1][2]u8 = undefined;
                try self.appendRangesToClass(class, complementByteRanges(&WORD_RANGES, &buf));
            },
            .not_whitespace => {
                var buf: [WHITESPACE_RANGES.len + 1][2]u8 = undefined;
                try self.appendRangesToClass(class, complementByteRanges(&WHITESPACE_RANGES, &buf));
            },
            else => unreachable,
        }
    }

    /// Append each byte range as a `char_range` child node.
    fn appendRangesToClass(self: *Self, class: *Node, ranges: []const [2]u8) !void {
        for (ranges) |r| {
            const range = try Node.createCharRange(self.allocator, r[0], r[1]);
            errdefer range.deinit();
            try class.appendChild(range);
        }
    }

    /// Build a standalone `char_class` node (optionally negated) from a list
    /// of byte ranges -- used for the standalone `\w`/`\W`/`\s`/`\S` atoms.
    fn createRangesClassNode(self: *Self, ranges: []const [2]u8, inverted: bool) !*Node {
        const class = try Node.createCharClass(self.allocator);
        errdefer class.deinit();
        class.inverted = inverted;
        try self.appendRangesToClass(class, ranges);
        return class;
    }

    /// Get the code point value of the current token (must satisfy
    /// isClassCharToken).
    fn classCharValue(self: *Self) u32 {
        if (self.current_token.type == .multibyte_char) {
            const bytes = self.current_token.byte_seq[0..self.current_token.byte_seq_len];
            // The lexer only ever produces multibyte_char tokens after
            // successfully decoding them, so this can't fail here.
            return std.unicode.utf8Decode(bytes) catch unreachable;
        }
        return self.current_token.char_value;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Parser: simple character" {
    const pattern = "a";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.char, root.type);
    try std.testing.expectEqual(@as(u32, 'a'), root.char_value);
}

test "Parser: sequence" {
    const pattern = "abc";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.sequence, root.type);
    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
    try std.testing.expectEqual(@as(u32, 'a'), root.children.items[0].char_value);
    try std.testing.expectEqual(@as(u32, 'b'), root.children.items[1].char_value);
    try std.testing.expectEqual(@as(u32, 'c'), root.children.items[2].char_value);
}

test "Parser: alternation" {
    const pattern = "a|b";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.alternation, root.type);
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    try std.testing.expectEqual(NodeType.char, root.children.items[0].type);
    try std.testing.expectEqual(NodeType.char, root.children.items[1].type);
}

test "Parser: star quantifier" {
    const pattern = "a*";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.star, root.type);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(NodeType.char, root.children.items[0].type);
}

test "Parser: plus quantifier" {
    const pattern = "a+";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.plus, root.type);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}

test "Parser: question quantifier" {
    const pattern = "a?";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.question, root.type);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}

test "Parser: repeat quantifier" {
    const pattern = "a{2,5}";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.repeat, root.type);
    try std.testing.expectEqual(@as(u32, 2), root.repeat_min);
    try std.testing.expectEqual(@as(u32, 5), root.repeat_max);
}

test "Parser: dot" {
    const pattern = ".";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.dot, root.type);
}

test "Parser: anchors" {
    {
        const pattern = "^a";
        var lexer = Lexer.init(pattern);
        var parser = try Parser.init(std.testing.allocator, &lexer);
        const root = try parser.parse();
        defer root.deinit();

        try std.testing.expectEqual(NodeType.sequence, root.type);
        try std.testing.expectEqual(NodeType.anchor_start, root.children.items[0].type);
    }

    {
        const pattern = "a$";
        var lexer = Lexer.init(pattern);
        var parser = try Parser.init(std.testing.allocator, &lexer);
        const root = try parser.parse();
        defer root.deinit();

        try std.testing.expectEqual(NodeType.sequence, root.type);
        try std.testing.expectEqual(NodeType.anchor_end, root.children.items[1].type);
    }
}

test "Parser: group" {
    const pattern = "(ab)";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.group, root.type);
    try std.testing.expectEqual(@as(u8, 1), root.group_index);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);

    const inner = root.children.items[0];
    try std.testing.expectEqual(NodeType.sequence, inner.type);
}

test "Parser: character class simple" {
    const pattern = "[abc]";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.char_class, root.type);
    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
}

test "Parser: character class range" {
    const pattern = "[a-z]";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.char_class, root.type);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);

    const range = root.children.items[0];
    try std.testing.expectEqual(NodeType.char_range, range.type);
    try std.testing.expectEqual(@as(u32, 'a'), range.range_start);
    try std.testing.expectEqual(@as(u32, 'z'), range.range_end);
}

test "Parser: complex pattern" {
    // Pattern: (a|b)+
    const pattern = "(a|b)+";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.plus, root.type);

    const group = root.children.items[0];
    try std.testing.expectEqual(NodeType.group, group.type);

    const alt = group.children.items[0];
    try std.testing.expectEqual(NodeType.alternation, alt.type);
}

test "Parser: escaped characters" {
    const pattern = "\\n\\t\\.";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.sequence, root.type);
    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
}

test "Parser: digit class" {
    const pattern = "\\d";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.char_range, root.type);
    try std.testing.expectEqual(@as(u32, '0'), root.range_start);
    try std.testing.expectEqual(@as(u32, '9'), root.range_end);
}

test "Parser: multiple alternations" {
    const pattern = "a|b|c";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    // Should create nested alternations
    try std.testing.expectEqual(NodeType.alternation, root.type);
}

test "Parser: empty pattern" {
    const pattern = "";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    // Empty pattern creates empty sequence
    try std.testing.expectEqual(NodeType.sequence, root.type);
    try std.testing.expectEqual(@as(usize, 0), root.children.items.len);
}

test "Parser: unmatched paren error" {
    const pattern = "(abc";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    try std.testing.expectError(error.UnexpectedToken, parser.parse());
}

test "Parser: invalid char range" {
    const pattern = "[z-a]";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    try std.testing.expectError(error.InvalidCharRange, parser.parse());
}

test "Parser: lazy star quantifier" {
    const pattern = "a*?";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.lazy_star, root.type);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(NodeType.char, root.children.items[0].type);
}

test "Parser: lazy plus quantifier" {
    const pattern = "a+?";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.lazy_plus, root.type);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}

test "Parser: lazy question quantifier" {
    const pattern = "a??";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.lazy_question, root.type);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}

test "Parser: possessive star quantifier" {
    const pattern = "a*+";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.possessive_star, root.type);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(NodeType.char, root.children.items[0].type);
}

test "Parser: possessive plus quantifier" {
    const pattern = "a++";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.possessive_plus, root.type);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}

test "Parser: possessive question quantifier" {
    const pattern = "a?+";
    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(std.testing.allocator, &lexer);

    const root = try parser.parse();
    defer root.deinit();

    try std.testing.expectEqual(NodeType.possessive_question, root.type);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}
