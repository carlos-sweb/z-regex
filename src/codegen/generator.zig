//! Code generator - Translates AST to bytecode
//!
//! This module implements the code generation phase of the compiler,
//! converting the Abstract Syntax Tree into executable bytecode.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../parser/ast.zig");
const bytecode = @import("../bytecode/writer.zig");
const opcodes = @import("../bytecode/opcodes.zig");
const compiler = @import("compiler.zig");
const bittable_mod = @import("../utils/bittable.zig");
const BitTable = bittable_mod.BitTable;
const casefold = @import("../unicode/casefold.zig");

const Node = ast.Node;
const NodeType = ast.NodeType;
const BytecodeWriter = bytecode.BytecodeWriter;
const Label = bytecode.Label;
const Opcode = opcodes.Opcode;
const CompileOptions = compiler.CompileOptions;

/// Recursively collect the group indices of every `.group` node in `node`'s
/// subtree (including `node` itself), used to know which captures a
/// skipped optional atom would have set had it run.
fn collectGroupIndices(node: *Node, list: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
    if (node.type == .group) {
        try list.append(allocator, node.group_index);
    }
    for (node.children.items) |child| {
        try collectGroupIndices(child, list, allocator);
    }
}

/// Code generation error
pub const CodegenError = error{
    UnsupportedNode,
    InvalidPattern,
    TooManyGroups,
    TooManyRanges,
    TooManyClassProperties,
    OutOfMemory,
    // BytecodeWriter errors
    BufferTooSmall,
    UnknownOpcode,
};

/// Code generator for translating AST to bytecode
pub const CodeGenerator = struct {
    allocator: Allocator,
    writer: *BytecodeWriter,
    group_count: u8,
    options: CompileOptions,

    const Self = @This();

    /// Maximum ASCII character value
    const MAX_ASCII = 127;

    /// Difference between uppercase and lowercase ASCII letters
    const CASE_DIFF = 32;

    /// Set `c`'s opposite-case bit too, if `c` is an ASCII letter (a no-op
    /// otherwise). Used to make character-class/-range bit tables
    /// case-insensitive.
    fn addOppositeCaseToTable(table: *BitTable, c: u8) void {
        if (c >= 'a' and c <= 'z') table.set(c - CASE_DIFF);
        if (c >= 'A' and c <= 'Z') table.set(c + CASE_DIFF);
    }

    /// Add a byte range to a bit table, optionally also setting each byte's
    /// opposite-case bit (for `case_insensitive` character classes/ranges).
    fn addRangeToTable(table: *BitTable, start: u8, end: u8, case_insensitive: bool) void {
        table.addRange(start, end);
        if (case_insensitive) {
            var c: u16 = start;
            while (c <= end) : (c += 1) {
                addOppositeCaseToTable(table, @intCast(c));
            }
        }
    }

    /// Initialize a new code generator
    pub fn init(allocator: Allocator, writer: *BytecodeWriter, options: CompileOptions) Self {
        return .{
            .allocator = allocator,
            .writer = writer,
            .group_count = 0,
            .options = options,
        };
    }

    /// Generate bytecode from an AST
    pub fn generate(self: *Self, root: *Node) CodegenError!void {
        try self.generateNode(root);
        // Emit MATCH at the end to signal successful match
        try self.writer.emitSimple(.MATCH);
    }

    /// Generate code for a node
    fn generateNode(self: *Self, node: *Node) CodegenError!void {
        switch (node.type) {
            .char => try self.generateChar(node),
            .char_range => try self.generateCharRange(node),
            .char_class => try self.generateCharClass(node),
            .dot => try self.generateDot(),
            .unicode_property => try self.generateUnicodeProperty(node),
            .unicode_script => try self.generateUnicodeScript(node),
            .unicode_script_extensions => try self.generateUnicodeScriptExtensions(node),
            .class_set_op => try self.generateClassSetOp(node),
            .star => try self.generateStar(node),
            .plus => try self.generatePlus(node),
            .question => try self.generateQuestion(node),
            .repeat => try self.generateRepeat(node),
            .lazy_star => try self.generateLazyStar(node),
            .lazy_plus => try self.generateLazyPlus(node),
            .lazy_question => try self.generateLazyQuestion(node),
            .lazy_repeat => try self.generateLazyRepeat(node),
            .possessive_star => try self.generatePossessiveStar(node),
            .possessive_plus => try self.generatePossessivePlus(node),
            .possessive_question => try self.generatePossessiveQuestion(node),
            .sequence => try self.generateSequence(node),
            .alternation => try self.generateAlternation(node),
            .group => try self.generateGroup(node),
            .non_capturing_group => try self.generateNonCapturingGroup(node),
            .back_ref => try self.generateBackRef(node),
            .lookahead => try self.generateLookahead(node, false),
            .negative_lookahead => try self.generateLookahead(node, true),
            .lookbehind => try self.generateLookbehind(node, false),
            .negative_lookbehind => try self.generateLookbehind(node, true),
            .anchor_start => try self.generateAnchorStart(),
            .anchor_end => try self.generateAnchorEnd(),
            .word_boundary => try self.generateWordBoundary(),
            .not_word_boundary => try self.generateNotWordBoundary(),
        }
    }

    // =========================================================================
    // Character Matching
    // =========================================================================

    /// Generate code for a character literal
    fn generateChar(self: *Self, node: *Node) !void {
        const char = node.char_value;

        // If case-insensitive mode and this is an ASCII letter, generate alternation
        if (self.options.case_insensitive and char <= MAX_ASCII) {
            const c = @as(u8, @intCast(char));

            // Check if it's a letter
            const is_lower = c >= 'a' and c <= 'z';
            const is_upper = c >= 'A' and c <= 'Z';

            if (is_lower or is_upper) {
                // Generate alternation: lowercase|uppercase
                const lower = if (is_lower) c else c + CASE_DIFF;
                const upper = if (is_upper) c else c - CASE_DIFF;

                // Generate alternation: SPLIT upper_label, lower_label;
                // lower_label: lower; GOTO after; upper_label: upper; after:
                var lower_label = try self.writer.createLabel();
                var upper_label = try self.writer.createLabel();
                var after_label = try self.writer.createLabel();

                try self.writer.emitSplit(.SPLIT, upper_label, lower_label);
                try self.writer.defineLabel(&lower_label);
                try self.writer.emit1(.CHAR32, lower);
                try self.writer.emitJump(.GOTO, after_label);
                try self.writer.defineLabel(&upper_label);
                try self.writer.emit1(.CHAR32, upper);
                try self.writer.defineLabel(&after_label);

                return;
            }
        }

        // Normal case: just emit the character
        try self.writer.emit1(.CHAR32, char);
    }

    /// Generate code for a character range [a-z]
    fn generateCharRange(self: *Self, node: *Node) !void {
        // Under case_insensitive, a byte-range's opposite-case letters (if
        // any) must also match (e.g. `\d` used inside `[a-z]` as a standalone
        // range is fine either way, but `[a-z]` itself must also match
        // 'A'-'Z'). CHAR_RANGE/CHAR_RANGE_INV have no case-insensitive
        // variant, so fall back to a bit table, same representation
        // CHAR_CLASS already uses for exactly this reason.
        if (self.options.case_insensitive and node.range_end <= MAX_ASCII) {
            var table = BitTable.init();
            addRangeToTable(&table, @intCast(node.range_start), @intCast(node.range_end), true);
            const opcode: opcodes.Opcode = if (node.inverted) .CHAR_CLASS_INV else .CHAR_CLASS;
            try self.writer.emitCharClass(opcode, &table.bits);
            return;
        }

        const opcode: opcodes.Opcode = if (node.inverted) .CHAR_RANGE_INV else .CHAR_RANGE;
        try self.writer.emit2(opcode, node.range_start, node.range_end);
    }

    /// Generate code for a character class [abc] or [a-z0-9]
    fn generateCharClass(self: *Self, node: *Node) !void {
        if (node.children.items.len == 0 and !node.inverted) {
            return error.InvalidPattern;
        }

        // A `\p{...}`/`\P{...}` member (General_Category, binary property,
        // Script, or Script_Extensions) can't fit either the byte bitmap or
        // the plain code-point-range representation below -- its membership
        // test is a whole external table, not an enumerable range list --
        // so it gets its own representation, CHAR_CLASS_UNICODE(_INV),
        // checked for first since its presence overrides the other two
        // paths regardless of what else is in the class.
        for (node.children.items) |child| {
            switch (child.type) {
                .unicode_property, .unicode_script, .unicode_script_extensions => return self.generateCharClassUnicode(node),
                else => {},
            }
        }

        // A class member above U+007F needs more than one UTF-8 byte to
        // encode, so it can't fit the fixed 256-entry byte bitmap below —
        // it needs the code-point-range representation instead.
        var needs_ranges = false;
        for (node.children.items) |child| {
            switch (child.type) {
                .char => if (child.char_value > 0x7F) {
                    needs_ranges = true;
                },
                .char_range => if (child.range_start > 0x7F or child.range_end > 0x7F) {
                    needs_ranges = true;
                },
                else => return error.InvalidPattern,
            }
        }

        if (needs_ranges) {
            return self.generateCharClassRanges(node);
        }

        if (node.children.items.len == 1 and !node.inverted) {
            // Single item, not inverted: just generate the child directly
            const child = node.children.items[0];
            try self.generateNode(child);
            return;
        }

        // For inverted single items or multiple items: use bit table
        var table = BitTable.init();

        // Build bit table from children
        for (node.children.items) |child| {
            switch (child.type) {
                .char => {
                    const c = @as(u8, @intCast(child.char_value));
                    table.set(c);
                    if (self.options.case_insensitive) addOppositeCaseToTable(&table, c);
                },
                .char_range => {
                    const start = @as(u8, @intCast(child.range_start));
                    const end = @as(u8, @intCast(child.range_end));
                    addRangeToTable(&table, start, end, self.options.case_insensitive);
                },
                else => {
                    // Unsupported child type in character class
                    return error.InvalidPattern;
                },
            }
        }

        // Emit CHAR_CLASS or CHAR_CLASS_INV with inline bit table
        const opcode: opcodes.Opcode = if (node.inverted) .CHAR_CLASS_INV else .CHAR_CLASS;
        try self.writer.emitCharClass(opcode, &table.bits);
    }

    /// Generate a character class containing a member above U+007F, using
    /// CHAR_CLASS_RANGES(_INV) (up to `opcodes.MAX_CLASS_RANGES` code point
    /// ranges) instead of the byte bitmap.
    fn generateCharClassRanges(self: *Self, node: *Node) !void {
        var ranges: [opcodes.MAX_CLASS_RANGES][2]u32 = undefined;
        var count: usize = 0;

        for (node.children.items) |child| {
            if (count >= opcodes.MAX_CLASS_RANGES) return error.TooManyRanges;
            switch (child.type) {
                .char => {
                    ranges[count] = .{ child.char_value, child.char_value };
                    count += 1;
                    try self.appendCaseFoldPair(&ranges, &count, child.char_value);
                },
                .char_range => {
                    ranges[count] = .{ child.range_start, child.range_end };
                    count += 1;
                },
                else => return error.InvalidPattern,
            }
        }

        const opcode: opcodes.Opcode = if (node.inverted) .CHAR_CLASS_RANGES_INV else .CHAR_CLASS_RANGES;
        try self.writer.emitCharClassRanges(opcode, ranges[0..count]);
    }

    /// Under `case_insensitive`, append `char_value`'s simple case-fold pair
    /// (if it has one) as its own single-codepoint range -- e.g. a literal
    /// `é` member becomes both `é` and `É`. `casefold.zig`'s tables cover
    /// ASCII too (not just non-ASCII), so this needs no separate ASCII-only
    /// path the way `generateChar`'s SPLIT/GOTO trick does; it's shared by
    /// `generateCharClassRanges` and `generateCharClassUnicode`, the two
    /// class representations built from a `[2]u32` range table. Ranges
    /// (`[À-Ö]`-style) are NOT case-folded here -- unlike ASCII's uniform
    /// +32 shift, non-ASCII case mappings aren't a simple offset over an
    /// arbitrary range, so that remains a documented gap (see
    /// `docs/KNOWN_LIMITATIONS.md`).
    fn appendCaseFoldPair(self: *Self, ranges: *[opcodes.MAX_CLASS_RANGES][2]u32, count: *usize, char_value: u32) !void {
        if (!self.options.case_insensitive) return;
        const opposite = casefold.toUpper(char_value) orelse casefold.toLower(char_value) orelse return;
        if (count.* >= opcodes.MAX_CLASS_RANGES) return error.TooManyRanges;
        ranges[count.*] = .{ opposite, opposite };
        count.* += 1;
    }

    /// Generate a character class containing at least one `\p{...}`/`\P{...}`
    /// member (e.g. `[\p{L}\d]`, `[\P{Alphabetic}a-z]`). Inline chars/ranges
    /// (including spliced shorthand like `\d`) go in the same
    /// `opcodes.MAX_CLASS_RANGES`-slot range table `generateCharClassRanges`
    /// uses; property/script/script-extensions members go in a separate
    /// `opcodes.MAX_CLASS_PROPERTIES`-slot table, each carrying its own
    /// `negated` bit for `\P{...}` used as a member -- independent of
    /// `node.inverted` (the whole class's `[^...]` negation, applied once via
    /// the opcode's _INV form) -- see CHAR_CLASS_UNICODE's doc comment.
    fn generateCharClassUnicode(self: *Self, node: *Node) !void {
        var ranges: [opcodes.MAX_CLASS_RANGES][2]u32 = undefined;
        var range_count: usize = 0;
        var props: [opcodes.MAX_CLASS_PROPERTIES]opcodes.ClassPropertyTest = undefined;
        var prop_count: usize = 0;

        for (node.children.items) |child| {
            switch (child.type) {
                .char => {
                    if (range_count >= opcodes.MAX_CLASS_RANGES) return error.TooManyRanges;
                    ranges[range_count] = .{ child.char_value, child.char_value };
                    range_count += 1;
                    try self.appendCaseFoldPair(&ranges, &range_count, child.char_value);
                },
                .char_range => {
                    if (range_count >= opcodes.MAX_CLASS_RANGES) return error.TooManyRanges;
                    ranges[range_count] = .{ child.range_start, child.range_end };
                    range_count += 1;
                },
                .unicode_property, .unicode_script, .unicode_script_extensions => {
                    if (prop_count >= opcodes.MAX_CLASS_PROPERTIES) return error.TooManyClassProperties;
                    const kind: opcodes.ClassPropertyKind = switch (child.type) {
                        .unicode_property => .unicode_property,
                        .unicode_script => .script,
                        .unicode_script_extensions => .script_extensions,
                        else => unreachable,
                    };
                    props[prop_count] = .{ .kind = kind, .negated = child.inverted, .value = @intCast(child.char_value) };
                    prop_count += 1;
                },
                else => return error.InvalidPattern,
            }
        }

        const opcode: opcodes.Opcode = if (node.inverted) .CHAR_CLASS_UNICODE_INV else .CHAR_CLASS_UNICODE;
        try self.writer.emitCharClassUnicode(opcode, ranges[0..range_count], props[0..prop_count]);
    }

    /// Collect one `v`-mode class set operation operand's ranges/properties
    /// (into caller-provided fixed buffers, same capacity as
    /// `generateCharClassUnicode` uses) and its own negation, from either
    /// shape `parser.zig::parseClassSetOperand`/operand1-parsing can
    /// produce: a `char_class` node (ordinary or nested `[...]`, whose own
    /// `.inverted` becomes this operand's negation) or a bare
    /// `unicode_property`/`unicode_script`/`unicode_script_extensions` node
    /// (a single property test, negation already folded into that test's
    /// own `negated` bit -- see `bytecode.BytecodeWriter.ClassSetOperand`'s
    /// doc comment for why the operand-level `negated` stays `false` there).
    fn collectClassSetOperand(
        self: *Self,
        node: *Node,
        ranges: *[opcodes.MAX_CLASS_RANGES][2]u32,
        props: *[opcodes.MAX_CLASS_PROPERTIES]opcodes.ClassPropertyTest,
    ) !bytecode.BytecodeWriter.ClassSetOperand {
        _ = self;
        var range_count: usize = 0;
        var prop_count: usize = 0;
        var negated = false;

        switch (node.type) {
            .char_class => {
                negated = node.inverted;
                for (node.children.items) |child| {
                    switch (child.type) {
                        .char => {
                            if (range_count >= opcodes.MAX_CLASS_RANGES) return error.TooManyRanges;
                            ranges[range_count] = .{ child.char_value, child.char_value };
                            range_count += 1;
                        },
                        .char_range => {
                            if (range_count >= opcodes.MAX_CLASS_RANGES) return error.TooManyRanges;
                            ranges[range_count] = .{ child.range_start, child.range_end };
                            range_count += 1;
                        },
                        .unicode_property, .unicode_script, .unicode_script_extensions => {
                            if (prop_count >= opcodes.MAX_CLASS_PROPERTIES) return error.TooManyClassProperties;
                            props[prop_count] = .{
                                .kind = classPropertyKindOf(child.type),
                                .negated = child.inverted,
                                .value = @intCast(child.char_value),
                            };
                            prop_count += 1;
                        },
                        else => return error.InvalidPattern,
                    }
                }
            },
            .unicode_property, .unicode_script, .unicode_script_extensions => {
                props[0] = .{
                    .kind = classPropertyKindOf(node.type),
                    .negated = node.inverted,
                    .value = @intCast(node.char_value),
                };
                prop_count = 1;
            },
            else => return error.InvalidPattern,
        }

        return .{ .negated = negated, .ranges = ranges[0..range_count], .properties = props[0..prop_count] };
    }

    fn classPropertyKindOf(node_type: NodeType) opcodes.ClassPropertyKind {
        return switch (node_type) {
            .unicode_property => .unicode_property,
            .unicode_script => .script,
            .unicode_script_extensions => .script_extensions,
            else => unreachable,
        };
    }

    /// Generate code for a `v`-mode class set operation (`[A--B]`/`[A&&B]`).
    /// `node.char_value` is the `ast.ClassSetOp` (0=difference,
    /// 1=intersection); `node.inverted` is the whole operation's own
    /// `[^...]`, from the outermost bracket -- independent of either
    /// operand's own negation, handled per-operand by
    /// `collectClassSetOperand`. See `docs/KNOWN_LIMITATIONS.md` for this
    /// feature's scope (exactly one operation, no chaining, no `\q{...}`).
    fn generateClassSetOp(self: *Self, node: *Node) !void {
        if (node.children.items.len != 2) return error.InvalidPattern;

        var left_ranges: [opcodes.MAX_CLASS_RANGES][2]u32 = undefined;
        var left_props: [opcodes.MAX_CLASS_PROPERTIES]opcodes.ClassPropertyTest = undefined;
        const left = try self.collectClassSetOperand(node.children.items[0], &left_ranges, &left_props);

        var right_ranges: [opcodes.MAX_CLASS_RANGES][2]u32 = undefined;
        var right_props: [opcodes.MAX_CLASS_PROPERTIES]opcodes.ClassPropertyTest = undefined;
        const right = try self.collectClassSetOperand(node.children.items[1], &right_ranges, &right_props);

        const set_op: ast.ClassSetOp = @enumFromInt(node.char_value);
        if (set_op == .intersection) {
            try self.writer.emitCharClassSetOp(.intersection, node.inverted, left, right);
        } else {
            try self.writer.emitCharClassSetOp(.difference, node.inverted, left, right);
        }
    }

    /// Generate code for dot (any character)
    /// By default (dot_all = false), '.' excludes '\n', matching JS behavior
    /// without the 's' flag. With dot_all = true, '.' matches everything.
    fn generateDot(self: *Self) !void {
        if (self.options.dot_all) {
            try self.writer.emitSimple(.CHAR_ANY);
        } else {
            try self.writer.emitSimple(.CHAR);
        }
    }

    /// Generate code for a Unicode property atom (`\p{Name}` / `\P{Name}`).
    /// `node.char_value` holds the `UnicodeProperty` enum value the parser
    /// already resolved from the property name.
    fn generateUnicodeProperty(self: *Self, node: *Node) !void {
        const category: u32 = node.char_value;
        const opcode: opcodes.Opcode = if (node.inverted) .UNICODE_PROPERTY_INV else .UNICODE_PROPERTY;
        try self.writer.emit1(opcode, category);
    }

    /// Generate code for a Unicode Script atom (`\p{Script=Name}` /
    /// `\p{sc=Name}`). `node.char_value` holds the index into
    /// `properties.zig`'s generated `SCRIPT_NAMES`/`SCRIPT_RANGES` the
    /// parser already resolved from the script name.
    fn generateUnicodeScript(self: *Self, node: *Node) !void {
        const script_index: u32 = node.char_value;
        const opcode: opcodes.Opcode = if (node.inverted) .UNICODE_SCRIPT_INV else .UNICODE_SCRIPT;
        try self.writer.emit1(opcode, script_index);
    }

    /// Generate code for a Unicode Script_Extensions atom
    /// (`\p{Script_Extensions=Name}` / `\p{scx=Name}`). Same `script_index`
    /// space as `generateUnicodeScript` -- only the opcode (and therefore
    /// which table the matcher checks) differs.
    fn generateUnicodeScriptExtensions(self: *Self, node: *Node) !void {
        const script_index: u32 = node.char_value;
        const opcode: opcodes.Opcode = if (node.inverted) .UNICODE_SCRIPT_EXTENSIONS_INV else .UNICODE_SCRIPT_EXTENSIONS;
        try self.writer.emit1(opcode, script_index);
    }

    // =========================================================================
    // Quantifiers
    // =========================================================================

    /// Generate code for star quantifier: e*
    /// Pattern: L1: SPLIT_GREEDY L1_body, L2; L1_body: e; GOTO L1; L2: ...
    /// Greedy: try consuming (looping) before giving up, matching how
    /// `generatePlus`/`generateRepeat`'s unbounded case already do it. The
    /// `isStarQuantifier`/`matchStarGreedy` fast path in
    /// `recursive_matcher.zig` is an optimization on top of this correct
    /// order (it works regardless of operand order, trying both), but any
    /// atom too complex for that heuristic to recognize (e.g. a capturing
    /// group or nested alternation) falls back to this bytecode's own
    /// SPLIT priority for correctness -- which is why this must be
    /// genuinely greedy-first, not just an optimization hint.
    fn generateStar(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        var loop_label = try self.writer.createLabel();
        var end_label = try self.writer.createLabel();

        try self.writer.defineLabel(&loop_label);
        try self.writer.emitSplit(.SPLIT_GREEDY, loop_label, end_label);

        try self.generateNode(node.children.items[0]);
        try self.writer.emitJump(.GOTO, loop_label);

        try self.writer.defineLabel(&end_label);
    }

    /// Generate code for plus quantifier: e+
    /// Pattern: L1: e; SPLIT L1, L2; L2: ...
    fn generatePlus(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        var loop_label = try self.writer.createLabel();
        var end_label = try self.writer.createLabel();

        try self.writer.defineLabel(&loop_label);
        try self.generateNode(node.children.items[0]);
        try self.writer.emitSplit(.SPLIT_GREEDY, loop_label, end_label); // Greedy

        try self.writer.defineLabel(&end_label);
    }

    /// Generate code for question quantifier: e?
    /// Pattern: SPLIT_GREEDY consume, skip; consume: e; skip: ...
    /// Greedy: try consuming first (matching how `generateLazyQuestion`
    /// already tries skip first for `e??`) so a plain try-first-then-
    /// backtrack-on-failure interpretation is correct regardless of whether
    /// `e` is simple enough for the `isQuestionQuantifier` fast-path
    /// heuristic to recognize -- see `generateStar`'s doc comment for why
    /// this matters for compound atoms like a capturing group.
    fn generateQuestion(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }
        const atom = node.children.items[0];

        var skip_label = try self.writer.createLabel();
        var consume_label = try self.writer.createLabel();

        // SPLIT_GREEDY: first path = consume (fall-through), second = skip
        try self.writer.emitSplit(.SPLIT_GREEDY, consume_label, skip_label);

        // Define consume label immediately (fall-through)
        try self.writer.defineLabel(&consume_label);
        try self.generateNode(atom);

        // Define skip label (after the character), clearing any capture
        // groups nested inside the atom first -- see emitClearCapturesOnSkip.
        try self.emitClearCapturesOnSkip(atom, &skip_label);
    }

    /// After generating an optional atom's "consume" bytecode, wire up the
    /// "skip" landing point. If the atom contains capture groups, they must
    /// be reset to unset when this point is reached via the SPLIT's skip
    /// branch (the atom didn't run this time -- e.g. `(b+)?` declining to
    /// match on a later iteration of an enclosing `*`, after an earlier
    /// iteration DID set its capture) but NOT when reached by falling
    /// through after a successful consume (the atom just ran and its
    /// capture should stand). So the consume path needs an explicit GOTO
    /// past a small CLEAR_CAPTURE block that only the skip branch flows
    /// into; when there's nothing to clear, this degenerates to the
    /// original plain fall-through/jump-target shape.
    fn emitClearCapturesOnSkip(self: *Self, atom: *Node, skip_label: *Label) !void {
        var group_indices: std.ArrayListUnmanaged(u8) = .empty;
        defer group_indices.deinit(self.allocator);
        try collectGroupIndices(atom, &group_indices, self.allocator);

        if (group_indices.items.len == 0) {
            try self.writer.defineLabel(skip_label);
            return;
        }

        var merge_label = try self.writer.createLabel();
        try self.writer.emitJump(.GOTO, merge_label);
        try self.writer.defineLabel(skip_label);
        for (group_indices.items) |g| {
            try self.writer.emit1(.CLEAR_CAPTURE, g);
        }
        try self.writer.defineLabel(&merge_label);
    }

    /// Generate code for repeat quantifier: e{n,m}
    fn generateRepeat(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        const min = node.repeat_min;
        const max = node.repeat_max;

        // Generate min required repetitions
        for (0..min) |_| {
            try self.generateNode(node.children.items[0]);
        }

        // Check if unbounded {n,}
        const is_unbounded = max == std.math.maxInt(u32);

        if (is_unbounded) {
            // Pattern: {n,} = n required + e* (zero or more)
            // Generate e*: L1: SPLIT L2, L1; e; GOTO L1; L2: ...
            var loop_label = try self.writer.createLabel();
            var end_label = try self.writer.createLabel();

            try self.writer.defineLabel(&loop_label);
            try self.writer.emitSplit(.SPLIT_GREEDY, loop_label, end_label);
            try self.generateNode(node.children.items[0]);
            try self.writer.emitJump(.GOTO, loop_label);
            try self.writer.defineLabel(&end_label);
        } else if (max > min) {
            // Generate optional repetitions up to max
            // Pattern for each optional: SPLIT skip, consume; consume: e; skip: ...
            const optional_count = max - min;
            for (0..optional_count) |_| {
                var skip_label = try self.writer.createLabel();
                var consume_label = try self.writer.createLabel();

                // Greedy: try to consume first (longer match preferred)
                try self.writer.emitSplit(.SPLIT_GREEDY, consume_label, skip_label);
                try self.writer.defineLabel(&consume_label);
                try self.generateNode(node.children.items[0]);
                try self.writer.defineLabel(&skip_label);
            }
        }
    }

    /// Generate code for lazy star quantifier: e*?
    /// Pattern: L1: SPLIT_LAZY L2, L3; e; GOTO L1; L2: ...
    /// Lazy = try empty first, then try consuming
    fn generateLazyStar(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        var loop_label = try self.writer.createLabel();
        var end_label = try self.writer.createLabel();

        try self.writer.defineLabel(&loop_label);
        try self.writer.emitSplit(.SPLIT_LAZY, end_label, loop_label);

        try self.generateNode(node.children.items[0]);
        try self.writer.emitJump(.GOTO, loop_label);

        try self.writer.defineLabel(&end_label);
    }

    /// Generate code for lazy plus quantifier: e+?
    /// Pattern: L1: e; SPLIT_LAZY L2, L1; L2: ...
    /// Lazy = match once, then try exit before consuming more
    fn generateLazyPlus(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        var loop_label = try self.writer.createLabel();
        var end_label = try self.writer.createLabel();

        try self.writer.defineLabel(&loop_label);
        try self.generateNode(node.children.items[0]);
        try self.writer.emitSplit(.SPLIT_LAZY, end_label, loop_label);

        try self.writer.defineLabel(&end_label);
    }

    /// Generate code for lazy question quantifier: e??
    /// Pattern: SPLIT_LAZY skip, consume; consume: e; skip: ...
    /// Lazy = try skip first, then try consuming
    fn generateLazyQuestion(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }
        const atom = node.children.items[0];

        var skip_label = try self.writer.createLabel();
        var consume_label = try self.writer.createLabel();

        // SPLIT_LAZY: first path = skip (don't consume), second path = consume
        // For lazy, we prefer skip (minimal match)
        try self.writer.emitSplit(.SPLIT_LAZY, skip_label, consume_label);

        // Define consume label immediately (fall-through)
        try self.writer.defineLabel(&consume_label);
        try self.generateNode(atom);

        // Define skip label (after the character), clearing any capture
        // groups nested inside the atom first -- see emitClearCapturesOnSkip.
        try self.emitClearCapturesOnSkip(atom, &skip_label);
    }

    /// Generate code for lazy repeat quantifier: e{n,m}?
    /// Same as repeat but uses SPLIT_LAZY for minimal matching
    fn generateLazyRepeat(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        const min = node.repeat_min;
        const max = node.repeat_max;

        // Generate min required repetitions
        for (0..min) |_| {
            try self.generateNode(node.children.items[0]);
        }

        // Check if unbounded {n,}?
        const is_unbounded = max == std.math.maxInt(u32);

        if (is_unbounded) {
            // Pattern: {n,}? = n required + e*? (lazy zero or more)
            // Generate e*?: L1: SPLIT_LAZY L2, L1; e; GOTO L1; L2: ...
            var loop_label = try self.writer.createLabel();
            var end_label = try self.writer.createLabel();

            try self.writer.defineLabel(&loop_label);
            try self.writer.emitSplit(.SPLIT_LAZY, end_label, loop_label);
            try self.generateNode(node.children.items[0]);
            try self.writer.emitJump(.GOTO, loop_label);
            try self.writer.defineLabel(&end_label);
        } else if (max > min) {
            // Generate optional repetitions up to max
            // Pattern for each optional: SPLIT_LAZY skip, consume; consume: e; skip: ...
            const optional_count = max - min;
            for (0..optional_count) |_| {
                var skip_label = try self.writer.createLabel();
                var consume_label = try self.writer.createLabel();

                // Lazy: try to skip first (minimal match preferred)
                try self.writer.emitSplit(.SPLIT_LAZY, skip_label, consume_label);
                try self.writer.defineLabel(&consume_label);
                try self.generateNode(node.children.items[0]);
                try self.writer.defineLabel(&skip_label);
            }
        }
    }

    /// Generate code for possessive star quantifier: e*+
    /// Pattern: L1: SPLIT_POSSESSIVE L2, L3; e; GOTO L1; L2: ...
    /// Possessive = consume all without backtracking
    fn generatePossessiveStar(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        var loop_label = try self.writer.createLabel();
        var end_label = try self.writer.createLabel();

        try self.writer.defineLabel(&loop_label);
        try self.writer.emitSplit(.SPLIT_POSSESSIVE, end_label, loop_label);

        try self.generateNode(node.children.items[0]);
        try self.writer.emitJump(.GOTO, loop_label);

        try self.writer.defineLabel(&end_label);
    }

    /// Generate code for possessive plus quantifier: e++
    /// Pattern: e; L1: SPLIT_POSSESSIVE L2, L1; e; GOTO L1; L2: ...
    /// Possessive = match at least once, then consume all without backtracking
    fn generatePossessivePlus(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        var loop_label = try self.writer.createLabel();
        var end_label = try self.writer.createLabel();

        // Match at least once
        try self.generateNode(node.children.items[0]);

        // Loop for more (possessive)
        try self.writer.defineLabel(&loop_label);
        try self.writer.emitSplit(.SPLIT_POSSESSIVE, end_label, loop_label);
        try self.generateNode(node.children.items[0]);
        try self.writer.emitJump(.GOTO, loop_label);

        try self.writer.defineLabel(&end_label);
    }

    /// Generate code for possessive question quantifier: e?+
    /// Pattern: SPLIT_POSSESSIVE consume, skip; consume: e; skip: ...
    /// Possessive = try consuming once without backtracking (greedy first)
    fn generatePossessiveQuestion(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        var skip_label = try self.writer.createLabel();
        var consume_label = try self.writer.createLabel();

        // SPLIT_POSSESSIVE: Try greedy path (consume) first, no backtracking
        try self.writer.emitSplit(.SPLIT_POSSESSIVE, consume_label, skip_label);

        // Define consume label immediately (fall-through)
        try self.writer.defineLabel(&consume_label);
        try self.generateNode(node.children.items[0]);

        // Define skip label (after the character)
        try self.writer.defineLabel(&skip_label);
    }

    // =========================================================================
    // Structural
    // =========================================================================

    /// Generate code for sequence: abc
    ///
    /// `node.char_value != 0` marks the special case of a `.sequence` built
    /// by the parser for a single atomic multi-byte literal character (e.g.
    /// `é`, `\u{1F600}`) rather than an ordinary multi-atom sequence like
    /// `"ab"` (which never sets `char_value`, see `parser.zig`) -- under
    /// `case_insensitive`, that single character's simple case-fold pair (if
    /// it has one) must also match, the non-ASCII counterpart to
    /// `generateChar`'s ASCII SPLIT/GOTO alternation below.
    fn generateSequence(self: *Self, node: *Node) !void {
        if (self.options.case_insensitive and node.char_value != 0) {
            const opposite = casefold.toUpper(node.char_value) orelse casefold.toLower(node.char_value);
            if (opposite) |opp| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(opp), &buf) catch unreachable;

                var orig_label = try self.writer.createLabel();
                var opp_label = try self.writer.createLabel();
                var after_label = try self.writer.createLabel();

                try self.writer.emitSplit(.SPLIT, orig_label, opp_label);
                try self.writer.defineLabel(&orig_label);
                for (node.children.items) |child| {
                    try self.generateNode(child);
                }
                try self.writer.emitJump(.GOTO, after_label);
                try self.writer.defineLabel(&opp_label);
                for (buf[0..len]) |b| {
                    try self.writer.emit1(.CHAR32, b);
                }
                try self.writer.defineLabel(&after_label);
                return;
            }
        }

        for (node.children.items) |child| {
            try self.generateNode(child);
        }
    }

    /// Generate code for alternation: a|b
    /// Pattern: SPLIT L_left, L_right; L_left: a; GOTO end; L_right: b; end:
    fn generateAlternation(self: *Self, node: *Node) !void {
        if (node.children.items.len != 2) {
            return error.InvalidPattern;
        }

        var left_label = try self.writer.createLabel();
        var right_label = try self.writer.createLabel();
        var end_label = try self.writer.createLabel();

        // Split to both branches
        try self.writer.emitSplit(.SPLIT, left_label, right_label);

        // Left branch
        try self.writer.defineLabel(&left_label);
        try self.generateNode(node.children.items[0]);
        try self.writer.emitJump(.GOTO, end_label);

        // Right branch
        try self.writer.defineLabel(&right_label);
        try self.generateNode(node.children.items[1]);

        try self.writer.defineLabel(&end_label);
    }

    /// Generate code for capture group: (...)
    fn generateGroup(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        const group_index = node.group_index;

        // SAVE_START
        try self.writer.emit1(.SAVE_START, group_index);

        // Generate group content
        try self.generateNode(node.children.items[0]);

        // SAVE_END
        try self.writer.emit1(.SAVE_END, group_index);
    }

    /// Generate code for a non-capturing group (?:...)
    /// Non-capturing groups only provide grouping without capturing
    fn generateNonCapturingGroup(self: *Self, node: *Node) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        // Just generate the content without SAVE_START/SAVE_END
        // This is purely for grouping (e.g., for quantifiers or alternation)
        try self.generateNode(node.children.items[0]);
    }

    // =========================================================================
    // Anchors
    // =========================================================================

    /// `^`: STRING_START (absolute) by default, LINE_START (line-boundary-aware)
    /// when the multiline option is set.
    fn generateAnchorStart(self: *Self) !void {
        const opcode: opcodes.Opcode = if (self.options.multiline) .LINE_START else .STRING_START;
        try self.writer.emitSimple(opcode);
    }

    /// `$`: STRING_END (absolute) by default, LINE_END (line-boundary-aware)
    /// when the multiline option is set.
    fn generateAnchorEnd(self: *Self) !void {
        const opcode: opcodes.Opcode = if (self.options.multiline) .LINE_END else .STRING_END;
        try self.writer.emitSimple(opcode);
    }

    fn generateWordBoundary(self: *Self) !void {
        try self.writer.emitSimple(.WORD_BOUNDARY);
    }

    fn generateNotWordBoundary(self: *Self) !void {
        try self.writer.emitSimple(.NOT_WORD_BOUNDARY);
    }

    /// Generate code for backreference
    fn generateBackRef(self: *Self, node: *Node) !void {
        const group = node.group_index;

        // Choose case-sensitive or case-insensitive based on options
        const opcode: opcodes.Opcode = if (self.options.case_insensitive)
            .BACK_REF_I
        else
            .BACK_REF;

        try self.writer.emit1(opcode, group);
    }

    /// Generate code for lookahead assertion
    fn generateLookahead(self: *Self, node: *Node, negative: bool) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        const opcode: opcodes.Opcode = if (negative) .NEGATIVE_LOOKAHEAD else .LOOKAHEAD;

        // For simplicity, we don't use the length field for now
        // The executor will find LOOKAHEAD_END by scanning forward
        try self.writer.emit1(opcode, 0);

        // Generate the lookahead pattern
        try self.generateNode(node.children.items[0]);

        // Emit lookahead end marker
        try self.writer.emitSimple(.LOOKAHEAD_END);
    }

    /// Generate code for lookbehind assertion: (?<=...) or (?<!...)
    fn generateLookbehind(self: *Self, node: *Node, negative: bool) !void {
        if (node.children.items.len != 1) {
            return error.InvalidPattern;
        }

        const opcode: opcodes.Opcode = if (negative) .NEGATIVE_LOOKBEHIND else .LOOKBEHIND;

        // For simplicity, we don't use the length field for now
        // The executor will find LOOKBEHIND_END by scanning forward
        try self.writer.emit1(opcode, 0);

        // Generate the lookbehind pattern
        try self.generateNode(node.children.items[0]);

        // Emit lookbehind end marker
        try self.writer.emitSimple(.LOOKBEHIND_END);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "CodeGenerator: simple character" {
    const parser_mod = @import("../parser/parser.zig");
    const lexer_mod = @import("../parser/lexer.zig");

    const pattern = "a";
    var lexer = lexer_mod.Lexer.init(pattern);
    var parser = try parser_mod.Parser.init(std.testing.allocator, &lexer);
    defer parser.deinit();

    const ast_root = try parser.parse();
    defer ast_root.deinit();

    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var gen = CodeGenerator.init(std.testing.allocator, &writer, .{});
    try gen.generate(ast_root);

    const code = try writer.finalize();
    // Note: code is owned by writer, will be freed by writer.deinit()

    // Should contain CHAR32 and MATCH
    try std.testing.expect(code.len > 0);
    try std.testing.expectEqual(@intFromEnum(Opcode.CHAR32), code[0]);
}

test "CodeGenerator: sequence" {
    const parser_mod = @import("../parser/parser.zig");
    const lexer_mod = @import("../parser/lexer.zig");

    const pattern = "abc";
    var lexer = lexer_mod.Lexer.init(pattern);
    var parser = try parser_mod.Parser.init(std.testing.allocator, &lexer);
    defer parser.deinit();

    const ast_root = try parser.parse();
    defer ast_root.deinit();

    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var gen = CodeGenerator.init(std.testing.allocator, &writer, .{});
    try gen.generate(ast_root);

    const code = try writer.finalize();

    // Should contain 3 CHAR32 instructions + MATCH
    try std.testing.expect(code.len > 0);
}

test "CodeGenerator: alternation" {
    const parser_mod = @import("../parser/parser.zig");
    const lexer_mod = @import("../parser/lexer.zig");

    const pattern = "a|b";
    var lexer = lexer_mod.Lexer.init(pattern);
    var parser = try parser_mod.Parser.init(std.testing.allocator, &lexer);
    defer parser.deinit();

    const ast_root = try parser.parse();
    defer ast_root.deinit();

    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var gen = CodeGenerator.init(std.testing.allocator, &writer, .{});
    try gen.generate(ast_root);

    const code = try writer.finalize();

    // Should contain SPLIT instruction
    try std.testing.expect(code.len > 0);
}

test "CodeGenerator: star quantifier" {
    const parser_mod = @import("../parser/parser.zig");
    const lexer_mod = @import("../parser/lexer.zig");

    const pattern = "a*";
    var lexer = lexer_mod.Lexer.init(pattern);
    var parser = try parser_mod.Parser.init(std.testing.allocator, &lexer);
    defer parser.deinit();

    const ast_root = try parser.parse();
    defer ast_root.deinit();

    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var gen = CodeGenerator.init(std.testing.allocator, &writer, .{});
    try gen.generate(ast_root);

    const code = try writer.finalize();

    try std.testing.expect(code.len > 0);
}

test "CodeGenerator: plus quantifier" {
    const parser_mod = @import("../parser/parser.zig");
    const lexer_mod = @import("../parser/lexer.zig");

    const pattern = "a+";
    var lexer = lexer_mod.Lexer.init(pattern);
    var parser = try parser_mod.Parser.init(std.testing.allocator, &lexer);
    defer parser.deinit();

    const ast_root = try parser.parse();
    defer ast_root.deinit();

    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var gen = CodeGenerator.init(std.testing.allocator, &writer, .{});
    try gen.generate(ast_root);

    const code = try writer.finalize();

    try std.testing.expect(code.len > 0);
}

test "CodeGenerator: group" {
    const parser_mod = @import("../parser/parser.zig");
    const lexer_mod = @import("../parser/lexer.zig");

    const pattern = "(ab)";
    var lexer = lexer_mod.Lexer.init(pattern);
    var parser = try parser_mod.Parser.init(std.testing.allocator, &lexer);
    defer parser.deinit();

    const ast_root = try parser.parse();
    defer ast_root.deinit();

    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var gen = CodeGenerator.init(std.testing.allocator, &writer, .{});
    try gen.generate(ast_root);

    const code = try writer.finalize();

    // Should contain SAVE_START and SAVE_END
    try std.testing.expect(code.len > 0);
}

test "CodeGenerator: anchors" {
    const parser_mod = @import("../parser/parser.zig");
    const lexer_mod = @import("../parser/lexer.zig");

    const pattern = "^a$";
    var lexer = lexer_mod.Lexer.init(pattern);
    var parser = try parser_mod.Parser.init(std.testing.allocator, &lexer);
    defer parser.deinit();

    const ast_root = try parser.parse();
    defer ast_root.deinit();

    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var gen = CodeGenerator.init(std.testing.allocator, &writer, .{});
    try gen.generate(ast_root);

    const code = try writer.finalize();

    try std.testing.expect(code.len > 0);
}

test "CodeGenerator: dot excludes newline by default" {
    const parser_mod = @import("../parser/parser.zig");
    const lexer_mod = @import("../parser/lexer.zig");

    const pattern = ".";
    var lexer = lexer_mod.Lexer.init(pattern);
    var parser = try parser_mod.Parser.init(std.testing.allocator, &lexer);
    defer parser.deinit();

    const ast_root = try parser.parse();
    defer ast_root.deinit();

    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var gen = CodeGenerator.init(std.testing.allocator, &writer, .{});
    try gen.generate(ast_root);

    const code = try writer.finalize();

    // Without dot_all, '.' must exclude '\n' (matches JS default): CHAR now
    // means "any Unicode scalar value except newline" (decoded at match time).
    try std.testing.expectEqual(@intFromEnum(Opcode.CHAR), code[0]);
}

test "CodeGenerator: dot matches newline with dot_all" {
    const parser_mod = @import("../parser/parser.zig");
    const lexer_mod = @import("../parser/lexer.zig");

    const pattern = ".";
    var lexer = lexer_mod.Lexer.init(pattern);
    var parser = try parser_mod.Parser.init(std.testing.allocator, &lexer);
    defer parser.deinit();

    const ast_root = try parser.parse();
    defer ast_root.deinit();

    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var gen = CodeGenerator.init(std.testing.allocator, &writer, .{ .dot_all = true });
    try gen.generate(ast_root);

    const code = try writer.finalize();

    // With dot_all, '.' matches newline too, so it compiles to the dedicated
    // CHAR_ANY opcode instead of the newline-excluding CHAR opcode.
    try std.testing.expectEqual(@intFromEnum(Opcode.CHAR_ANY), code[0]);
}

test "CodeGenerator: repeat quantifier" {
    const parser_mod = @import("../parser/parser.zig");
    const lexer_mod = @import("../parser/lexer.zig");

    const pattern = "a{2,4}";
    var lexer = lexer_mod.Lexer.init(pattern);
    var parser = try parser_mod.Parser.init(std.testing.allocator, &lexer);
    defer parser.deinit();

    const ast_root = try parser.parse();
    defer ast_root.deinit();

    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var gen = CodeGenerator.init(std.testing.allocator, &writer, .{});
    try gen.generate(ast_root);

    const code = try writer.finalize();

    try std.testing.expect(code.len > 0);
}
