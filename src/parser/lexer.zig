//! Lexer for regex patterns
//!
//! This module tokenizes regex patterns into a stream of tokens
//! for consumption by the parser.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Token types in regex syntax
pub const TokenType = enum {
    // Literals
    char, // Regular character
    escaped_char, // \n, \t, \x41, \cA, \0, ...
    multibyte_char, // a \u{H+}/\uHHHH escape, or a literal input character, whose code point needs multiple UTF-8 bytes

    // Character classes
    dot, // .
    digit, // \d
    not_digit, // \D
    word, // \w
    not_word, // \W
    whitespace, // \s
    not_whitespace, // \S
    unicode_prop, // \p{Name}
    not_unicode_prop, // \P{Name}

    // Anchors
    line_start, // ^
    line_end, // $
    word_boundary, // \b
    not_word_boundary, // \B

    // Backreferences
    back_ref, // \1, \2, ..., \9
    named_back_ref, // \k<name>

    // Quantifiers (greedy)
    star, // *
    plus, // +
    question, // ?
    repeat, // {n,m}

    // Lazy quantifiers
    lazy_star, // *?
    lazy_plus, // +?
    lazy_question, // ??

    // Possessive quantifiers (eager/atomic)
    possessive_star, // *+
    possessive_plus, // ++
    possessive_question, // ?+

    // Groups and alternation
    lparen, // (
    rparen, // )
    pipe, // |

    // Lookahead assertions
    lookahead_start, // (?=
    negative_lookahead_start, // (?!

    // Lookbehind assertions
    lookbehind_start, // (?<=
    negative_lookbehind_start, // (?<!

    // Non-capturing groups
    non_capturing_group_start, // (?:

    // Named capturing groups
    named_group_start, // (?<name>

    // Character sets
    lbracket, // [
    rbracket, // ]
    caret, // ^ (inside brackets)
    hyphen, // - (inside brackets)
    // `v` mode (Unicode Sets) class set operators, only tokenized as such
    // inside a class -- see `nextInClass`.
    class_minus_minus, // -- (class set difference)
    class_and_and, // && (class set intersection)

    // Special
    eof,
};

/// Token with type and associated data
pub const Token = struct {
    type: TokenType,
    position: usize,

    /// Character value (for char, escaped_char)
    char_value: u32 = 0,

    /// Repeat counts (for repeat token)
    repeat_min: u32 = 0,
    repeat_max: u32 = 0,

    /// Backreference group number (for back_ref token)
    backref_group: u8 = 0,

    /// UTF-8 byte sequence (for multibyte_char token, e.g. a \u{...} escape
    /// whose code point doesn't fit in a single byte)
    byte_seq: [4]u8 = undefined,
    byte_seq_len: u3 = 0,

    /// Byte range of a group name in the original pattern (for
    /// named_group_start and named_back_ref tokens)
    name_start: usize = 0,
    name_end: usize = 0,

    /// Create a simple token
    pub fn simple(token_type: TokenType, pos: usize) Token {
        return .{ .type = token_type, .position = pos };
    }

    /// Create a character token
    pub fn char_token(c: u32, pos: usize) Token {
        return .{ .type = .char, .position = pos, .char_value = c };
    }

    /// Create an escaped character token
    pub fn escaped(c: u32, pos: usize) Token {
        return .{ .type = .escaped_char, .position = pos, .char_value = c };
    }

    /// Create an escaped multi-byte token (UTF-8 encoded code point)
    pub fn multibyteChar(bytes: [4]u8, len: u3, pos: usize) Token {
        return .{ .type = .multibyte_char, .position = pos, .byte_seq = bytes, .byte_seq_len = len };
    }

    /// Create a named-group-start token `(?<name>`
    pub fn namedGroupStart(name_start: usize, name_end: usize, pos: usize) Token {
        return .{ .type = .named_group_start, .position = pos, .name_start = name_start, .name_end = name_end };
    }

    /// Create a named-backreference token `\k<name>`
    pub fn namedBackRef(name_start: usize, name_end: usize, pos: usize) Token {
        return .{ .type = .named_back_ref, .position = pos, .name_start = name_start, .name_end = name_end };
    }

    /// Create a Unicode property token `\p{Name}` / `\P{Name}`
    pub fn unicodeProp(negated: bool, name_start: usize, name_end: usize, pos: usize) Token {
        return .{
            .type = if (negated) .not_unicode_prop else .unicode_prop,
            .position = pos,
            .name_start = name_start,
            .name_end = name_end,
        };
    }

    /// Create a repeat token
    pub fn repeat_token(min: u32, max: u32, pos: usize) Token {
        return .{
            .type = .repeat,
            .position = pos,
            .repeat_min = min,
            .repeat_max = max,
        };
    }

    /// Create a backreference token
    pub fn backref_token(group: u8, pos: usize) Token {
        return .{
            .type = .back_ref,
            .position = pos,
            .backref_group = group,
        };
    }
};

/// Lexer for tokenizing regex patterns
pub const Lexer = struct {
    pattern: []const u8,
    pos: usize,
    /// Set by the parser while inside `[...]`. Most regex metacharacters
    /// (`. * + ? ( ) | ^ $ { }`) are literal characters there, unlike
    /// everywhere else in the pattern -- see `nextInClass`. The parser is
    /// responsible for toggling this (it already consumes `[` and an
    /// optional leading `^` negation marker itself before any class-body
    /// tokens are requested, and `]`/`eof` end class-body tokenization).
    in_char_class: bool = false,

    /// Set by `compiler.zig::compile()` from `CompileOptions.unicode` before
    /// parsing starts (same "public field the owner toggles externally"
    /// pattern as `in_char_class`, since `Lexer.init` takes no options).
    /// When true, `parseEscape`/`parseClassEscape` reject an unrecognized
    /// escaped character (`error.InvalidEscape`) instead of the
    /// Annex-B-style literal-character fallback used everywhere else in
    /// this lexer -- see `isStrictIdentityEscape`.
    unicode_mode: bool = false,

    /// Set by `compiler.zig::compile()` from `CompileOptions.v` before
    /// parsing starts (same pattern as `unicode_mode`). When true,
    /// `nextInClass` recognizes `--`/`&&` (class set difference/
    /// intersection) and `[` (nested class) as their own tokens instead of
    /// literal characters -- see `parser.zig::parseCharClass`'s handling of
    /// `.class_minus_minus`/`.class_and_and`.
    v_mode: bool = false,

    const Self = @This();

    /// Initialize a new lexer
    pub fn init(pattern: []const u8) Self {
        return .{
            .pattern = pattern,
            .pos = 0,
        };
    }

    /// Get the next token
    pub fn next(self: *Self) !Token {
        if (self.in_char_class) {
            return self.nextInClass();
        }

        if (self.pos >= self.pattern.len) {
            return Token.simple(.eof, self.pos);
        }

        const c = self.pattern[self.pos];
        const start_pos = self.pos;

        switch (c) {
            '.' => {
                self.pos += 1;
                return Token.simple(.dot, start_pos);
            },
            '^' => {
                self.pos += 1;
                return Token.simple(.line_start, start_pos);
            },
            '$' => {
                self.pos += 1;
                return Token.simple(.line_end, start_pos);
            },
            '*' => {
                self.pos += 1;
                // Check for modifiers
                if (self.pos < self.pattern.len) {
                    const next_char = self.pattern[self.pos];
                    if (next_char == '?') {
                        self.pos += 1;
                        return Token.simple(.lazy_star, start_pos);
                    } else if (next_char == '+') {
                        self.pos += 1;
                        return Token.simple(.possessive_star, start_pos);
                    }
                }
                return Token.simple(.star, start_pos);
            },
            '+' => {
                self.pos += 1;
                // Check for modifiers
                if (self.pos < self.pattern.len) {
                    const next_char = self.pattern[self.pos];
                    if (next_char == '?') {
                        self.pos += 1;
                        return Token.simple(.lazy_plus, start_pos);
                    } else if (next_char == '+') {
                        self.pos += 1;
                        return Token.simple(.possessive_plus, start_pos);
                    }
                }
                return Token.simple(.plus, start_pos);
            },
            '?' => {
                self.pos += 1;
                // Check for modifiers
                if (self.pos < self.pattern.len) {
                    const next_char = self.pattern[self.pos];
                    if (next_char == '?') {
                        self.pos += 1;
                        return Token.simple(.lazy_question, start_pos);
                    } else if (next_char == '+') {
                        self.pos += 1;
                        return Token.simple(.possessive_question, start_pos);
                    }
                }
                return Token.simple(.question, start_pos);
            },
            '|' => {
                self.pos += 1;
                return Token.simple(.pipe, start_pos);
            },
            '(' => {
                self.pos += 1;
                // Check for special groups: (?= or (?! or (?<= or (?<! or (?:
                if (self.pos < self.pattern.len and self.pattern[self.pos] == '?') {
                    // Peek ahead to see what kind of assertion/group
                    if (self.pos + 1 < self.pattern.len) {
                        const next_char = self.pattern[self.pos + 1];
                        if (next_char == '=') {
                            // Positive lookahead (?=
                            self.pos += 2; // consume '?='
                            return Token.simple(.lookahead_start, start_pos);
                        } else if (next_char == '!') {
                            // Negative lookahead (?!
                            self.pos += 2; // consume '?!'
                            return Token.simple(.negative_lookahead_start, start_pos);
                        } else if (next_char == '<') {
                            // Lookbehind: (?<= or (?<!
                            if (self.pos + 2 < self.pattern.len) {
                                const third_char = self.pattern[self.pos + 2];
                                if (third_char == '=') {
                                    // Positive lookbehind (?<=
                                    self.pos += 3; // consume '?<='
                                    return Token.simple(.lookbehind_start, start_pos);
                                } else if (third_char == '!') {
                                    // Negative lookbehind (?<!
                                    self.pos += 3; // consume '?<!'
                                    return Token.simple(.negative_lookbehind_start, start_pos);
                                }
                            }
                            // Not a lookbehind: named capturing group (?<name>
                            self.pos += 2; // consume '?<'
                            const name = try self.parseGroupName();
                            return Token.namedGroupStart(name.start, name.end, start_pos);
                        } else if (next_char == ':') {
                            // Non-capturing group (?:
                            self.pos += 2; // consume '?:'
                            return Token.simple(.non_capturing_group_start, start_pos);
                        }
                    }
                    // If not recognized, treat as error or regular group
                    // For now, just consume as lparen and let parser handle it
                }
                return Token.simple(.lparen, start_pos);
            },
            ')' => {
                self.pos += 1;
                return Token.simple(.rparen, start_pos);
            },
            '[' => {
                self.pos += 1;
                return Token.simple(.lbracket, start_pos);
            },
            ']' => {
                self.pos += 1;
                return Token.simple(.rbracket, start_pos);
            },
            '-' => {
                self.pos += 1;
                return Token.simple(.hyphen, start_pos);
            },
            '{' => {
                self.pos += 1;
                return try self.parseRepeat(start_pos);
            },
            '\\' => {
                self.pos += 1;
                return try self.parseEscape(start_pos);
            },
            else => {
                if (c < 0x80) {
                    self.pos += 1;
                    return Token.char_token(c, start_pos);
                }
                // Possible lead byte of a multi-byte UTF-8 sequence: consume
                // the whole sequence as one atomic unit (so e.g. `é+` repeats
                // the whole 2-byte character, not just its last byte). Falls
                // back to a single raw byte if it isn't valid UTF-8.
                return self.literalMultibyteToken(c, start_pos);
            },
        }
    }

    /// Consume the full UTF-8 sequence starting at the current position
    /// (lead byte `c`, already known to be >= 0x80) and return it as one
    /// token, or fall back to a single-byte literal if it isn't valid UTF-8.
    fn literalMultibyteToken(self: *Self, c: u8, start_pos: usize) Token {
        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
            self.pos += 1;
            return Token.char_token(c, start_pos);
        };
        if (self.pos + seq_len > self.pattern.len) {
            self.pos += 1;
            return Token.char_token(c, start_pos);
        }
        const bytes = self.pattern[self.pos..][0..seq_len];
        if (std.unicode.utf8Decode(bytes)) |_| {
            self.pos += seq_len;
            var buf: [4]u8 = undefined;
            @memcpy(buf[0..seq_len], bytes);
            return Token.multibyteChar(buf, seq_len, start_pos);
        } else |_| {
            self.pos += 1;
            return Token.char_token(c, start_pos);
        }
    }

    /// Tokenize while inside `[...]`: most metacharacters are literal here.
    /// Only `]` (end of class), `-` (range separator), and `\` (escape
    /// introducer) keep special meaning; `^` was already handled by the
    /// parser before entering class mode (it's only a negation marker at
    /// the very start of the class).
    fn nextInClass(self: *Self) !Token {
        if (self.pos >= self.pattern.len) {
            return Token.simple(.eof, self.pos);
        }

        const c = self.pattern[self.pos];
        const start_pos = self.pos;

        switch (c) {
            ']' => {
                self.pos += 1;
                return Token.simple(.rbracket, start_pos);
            },
            '-' => {
                // `--` (class set difference) only under `v_mode` -- outside
                // it, `-` is always a single range hyphen, even when
                // followed by another `-` (e.g. the (rare) literal range
                // `[+---]` from `+` to `-`), preserving existing behavior.
                if (self.v_mode and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] == '-') {
                    self.pos += 2;
                    return Token.simple(.class_minus_minus, start_pos);
                }
                self.pos += 1;
                return Token.simple(.hyphen, start_pos);
            },
            '&' => {
                // `&&` (class set intersection) only under `v_mode` --
                // outside it, `&` has no special class meaning and falls
                // through to a literal character below.
                if (self.v_mode and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] == '&') {
                    self.pos += 2;
                    return Token.simple(.class_and_and, start_pos);
                }
                self.pos += 1;
                return Token.char_token('&', start_pos);
            },
            '[' => {
                // A nested class (`v` mode set-operation operand, e.g.
                // `[[a-z]&&[^x]]`) only under `v_mode` -- outside it, `[`
                // has no special class meaning and falls through to a
                // literal character below.
                if (self.v_mode) {
                    self.pos += 1;
                    return Token.simple(.lbracket, start_pos);
                }
                self.pos += 1;
                return Token.char_token('[', start_pos);
            },
            '\\' => {
                self.pos += 1;
                return try self.parseClassEscape(start_pos);
            },
            else => {
                if (c < 0x80) {
                    self.pos += 1;
                    return Token.char_token(c, start_pos);
                }
                return self.literalMultibyteToken(c, start_pos);
            },
        }
    }

    /// Parse an escape sequence inside `[...]`. Mostly the same as
    /// `parseEscape`, except: `\b` means backspace (0x08) here, not a word
    /// boundary (which is meaningless inside a class); `\B` and backref
    /// digits have no class meaning and fall back to their literal
    /// character; shorthand classes (`\d`, `\D`, `\w`, `\W`, `\s`, `\S`)
    /// are returned as their own tokens so the parser can splice their
    /// members into the enclosing class (see `parser.zig::parseCharClass`).
    fn parseClassEscape(self: *Self, start_pos: usize) !Token {
        if (self.pos >= self.pattern.len) {
            return error.InvalidEscape;
        }

        const c = self.pattern[self.pos];
        self.pos += 1;

        switch (c) {
            'd' => return Token.simple(.digit, start_pos),
            'D' => return Token.simple(.not_digit, start_pos),
            'w' => return Token.simple(.word, start_pos),
            'W' => return Token.simple(.not_word, start_pos),
            's' => return Token.simple(.whitespace, start_pos),
            'S' => return Token.simple(.not_whitespace, start_pos),
            // \p{...}/\P{...} as a class member (e.g. `[\p{L}\d]`) -- same
            // token-producing logic as the non-class case (`parseEscape`
            // below), so the parser's `parseCharClass` can splice a
            // property/script/script-extensions node into the class the
            // same way it already splices `\d`/`\w`/`\s` shorthand members.
            'p' => return self.parseUnicodeProperty(false, start_pos),
            'P' => return self.parseUnicodeProperty(true, start_pos),
            'b' => return Token.escaped(0x08, start_pos), // backspace inside a class
            'n' => return Token.escaped('\n', start_pos),
            'r' => return Token.escaped('\r', start_pos),
            't' => return Token.escaped('\t', start_pos),
            'v' => return Token.escaped(0x0B, start_pos),
            'f' => return Token.escaped(0x0C, start_pos),
            'x' => return self.parseHexEscape(start_pos),
            'u' => return self.parseUnicodeEscape(start_pos),
            'c' => return self.parseControlEscape(start_pos),
            '0' => {
                if (self.pos < self.pattern.len and isAsciiDigit(self.pattern[self.pos])) {
                    // Legacy Annex B octal (`\01`), never valid under `u`.
                    if (self.unicode_mode) return error.InvalidEscape;
                    return Token.escaped('0', start_pos);
                }
                return Token.escaped(0, start_pos);
            },
            // \], \\, \-, \^, \B, backref digits, and anything else: no
            // special class meaning, fall back to the literal character --
            // unless `unicode_mode` is set and `c` isn't a recognized class
            // identity-escape character, in which case it's a SyntaxError
            // (see `isStrictIdentityEscape`).
            else => {
                if (self.unicode_mode and !isStrictIdentityEscape(c, true)) {
                    return error.InvalidEscape;
                }
                return Token.escaped(c, start_pos);
            },
        }
    }

    /// Implementation limit on how far a `{n,m}` quantifier is unrolled.
    /// ECMA-262 permits arbitrarily large DecimalDigits counts (up to
    /// 2**53-1), but the code generator lowers the *required* `min`
    /// repetitions by emitting one copy of the atom apiece, so an
    /// astronomical count (e.g. `b{9007199254740991}`) would overflow the
    /// u32 counter (a safety-check panic) or exhaust memory. So we bound it:
    ///   * a `max` above the limit becomes unbounded (`∞`) -- always correct,
    ///     since no input can hold more repetitions than its own length; and
    ///   * a `min` above the limit is clamped to the limit -- the sole lossy
    ///     step, observable only for a subject that actually contains
    ///     >= MAX_REPEAT_UNROLL repetitions (a >=64K-char adversarial input).
    /// This is the same class of bounded-repeat limit engines like RE2 use.
    /// A fully faithful fix would be a runtime counted loop (the unused
    /// `LOOP` opcode was reserved for exactly that).
    pub const MAX_REPEAT_UNROLL: u32 = 1 << 16;

    /// Accumulate a decimal digit into a quantifier count, saturating once it
    /// passes the unroll limit so no arithmetic can overflow no matter how
    /// long the digit run is (the count is clamped at the return site).
    fn accumCount(v: u64, digit: u8) u64 {
        if (v > MAX_REPEAT_UNROLL) return v;
        return v * 10 + digit;
    }

    /// Parse repeat quantifier {n,m}
    fn parseRepeat(self: *Self, start_pos: usize) !Token {
        const unbounded = std.math.maxInt(u32);
        var min: u64 = 0;
        var max: u64 = 0;
        var has_comma = false;

        // Parse min
        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c >= '0' and c <= '9') {
                min = accumCount(min, c - '0');
                self.pos += 1;
            } else if (c == ',') {
                has_comma = true;
                self.pos += 1;
                break;
            } else if (c == '}') {
                // {n} form: exactly n. A count past the limit degrades to
                // "clamped min, unbounded max" (see MAX_REPEAT_UNROLL).
                self.pos += 1;
                const n: u32 = @intCast(@min(min, MAX_REPEAT_UNROLL));
                const m: u32 = if (min > MAX_REPEAT_UNROLL) unbounded else n;
                return Token.repeat_token(n, m, start_pos);
            } else {
                return error.InvalidRepeat;
            }
        }

        if (!has_comma) return error.InvalidRepeat;

        // Parse max
        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c >= '0' and c <= '9') {
                max = accumCount(max, c - '0');
                self.pos += 1;
            } else if (c == '}') {
                self.pos += 1;
                const n: u32 = @intCast(@min(min, MAX_REPEAT_UNROLL));
                // {n,} (no max digits) is unlimited; a max past the limit is
                // treated as unlimited too -- correct for any real input.
                const is_open = (max == 0 and self.pattern[self.pos - 2] == ',');
                const m: u32 = if (is_open or max > MAX_REPEAT_UNROLL)
                    unbounded
                else
                    @intCast(max);
                return Token.repeat_token(n, m, start_pos);
            } else {
                return error.InvalidRepeat;
            }
        }

        return error.UnterminatedRepeat;
    }

    /// Parse escape sequence
    fn parseEscape(self: *Self, start_pos: usize) !Token {
        if (self.pos >= self.pattern.len) {
            return error.InvalidEscape;
        }

        const c = self.pattern[self.pos];
        self.pos += 1;

        switch (c) {
            'd' => return Token.simple(.digit, start_pos),
            'D' => return Token.simple(.not_digit, start_pos),
            'w' => return Token.simple(.word, start_pos),
            'W' => return Token.simple(.not_word, start_pos),
            's' => return Token.simple(.whitespace, start_pos),
            'S' => return Token.simple(.not_whitespace, start_pos),
            'p' => return self.parseUnicodeProperty(false, start_pos),
            'P' => return self.parseUnicodeProperty(true, start_pos),
            'b' => return Token.simple(.word_boundary, start_pos),
            'B' => return Token.simple(.not_word_boundary, start_pos),
            'n' => return Token.escaped('\n', start_pos),
            'r' => return Token.escaped('\r', start_pos),
            't' => return Token.escaped('\t', start_pos),
            'v' => return Token.escaped(0x0B, start_pos),
            'f' => return Token.escaped(0x0C, start_pos),
            'x' => return self.parseHexEscape(start_pos),
            'u' => return self.parseUnicodeEscape(start_pos),
            'c' => return self.parseControlEscape(start_pos),
            // \k<name> named backreference. Falls back to a literal 'k' if
            // not followed by a validly-formed <name> (Annex-B-style
            // leniency, same as \x/\u/\c when malformed).
            'k' => {
                if (self.pos < self.pattern.len and self.pattern[self.pos] == '<') {
                    const saved_pos = self.pos;
                    self.pos += 1; // consume '<'
                    if (self.parseGroupName()) |name| {
                        return Token.namedBackRef(name.start, name.end, start_pos);
                    } else |_| {
                        self.pos = saved_pos;
                    }
                }
                return Token.escaped('k', start_pos);
            },
            // \0 is NUL, but only when not followed by another digit.
            // \0<digit> is legacy Annex B octal, not yet implemented; fall back
            // to a literal '0' (matching prior behavior) rather than guessing --
            // unless `unicode_mode` is set, where legacy octal is never valid.
            '0' => {
                if (self.pos < self.pattern.len and isAsciiDigit(self.pattern[self.pos])) {
                    if (self.unicode_mode) return error.InvalidEscape;
                    return Token.escaped('0', start_pos);
                }
                return Token.escaped(0, start_pos);
            },
            // Backreferences \1-\9
            '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                const group = @as(u8, c - '0');
                return Token.backref_token(group, start_pos);
            },
            '\\', '.', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '^', '$' => {
                return Token.escaped(c, start_pos);
            },
            // Any other escaped character (`\q`, `\!`, `\ `, ...): no special
            // meaning, fall back to the literal character -- unless
            // `unicode_mode` is set, where an unrecognized IdentityEscape is
            // a SyntaxError (see `isStrictIdentityEscape`).
            else => {
                if (self.unicode_mode and !isStrictIdentityEscape(c, false)) {
                    return error.InvalidEscape;
                }
                return Token.escaped(c, start_pos);
            },
        }
    }

    fn isAsciiDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    /// Whether `c` is a valid `IdentityEscape` character under `u`-mode's
    /// strict grammar -- i.e. `\c` is legal even though `c` isn't part of
    /// any recognized escape sequence (`d`/`w`/`s`/`p`/`x`/`u`/`c`/`k`/
    /// digits/...). Outside a class this is `SyntaxCharacter` (`^ $ \ . *
    /// + ? ( ) [ ] { } |`) plus `/`; inside a class, `-` is valid too (it's
    /// meaningful there). Both `parseEscape` and `parseClassEscape` only
    /// consult this from their `else` arm, which -- for the non-class case
    /// -- is only ever reached by characters *not* already handled by that
    /// switch's explicit `SyntaxCharacter` branch, so in practice only `/`
    /// matters there; the class case has no such explicit branch, so this
    /// is what actually distinguishes `\-`/`\/` (valid) from `\B`/`\5`/`\q`
    /// (SyntaxError under `u`, Annex-B-leniency literal otherwise).
    fn isStrictIdentityEscape(c: u8, in_class: bool) bool {
        return switch (c) {
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
            '-' => in_class,
            else => false,
        };
    }

    /// Parse a group name for `(?<name>` / `\k<name>`. Called with `self.pos`
    /// positioned right after the opening `<`. On success, consumes through
    /// the closing `>` and returns the name's byte range in the pattern
    /// (practical ASCII identifier subset: letter/`_`/`$` then
    /// letter/digit/`_`/`$`*, not the full Unicode identifier grammar).
    fn parseGroupName(self: *Self) !struct { start: usize, end: usize } {
        const name_start = self.pos;
        if (self.pos >= self.pattern.len) return error.InvalidGroupName;
        const first = self.pattern[self.pos];
        if (!(std.ascii.isAlphabetic(first) or first == '_' or first == '$')) {
            return error.InvalidGroupName;
        }
        self.pos += 1;
        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$') {
                self.pos += 1;
            } else {
                break;
            }
        }
        const name_end = self.pos;
        if (self.pos >= self.pattern.len or self.pattern[self.pos] != '>') {
            return error.InvalidGroupName;
        }
        self.pos += 1; // consume '>'
        return .{ .start = name_start, .end = name_end };
    }

    /// Parse `\p{Name}` / `\P{Name}` (Unicode property escape). Called with
    /// `self.pos` positioned right after `p`/`P`. Falls back to a literal
    /// `p`/`P` if not followed by a validly-formed `{Name}` (Annex-B-style
    /// leniency, same as `\x`/`\u`/`\c`/`\k` when malformed). This function
    /// only extracts the name span -- it doesn't know whether the name is a
    /// property this engine actually implements; the parser resolves that
    /// and surfaces a clear error for an unknown property (see
    /// `parser.zig::parseAtom`) rather than silently ignoring it.
    fn parseUnicodeProperty(self: *Self, negated: bool, start_pos: usize) Token {
        const saved_pos = self.pos;
        const fallback_char: u32 = if (negated) 'P' else 'p';

        if (self.pos >= self.pattern.len or self.pattern[self.pos] != '{') {
            return Token.escaped(fallback_char, start_pos);
        }
        self.pos += 1; // consume '{'
        const name_start = self.pos;
        while (self.pos < self.pattern.len and isPropertyNameChar(self.pattern[self.pos])) {
            self.pos += 1;
        }
        const name_end = self.pos;
        if (name_end == name_start or self.pos >= self.pattern.len or self.pattern[self.pos] != '}') {
            self.pos = saved_pos;
            return Token.escaped(fallback_char, start_pos);
        }
        self.pos += 1; // consume '}'
        return Token.unicodeProp(negated, name_start, name_end, start_pos);
    }

    /// Valid inside a `\p{...}` name/value: ASCII letters/digits, `_`
    /// (e.g. `Uppercase_Letter`), and `=` (e.g. `General_Category=Lu`).
    fn isPropertyNameChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '=';
    }

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn hexValue(c: u8) u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => unreachable,
        };
    }

    /// Parse \xHH (exactly 2 hex digits). If not followed by 2 hex digits,
    /// falls back to a literal 'x' (Annex-B-style leniency).
    fn parseHexEscape(self: *Self, start_pos: usize) Token {
        if (self.pos + 1 < self.pattern.len and
            isHexDigit(self.pattern[self.pos]) and isHexDigit(self.pattern[self.pos + 1]))
        {
            const value = @as(u32, hexValue(self.pattern[self.pos])) * 16 + hexValue(self.pattern[self.pos + 1]);
            self.pos += 2;
            return Token.escaped(value, start_pos);
        }
        return Token.escaped('x', start_pos);
    }

    /// Parse \cX control character escape. If not followed by an ASCII
    /// letter, falls back to a literal 'c' (Annex-B-style leniency).
    fn parseControlEscape(self: *Self, start_pos: usize) Token {
        if (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                const upper = if (c >= 'a' and c <= 'z') c - 'a' + 'A' else c;
                self.pos += 1;
                return Token.escaped(upper - 'A' + 1, start_pos);
            }
        }
        return Token.escaped('c', start_pos);
    }

    /// Parse \uHHHH or \u{H+}. Falls back to a literal 'u' if malformed
    /// (Annex-B-style leniency).
    fn parseUnicodeEscape(self: *Self, start_pos: usize) Token {
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '{') {
            const brace_start = self.pos;
            self.pos += 1;
            var value: u32 = 0;
            var digit_count: usize = 0;
            while (self.pos < self.pattern.len and isHexDigit(self.pattern[self.pos]) and value <= 0x10FFFF) {
                value = value * 16 + hexValue(self.pattern[self.pos]);
                self.pos += 1;
                digit_count += 1;
            }
            if (digit_count > 0 and value <= 0x10FFFF and
                self.pos < self.pattern.len and self.pattern[self.pos] == '}')
            {
                self.pos += 1;
                return codepointToken(value, start_pos);
            }
            self.pos = brace_start;
            return Token.escaped('u', start_pos);
        }

        if (self.pos + 3 < self.pattern.len and
            isHexDigit(self.pattern[self.pos]) and isHexDigit(self.pattern[self.pos + 1]) and
            isHexDigit(self.pattern[self.pos + 2]) and isHexDigit(self.pattern[self.pos + 3]))
        {
            var value: u32 = 0;
            for (0..4) |i| value = value * 16 + hexValue(self.pattern[self.pos + i]);
            self.pos += 4;
            return codepointToken(value, start_pos);
        }

        return Token.escaped('u', start_pos);
    }

    /// Turn a decoded Unicode code point into a token: a single-byte
    /// escaped_char for ASCII, or a UTF-8-encoded multibyte_char sequence
    /// otherwise (the engine matches bytes, so non-ASCII code points must be
    /// expressed as their UTF-8 byte sequence to match real input text).
    fn codepointToken(value: u32, start_pos: usize) Token {
        if (value <= 0x7F) {
            return Token.escaped(value, start_pos);
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(value), &buf) catch {
            // Lone surrogate half (0xD800-0xDFFF) or otherwise unencodable:
            // no valid byte representation, fall back to literal 'u'.
            return Token.escaped('u', start_pos);
        };
        return Token.multibyteChar(buf, len, start_pos);
    }

    /// Peek at the next token without consuming it
    pub fn peek(self: *Self) !Token {
        const saved_pos = self.pos;
        const token = try self.next();
        self.pos = saved_pos;
        return token;
    }

    /// Check if we're at end of pattern
    pub fn isAtEnd(self: Self) bool {
        return self.pos >= self.pattern.len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Lexer: simple characters" {
    var lexer = Lexer.init("abc");

    const t1 = try lexer.next();
    try std.testing.expectEqual(TokenType.char, t1.type);
    try std.testing.expectEqual(@as(u32, 'a'), t1.char_value);

    const t2 = try lexer.next();
    try std.testing.expectEqual(TokenType.char, t2.type);
    try std.testing.expectEqual(@as(u32, 'b'), t2.char_value);

    const t3 = try lexer.next();
    try std.testing.expectEqual(TokenType.char, t3.type);
    try std.testing.expectEqual(@as(u32, 'c'), t3.char_value);

    const eof = try lexer.next();
    try std.testing.expectEqual(TokenType.eof, eof.type);
}

test "Lexer: special characters" {
    var lexer = Lexer.init(".*|()+[]?");

    try std.testing.expectEqual(TokenType.dot, (try lexer.next()).type);
    try std.testing.expectEqual(TokenType.star, (try lexer.next()).type);
    try std.testing.expectEqual(TokenType.pipe, (try lexer.next()).type);
    try std.testing.expectEqual(TokenType.lparen, (try lexer.next()).type);
    try std.testing.expectEqual(TokenType.rparen, (try lexer.next()).type);
    try std.testing.expectEqual(TokenType.plus, (try lexer.next()).type);
    try std.testing.expectEqual(TokenType.lbracket, (try lexer.next()).type);
    try std.testing.expectEqual(TokenType.rbracket, (try lexer.next()).type);
    try std.testing.expectEqual(TokenType.question, (try lexer.next()).type);
}

test "Lexer: escape sequences" {
    var lexer = Lexer.init("\\d\\w\\s\\n\\.");

    try std.testing.expectEqual(TokenType.digit, (try lexer.next()).type);
    try std.testing.expectEqual(TokenType.word, (try lexer.next()).type);
    try std.testing.expectEqual(TokenType.whitespace, (try lexer.next()).type);

    const newline = try lexer.next();
    try std.testing.expectEqual(TokenType.escaped_char, newline.type);
    try std.testing.expectEqual(@as(u32, '\n'), newline.char_value);

    const dot = try lexer.next();
    try std.testing.expectEqual(TokenType.escaped_char, dot.type);
    try std.testing.expectEqual(@as(u32, '.'), dot.char_value);
}

test "Lexer: repeat quantifier" {
    var lexer = Lexer.init("a{3}b{2,5}c{1,}");

    _ = try lexer.next(); // 'a'
    const r1 = try lexer.next();
    try std.testing.expectEqual(TokenType.repeat, r1.type);
    try std.testing.expectEqual(@as(u32, 3), r1.repeat_min);
    try std.testing.expectEqual(@as(u32, 3), r1.repeat_max);

    _ = try lexer.next(); // 'b'
    const r2 = try lexer.next();
    try std.testing.expectEqual(TokenType.repeat, r2.type);
    try std.testing.expectEqual(@as(u32, 2), r2.repeat_min);
    try std.testing.expectEqual(@as(u32, 5), r2.repeat_max);

    _ = try lexer.next(); // 'c'
    const r3 = try lexer.next();
    try std.testing.expectEqual(TokenType.repeat, r3.type);
    try std.testing.expectEqual(@as(u32, 1), r3.repeat_min);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), r3.repeat_max);
}

test "Lexer: peek" {
    var lexer = Lexer.init("ab");

    const peeked = try lexer.peek();
    try std.testing.expectEqual(TokenType.char, peeked.type);
    try std.testing.expectEqual(@as(u32, 'a'), peeked.char_value);

    // Position should not have changed
    const actual = try lexer.next();
    try std.testing.expectEqual(TokenType.char, actual.type);
    try std.testing.expectEqual(@as(u32, 'a'), actual.char_value);
}

test "Lexer: anchors" {
    var lexer = Lexer.init("^hello$");

    try std.testing.expectEqual(TokenType.line_start, (try lexer.next()).type);
    _ = try lexer.next(); // 'h'
    _ = try lexer.next(); // 'e'
    _ = try lexer.next(); // 'l'
    _ = try lexer.next(); // 'l'
    _ = try lexer.next(); // 'o'
    try std.testing.expectEqual(TokenType.line_end, (try lexer.next()).type);
}

test "Lexer: word boundaries" {
    var lexer = Lexer.init("\\bword\\B");

    try std.testing.expectEqual(TokenType.word_boundary, (try lexer.next()).type);
    _ = try lexer.next(); // 'w'
    _ = try lexer.next(); // 'o'
    _ = try lexer.next(); // 'r'
    _ = try lexer.next(); // 'd'
    try std.testing.expectEqual(TokenType.not_word_boundary, (try lexer.next()).type);
}

test "Lexer: isAtEnd" {
    var lexer = Lexer.init("a");

    try std.testing.expect(!lexer.isAtEnd());
    _ = try lexer.next();
    try std.testing.expect(lexer.isAtEnd());
}

test "Lexer: invalid repeat" {
    var lexer = Lexer.init("{abc}");

    try std.testing.expectError(error.InvalidRepeat, lexer.next());
}

test "Lexer: position tracking" {
    var lexer = Lexer.init("abc");

    const t1 = try lexer.next();
    try std.testing.expectEqual(@as(usize, 0), t1.position);

    const t2 = try lexer.next();
    try std.testing.expectEqual(@as(usize, 1), t2.position);

    const t3 = try lexer.next();
    try std.testing.expectEqual(@as(usize, 2), t3.position);
}

test "Lexer: lazy quantifiers" {
    var lexer = Lexer.init("a*?b+?c??");

    _ = try lexer.next(); // 'a'
    try std.testing.expectEqual(TokenType.lazy_star, (try lexer.next()).type);
    _ = try lexer.next(); // 'b'
    try std.testing.expectEqual(TokenType.lazy_plus, (try lexer.next()).type);
    _ = try lexer.next(); // 'c'
    try std.testing.expectEqual(TokenType.lazy_question, (try lexer.next()).type);
}

test "Lexer: distinguish greedy from lazy" {
    {
        var lexer = Lexer.init("a*");
        _ = try lexer.next(); // 'a'
        try std.testing.expectEqual(TokenType.star, (try lexer.next()).type);
    }
    {
        var lexer = Lexer.init("a*?");
        _ = try lexer.next(); // 'a'
        try std.testing.expectEqual(TokenType.lazy_star, (try lexer.next()).type);
    }
}

test "Lexer: possessive quantifiers" {
    var lexer = Lexer.init("a*+b++c?+");

    _ = try lexer.next(); // 'a'
    try std.testing.expectEqual(TokenType.possessive_star, (try lexer.next()).type);
    _ = try lexer.next(); // 'b'
    try std.testing.expectEqual(TokenType.possessive_plus, (try lexer.next()).type);
    _ = try lexer.next(); // 'c'
    try std.testing.expectEqual(TokenType.possessive_question, (try lexer.next()).type);
}

test "Lexer: distinguish greedy/lazy/possessive" {
    // Star
    {
        var lexer = Lexer.init("a*");
        _ = try lexer.next();
        try std.testing.expectEqual(TokenType.star, (try lexer.next()).type);
    }
    {
        var lexer = Lexer.init("a*?");
        _ = try lexer.next();
        try std.testing.expectEqual(TokenType.lazy_star, (try lexer.next()).type);
    }
    {
        var lexer = Lexer.init("a*+");
        _ = try lexer.next();
        try std.testing.expectEqual(TokenType.possessive_star, (try lexer.next()).type);
    }
}
