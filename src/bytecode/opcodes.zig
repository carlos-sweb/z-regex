//! Bytecode opcodes for zregexp
//!
//! This module defines all opcodes used in the regex bytecode virtual machine.
//! Based on QuickJS libregexp with 33 opcodes organized by category.
//!
//! Bytecode format:
//! - Each instruction starts with an 8-bit opcode
//! - Followed by operands (size depends on opcode)
//! - All multi-byte values are little-endian

const std = @import("std");

/// Maximum number of code point ranges inline in a CHAR_CLASS_RANGES(_INV)
/// instruction. A fixed cap keeps instruction size static (like
/// CHAR_CLASS's fixed 32-byte bitmap) instead of requiring variable-length
/// instruction decoding. Classes needing more ranges than this are a
/// compile error (`error.TooManyRanges`) rather than silently truncated.
pub const MAX_CLASS_RANGES = 8;

/// Maximum number of `\p{...}`/`\P{...}` (property, script, or
/// script-extensions) tests inline in a CHAR_CLASS_UNICODE(_INV)
/// instruction -- e.g. `[\p{L}\p{N}\p{Script=Greek}]` uses 3. A class
/// needing more than this is a compile error (`error.TooManyClassProperties`)
/// rather than silently truncated, same policy as MAX_CLASS_RANGES.
pub const MAX_CLASS_PROPERTIES = 4;

/// Which lookup a CHAR_CLASS_UNICODE(_INV) property-test entry's `value`
/// indexes into -- three different index spaces (`UnicodeProperty` enum
/// ordinal, or a script-table index shared by `.script`/`.script_extensions`)
/// need to be told apart at match time.
pub const ClassPropertyKind = enum(u8) {
    unicode_property = 0,
    script = 1,
    script_extensions = 2,
};

/// Byte size of one CHAR_CLASS_SET_OP operand block: negated:u8 +
/// range_count:u8 + MAX_CLASS_RANGES*(u32+u32) + prop_count:u8 +
/// MAX_CLASS_PROPERTIES*(u8+u8+u8) -- the same range/property-table layout
/// CHAR_CLASS_UNICODE uses, plus one leading `negated` byte for this
/// operand's own `[^...]` (only meaningful when the operand is a nested
/// class; see CHAR_CLASS_SET_OP's doc comment).
pub const CLASS_SET_OPERAND_SIZE = 1 + 1 + MAX_CLASS_RANGES * 8 + 1 + MAX_CLASS_PROPERTIES * 3;

/// One `\p{...}`/`\P{...}` test inline in a CHAR_CLASS_UNICODE(_INV)
/// instruction. `negated` is this individual test's own `\P{...}`-ness
/// (independent of the whole instruction's _INV variant -- see
/// CHAR_CLASS_UNICODE's doc comment for why those are different things).
pub const ClassPropertyTest = struct {
    kind: ClassPropertyKind,
    negated: bool,
    value: u8,
};

/// Bytecode opcode enumeration
/// Matches libregexp opcode values for compatibility
pub const Opcode = enum(u8) {
    // =========================================================================
    // Character Matching (0x00-0x0F)
    // =========================================================================

    /// Match any Unicode scalar value except newline (dot without /s).
    /// Decodes a full UTF-8 sequence at the current position (1-4 bytes);
    /// falls back to matching exactly 1 byte if it isn't valid UTF-8.
    /// Format: [CHAR]
    CHAR = 0x00,

    /// Match specific character
    /// Format: [CHAR c:u32]
    CHAR32 = 0x01,

    /// Match one of two characters (optimization)
    /// Format: [CHAR2 c1:u32 c2:u32]
    CHAR2 = 0x02,

    /// Match character in range [min, max]
    /// Format: [CHAR_RANGE min:u32 max:u32]
    CHAR_RANGE = 0x03,

    /// Match character in inverted range (not in [min, max]).
    /// If the byte at the current position isn't in [min, max], decodes and
    /// consumes a full UTF-8 sequence there (see CHAR); otherwise fails.
    /// Format: [CHAR_RANGE_INV min:u32 max:u32]
    CHAR_RANGE_INV = 0x04,

    /// Match character class (with inline bit table)
    /// Format: [CHAR_CLASS table:32bytes]
    CHAR_CLASS = 0x05,

    /// Match inverted character class (with inline bit table).
    /// Same UTF-8 decoding behavior as CHAR_RANGE_INV.
    /// Format: [CHAR_CLASS_INV table:32bytes]
    CHAR_CLASS_INV = 0x06,

    /// Match any Unicode scalar value, including newline (dot with /s).
    /// Same UTF-8 decoding behavior as CHAR, without the newline exclusion.
    /// Format: [CHAR_ANY]
    CHAR_ANY = 0x07,

    /// Match a Unicode scalar value against a small set of code point ranges
    /// (for character classes containing a member above U+007F, which can't
    /// fit the CHAR_CLASS bitmap). Decodes a full UTF-8 sequence at the
    /// current position and checks it against up to MAX_CLASS_RANGES ranges.
    /// Format: [CHAR_CLASS_RANGES count:u8 (start:u32 end:u32){8}]
    CHAR_CLASS_RANGES = 0x08,

    /// Inverted form of CHAR_CLASS_RANGES: matches if the decoded code point
    /// is NOT in any of the ranges (consumes the full UTF-8 sequence, same
    /// reasoning as CHAR_RANGE_INV/CHAR_CLASS_INV).
    /// Format: [CHAR_CLASS_RANGES_INV count:u8 (start:u32 end:u32){8}]
    CHAR_CLASS_RANGES_INV = 0x09,

    /// Match a Unicode property (`\p{...}`) -- General_Category or one of a
    /// curated set of binary properties. Decodes a full UTF-8 sequence at
    /// the current position and checks it against the static table
    /// selected by `category` (`src/unicode/properties.zig::UnicodeProperty`).
    /// Format: [UNICODE_PROPERTY category:u8]
    UNICODE_PROPERTY = 0x0A,

    /// Inverted form of UNICODE_PROPERTY (`\P{...}`): matches if the decoded
    /// code point does NOT belong to the property.
    /// Format: [UNICODE_PROPERTY_INV category:u8]
    UNICODE_PROPERTY_INV = 0x0B,

    /// Match a Unicode Script (`\p{Script=Greek}`/`\p{sc=Greek}`). Decodes a
    /// full UTF-8 sequence at the current position and checks it against
    /// the script selected by `script_index` (an index into
    /// `src/unicode/properties.zig`'s generated `SCRIPT_NAMES`/
    /// `SCRIPT_RANGES` tables -- kept separate from UNICODE_PROPERTY's
    /// `UnicodeProperty` enum since there are ~170 scripts, too many for a
    /// hand-maintained enum/switch the way the smaller, more stable
    /// General_Category + binary property set uses).
    /// Format: [UNICODE_SCRIPT script_index:u8]
    UNICODE_SCRIPT = 0x0C,

    /// Inverted form of UNICODE_SCRIPT: matches if the decoded code point
    /// does NOT belong to the script.
    /// Format: [UNICODE_SCRIPT_INV script_index:u8]
    UNICODE_SCRIPT_INV = 0x0D,

    /// Match a Unicode Script_Extensions (`\p{Script_Extensions=Greek}`/
    /// `\p{scx=Greek}`) -- a broader, possibly multi-valued property than
    /// Script (e.g. a combining accent's Script is `Inherited` but its
    /// Script_Extensions includes every script it's actually combined with).
    /// Same `script_index` space as UNICODE_SCRIPT -- a script's identity
    /// doesn't change between the two properties, only which codepoints
    /// count as using it -- so this checks
    /// `src/unicode/properties.zig`'s generated `SCRIPT_EXTENSIONS_RANGES`
    /// table instead of `SCRIPT_RANGES`.
    /// Format: [UNICODE_SCRIPT_EXTENSIONS script_index:u8]
    UNICODE_SCRIPT_EXTENSIONS = 0x0E,

    /// Inverted form of UNICODE_SCRIPT_EXTENSIONS: matches if the decoded
    /// code point's Script_Extensions set does NOT include the script.
    /// Format: [UNICODE_SCRIPT_EXTENSIONS_INV script_index:u8]
    UNICODE_SCRIPT_EXTENSIONS_INV = 0x0F,

    // =========================================================================
    // Control Flow (0x10-0x1F)
    // =========================================================================

    /// Match succeeds
    /// Format: [MATCH]
    MATCH = 0x10,

    /// Unconditional jump
    /// Format: [GOTO offset:i32]
    GOTO = 0x11,

    /// Split execution (for alternation, quantifiers)
    /// Format: [SPLIT offset1:i32 offset2:i32]
    /// Try offset1 first, backtrack to offset2 on failure
    SPLIT = 0x12,

    /// Split with greedy preference
    /// Format: [SPLIT_GREEDY offset1:i32 offset2:i32]
    SPLIT_GREEDY = 0x13,

    /// Split with lazy preference
    /// Format: [SPLIT_LAZY offset1:i32 offset2:i32]
    SPLIT_LAZY = 0x14,

    /// Split with possessive/atomic behavior (no backtracking)
    /// Format: [SPLIT_POSSESSIVE offset1:i32 offset2:i32]
    SPLIT_POSSESSIVE = 0x15,

    /// Loop check (for quantifiers)
    /// Format: [LOOP counter_index:u8 max:u32 offset:i32]
    LOOP = 0x16,

    // =========================================================================
    // Capture Groups (0x20-0x2F)
    // =========================================================================

    /// Save capture group start position
    /// Format: [SAVE_START group:u8]
    SAVE_START = 0x20,

    /// Save capture group end position
    /// Format: [SAVE_END group:u8]
    SAVE_END = 0x21,

    /// Save named capture group start
    /// Format: [SAVE_START_NAMED group:u8 name_offset:u32]
    SAVE_START_NAMED = 0x22,

    /// Save named capture group end
    /// Format: [SAVE_END_NAMED group:u8 name_offset:u32]
    SAVE_END_NAMED = 0x23,

    /// Reset a capture group to "unset" (both start and end cleared).
    /// Used on the "skip" path of an optional atom (`e?`, or an inner
    /// optional inside a repeated group) so a capture set by an earlier
    /// iteration of an enclosing loop doesn't leak into a later iteration
    /// where this group's own atom didn't participate.
    /// Format: [CLEAR_CAPTURE group:u8]
    CLEAR_CAPTURE = 0x24,

    // =========================================================================
    // Backreferences (0x30-0x3F)
    // =========================================================================

    /// Match backreference to capture group
    /// Format: [BACK_REF group:u8]
    BACK_REF = 0x30,

    /// Match backreference (case insensitive)
    /// Format: [BACK_REF_I group:u8]
    BACK_REF_I = 0x31,

    // =========================================================================
    // Assertions (0x40-0x4F)
    // =========================================================================

    /// Assert start of line (^ or \A)
    /// Format: [LINE_START]
    LINE_START = 0x40,

    /// Assert end of line ($ or \Z)
    /// Format: [LINE_END]
    LINE_END = 0x41,

    /// Assert word boundary (\b)
    /// Format: [WORD_BOUNDARY]
    WORD_BOUNDARY = 0x42,

    /// Assert non-word boundary (\B)
    /// Format: [NOT_WORD_BOUNDARY]
    NOT_WORD_BOUNDARY = 0x43,

    /// Assert start of string (\A)
    /// Format: [STRING_START]
    STRING_START = 0x44,

    /// Assert end of string (\z)
    /// Format: [STRING_END]
    STRING_END = 0x45,

    // =========================================================================
    // Lookaround (0x50-0x5F)
    // =========================================================================

    /// Positive lookahead
    /// Format: [LOOKAHEAD len:u32 ... LOOKAHEAD_END]
    LOOKAHEAD = 0x50,

    /// Negative lookahead
    /// Format: [NEGATIVE_LOOKAHEAD len:u32 ... LOOKAHEAD_END]
    NEGATIVE_LOOKAHEAD = 0x51,

    /// Positive lookbehind
    /// Format: [LOOKBEHIND len:u32 ... LOOKBEHIND_END]
    LOOKBEHIND = 0x52,

    /// Negative lookbehind
    /// Format: [NEGATIVE_LOOKBEHIND len:u32 ... LOOKBEHIND_END]
    NEGATIVE_LOOKBEHIND = 0x53,

    /// End of lookahead assertion
    /// Format: [LOOKAHEAD_END]
    LOOKAHEAD_END = 0x54,

    /// End of lookbehind assertion
    /// Format: [LOOKBEHIND_END]
    LOOKBEHIND_END = 0x55,

    // =========================================================================
    // Special (0x60-0x6F)
    // =========================================================================

    /// Push current position to stack
    /// Format: [PUSH_POS]
    PUSH_POS = 0x60,

    /// Pop and check position hasn't changed
    /// Format: [CHECK_POS]
    CHECK_POS = 0x61,

    // =========================================================================
    // More Character Matching (Character Matching's 0x00-0x0F range filled up
    // by the UNICODE_SCRIPT_EXTENSIONS pair -- these two continue it here
    // rather than renumbering anything that shipped earlier)
    // =========================================================================

    /// Match a character class containing a mix of inline code-point ranges
    /// (literal chars/ranges/shorthand-splices, same MAX_CLASS_RANGES cap as
    /// CHAR_CLASS_RANGES) and `\p{...}`/`\P{...}` tests (General_Category,
    /// binary property, Script, or Script_Extensions, up to
    /// MAX_CLASS_PROPERTIES) -- e.g. `[\p{L}\d]` or `[\P{Alphabetic}a-z]`.
    /// Matches if the decoded code point is in ANY inline range OR satisfies
    /// ANY property test (each property test carries its own `negated` bit
    /// for `\P{...}` used as a class member, independent of the whole-class
    /// negation this opcode's _INV form applies -- `[\P{L}\d]` and
    /// `[^\p{L}\d]` are different things).
    /// Format: [CHAR_CLASS_UNICODE range_count:u8 (start:u32 end:u32){8}
    ///          prop_count:u8 (kind:u8 negated:u8 value:u8){4}]
    /// kind: 0 = UnicodeProperty (value = enum ordinal), 1 = Script,
    /// 2 = Script_Extensions (value = script index for both).
    CHAR_CLASS_UNICODE = 0x62,

    /// Inverted form of CHAR_CLASS_UNICODE: matches if the decoded code
    /// point matches NONE of the ranges or property tests (De Morgan's
    /// complement of the union -- same single-XOR-at-the-end approach
    /// CHAR_CLASS_RANGES_INV already uses, no per-member negation needed
    /// here since that's already handled by each property test's own
    /// `negated` bit).
    /// Format: same as CHAR_CLASS_UNICODE.
    CHAR_CLASS_UNICODE_INV = 0x63,

    /// Match a `v`-mode class set operation (`[A--B]` difference, `[A&&B]`
    /// intersection) -- see `docs/KNOWN_LIMITATIONS.md` for this feature's
    /// scope (exactly one operation, no chaining, no `\q{...}`). Decodes one
    /// code point and evaluates it against *two* independent
    /// CHAR_CLASS_UNICODE-shaped operand specs (same range-table +
    /// property-table layout, each with its own `negated` bit for its own
    /// `[^...]`, if it's a nested class), then combines with AND (`op=1`,
    /// intersection) or AND-NOT (`op=0`, difference); `result_negated` is
    /// this whole operation's *own* `[^...]`, from the outermost bracket --
    /// a third, independent negation layer on top of each operand's own.
    /// Format: [CHAR_CLASS_SET_OP op:u8 result_negated:u8
    ///          left:(negated:u8 range_count:u8 (start:u32 end:u32){8}
    ///                prop_count:u8 (kind:u8 negated:u8 value:u8){4})
    ///          right:(same layout as left)]
    CHAR_CLASS_SET_OP = 0x64,

    _,

    /// Get the category of this opcode
    pub fn category(self: Opcode) OpcodeCategory {
        return switch (self) {
            .CHAR, .CHAR32, .CHAR2, .CHAR_RANGE, .CHAR_RANGE_INV, .CHAR_CLASS, .CHAR_CLASS_INV, .CHAR_ANY, .CHAR_CLASS_RANGES, .CHAR_CLASS_RANGES_INV, .UNICODE_PROPERTY, .UNICODE_PROPERTY_INV, .UNICODE_SCRIPT, .UNICODE_SCRIPT_INV, .UNICODE_SCRIPT_EXTENSIONS, .UNICODE_SCRIPT_EXTENSIONS_INV, .CHAR_CLASS_UNICODE, .CHAR_CLASS_UNICODE_INV, .CHAR_CLASS_SET_OP => .character_match,
            .MATCH, .GOTO, .SPLIT, .SPLIT_GREEDY, .SPLIT_LAZY, .SPLIT_POSSESSIVE, .LOOP => .control_flow,
            .SAVE_START, .SAVE_END, .SAVE_START_NAMED, .SAVE_END_NAMED, .CLEAR_CAPTURE => .capture,
            .BACK_REF, .BACK_REF_I => .backreference,
            .LINE_START, .LINE_END, .WORD_BOUNDARY, .NOT_WORD_BOUNDARY, .STRING_START, .STRING_END => .assertion,
            .LOOKAHEAD, .NEGATIVE_LOOKAHEAD, .LOOKBEHIND, .NEGATIVE_LOOKBEHIND, .LOOKAHEAD_END, .LOOKBEHIND_END => .lookaround,
            .PUSH_POS, .CHECK_POS => .special,
            _ => .unknown,
        };
    }

    /// Get the size of this instruction in bytes (including opcode)
    pub fn size(self: Opcode) u8 {
        return switch (self) {
            // 1 byte (opcode only)
            .CHAR, .CHAR_ANY, .MATCH, .LINE_START, .LINE_END, .WORD_BOUNDARY, .NOT_WORD_BOUNDARY,
            .STRING_START, .STRING_END, .LOOKAHEAD_END, .LOOKBEHIND_END,
            .PUSH_POS, .CHECK_POS => 1,

            // 2 bytes (opcode + u8)
            .SAVE_START, .SAVE_END, .BACK_REF, .BACK_REF_I, .CLEAR_CAPTURE, .UNICODE_PROPERTY, .UNICODE_PROPERTY_INV, .UNICODE_SCRIPT, .UNICODE_SCRIPT_INV, .UNICODE_SCRIPT_EXTENSIONS, .UNICODE_SCRIPT_EXTENSIONS_INV => 2,

            // 5 bytes (opcode + u32)
            .CHAR32, .LOOKAHEAD, .NEGATIVE_LOOKAHEAD, .LOOKBEHIND, .NEGATIVE_LOOKBEHIND => 5,

            // 6 bytes (opcode + u8 + u32)
            .SAVE_START_NAMED, .SAVE_END_NAMED => 6,

            // 5 bytes (opcode + i32)
            .GOTO => 5,

            // 9 bytes (opcode + 2 * u32)
            .CHAR2, .CHAR_RANGE, .CHAR_RANGE_INV => 9,

            // 10 bytes (opcode + u8 + u32 + i32)
            .LOOP => 10,

            // 9 bytes (opcode + 2 * i32 for offsets)
            .SPLIT, .SPLIT_GREEDY, .SPLIT_LAZY, .SPLIT_POSSESSIVE => 9,

            // 33 bytes (opcode + 32 bytes bit table)
            .CHAR_CLASS, .CHAR_CLASS_INV => 33,

            // opcode + count:u8 + MAX_CLASS_RANGES * (start:u32 + end:u32)
            .CHAR_CLASS_RANGES, .CHAR_CLASS_RANGES_INV => 2 + MAX_CLASS_RANGES * 8,

            // opcode + range_count:u8 + MAX_CLASS_RANGES*(u32+u32) + prop_count:u8 + MAX_CLASS_PROPERTIES*(u8+u8+u8)
            .CHAR_CLASS_UNICODE, .CHAR_CLASS_UNICODE_INV => 1 + 1 + MAX_CLASS_RANGES * 8 + 1 + MAX_CLASS_PROPERTIES * 3,

            // opcode + op:u8 + result_negated:u8 + 2 * CLASS_SET_OPERAND_SIZE
            .CHAR_CLASS_SET_OP => 1 + 1 + 1 + 2 * CLASS_SET_OPERAND_SIZE,

            _ => 1, // Unknown opcodes default to 1 byte
        };
    }

    /// Check if this opcode terminates execution
    pub fn isTerminal(self: Opcode) bool {
        return self == .MATCH;
    }

    /// Check if this opcode is a control flow instruction
    pub fn isControlFlow(self: Opcode) bool {
        return self.category() == .control_flow;
    }

    /// Check if this opcode can cause backtracking
    pub fn canBacktrack(self: Opcode) bool {
        return switch (self) {
            .SPLIT, .SPLIT_GREEDY, .SPLIT_LAZY, .LOOP => true,
            else => false,
        };
    }

    /// Get human-readable name
    pub fn name(self: Opcode) []const u8 {
        return @tagName(self);
    }
};

/// Opcode category for classification
pub const OpcodeCategory = enum {
    character_match,
    control_flow,
    capture,
    backreference,
    assertion,
    lookaround,
    special,
    unknown,
};

/// Metadata about an opcode
pub const OpcodeInfo = struct {
    opcode: Opcode,
    mnemonic: []const u8,
    description: []const u8,
    operands: []const OperandType,
    category: OpcodeCategory,

    pub const OperandType = enum {
        u8_value,
        u16_value,
        u32_value,
        i32_offset,
        group_index,
        name_offset,
        counter_index,
    };
};

/// Get metadata for an opcode
pub fn getOpcodeInfo(opcode: Opcode) OpcodeInfo {
    return switch (opcode) {
        .CHAR => .{
            .opcode = opcode,
            .mnemonic = "CHAR",
            .description = "Match any character except newline",
            .operands = &[_]OpcodeInfo.OperandType{},
            .category = .character_match,
        },
        .CHAR32 => .{
            .opcode = opcode,
            .mnemonic = "CHAR32",
            .description = "Match specific character",
            .operands = &[_]OpcodeInfo.OperandType{.u32_value},
            .category = .character_match,
        },
        .MATCH => .{
            .opcode = opcode,
            .mnemonic = "MATCH",
            .description = "Match succeeds",
            .operands = &[_]OpcodeInfo.OperandType{},
            .category = .control_flow,
        },
        .SPLIT => .{
            .opcode = opcode,
            .mnemonic = "SPLIT",
            .description = "Split execution for alternation",
            .operands = &[_]OpcodeInfo.OperandType{ .i32_offset, .i32_offset },
            .category = .control_flow,
        },
        .SAVE_START => .{
            .opcode = opcode,
            .mnemonic = "SAVE_START",
            .description = "Save capture group start position",
            .operands = &[_]OpcodeInfo.OperandType{.group_index},
            .category = .capture,
        },
        // Add more as needed...
        else => .{
            .opcode = opcode,
            .mnemonic = opcode.name(),
            .description = "No description available",
            .operands = &[_]OpcodeInfo.OperandType{},
            .category = opcode.category(),
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

test "Opcode: values match expected" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(Opcode.CHAR));
    try std.testing.expectEqual(@as(u8, 0x10), @intFromEnum(Opcode.MATCH));
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(Opcode.SAVE_START));
    try std.testing.expectEqual(@as(u8, 0x30), @intFromEnum(Opcode.BACK_REF));
    try std.testing.expectEqual(@as(u8, 0x40), @intFromEnum(Opcode.LINE_START));
    try std.testing.expectEqual(@as(u8, 0x50), @intFromEnum(Opcode.LOOKAHEAD));
}

test "Opcode: category classification" {
    try std.testing.expectEqual(OpcodeCategory.character_match, Opcode.CHAR.category());
    try std.testing.expectEqual(OpcodeCategory.control_flow, Opcode.MATCH.category());
    try std.testing.expectEqual(OpcodeCategory.capture, Opcode.SAVE_START.category());
    try std.testing.expectEqual(OpcodeCategory.backreference, Opcode.BACK_REF.category());
    try std.testing.expectEqual(OpcodeCategory.assertion, Opcode.LINE_START.category());
    try std.testing.expectEqual(OpcodeCategory.lookaround, Opcode.LOOKAHEAD.category());
}

test "Opcode: size calculations" {
    try std.testing.expectEqual(@as(u8, 1), Opcode.CHAR.size());
    try std.testing.expectEqual(@as(u8, 1), Opcode.MATCH.size());
    try std.testing.expectEqual(@as(u8, 2), Opcode.SAVE_START.size());
    try std.testing.expectEqual(@as(u8, 5), Opcode.CHAR32.size());
    try std.testing.expectEqual(@as(u8, 9), Opcode.SPLIT.size());
}

test "Opcode: terminal check" {
    try std.testing.expect(Opcode.MATCH.isTerminal());
    try std.testing.expect(!Opcode.CHAR.isTerminal());
    try std.testing.expect(!Opcode.SPLIT.isTerminal());
}

test "Opcode: control flow check" {
    try std.testing.expect(Opcode.MATCH.isControlFlow());
    try std.testing.expect(Opcode.GOTO.isControlFlow());
    try std.testing.expect(Opcode.SPLIT.isControlFlow());
    try std.testing.expect(!Opcode.CHAR.isControlFlow());
    try std.testing.expect(!Opcode.SAVE_START.isControlFlow());
}

test "Opcode: backtracking check" {
    try std.testing.expect(Opcode.SPLIT.canBacktrack());
    try std.testing.expect(Opcode.LOOP.canBacktrack());
    try std.testing.expect(!Opcode.MATCH.canBacktrack());
    try std.testing.expect(!Opcode.CHAR.canBacktrack());
}

test "Opcode: name retrieval" {
    try std.testing.expectEqualStrings("CHAR", Opcode.CHAR.name());
    try std.testing.expectEqualStrings("MATCH", Opcode.MATCH.name());
    try std.testing.expectEqualStrings("SPLIT", Opcode.SPLIT.name());
}

test "OpcodeInfo: basic retrieval" {
    const info = getOpcodeInfo(.CHAR32);
    try std.testing.expectEqual(Opcode.CHAR32, info.opcode);
    try std.testing.expectEqualStrings("CHAR32", info.mnemonic);
    try std.testing.expectEqual(@as(usize, 1), info.operands.len);
}

test "OpcodeCategory: all categories represented" {
    const categories = [_]OpcodeCategory{
        .character_match,
        .control_flow,
        .capture,
        .backreference,
        .assertion,
        .lookaround,
        .special,
        .unknown,
    };
    _ = categories;
}
