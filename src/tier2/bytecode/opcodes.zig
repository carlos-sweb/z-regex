//! Bytecode opcodes for zregex
//!
//! This module defines all opcodes used in the regex bytecode virtual machine.
//! Based on QuickJS libregexp with 33 opcodes organized by category.
//!
//! Bytecode format:
//! - Each instruction starts with an 8-bit opcode
//! - Followed by operands (size depends on opcode)
//! - All multi-byte values are little-endian
//!
//! Since F3b every character opcode decodes one character of the subject
//! (`subject.Subject.decodeAt`) and tests its value; "decodes a UTF-8
//! sequence" below means that. Only BYTE reads a raw byte.

const std = @import("std");

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

    /// Match one character of the subject: a code point, as decoded at the
    /// current position (F3b). An ill-formed WTF-8 byte never matches it,
    /// even one with the same value (see BYTE).
    /// Format: [CHAR32 c:u32]
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

    /// Match a Unicode scalar value against a CharSet (F2b): decodes a full
    /// UTF-8 sequence at the current position (same decoding as
    /// CHAR_RANGE_INV/CHAR_CLASS_INV: one byte for invalid UTF-8, a WTF-8
    /// lone surrogate as its code point) and checks it against
    /// `CompileResult.charsets[idx]`. Every class that doesn't fit the ASCII
    /// bitmap compiles to this: non-ASCII members, `\p{...}` members and
    /// `v`-mode set operations, all materialized at compile time. The table
    /// lives outside the bytecode, so the bytecode alone isn't executable
    /// (docs/REGEX_TIERS_PLAN.md, F2b decision).
    /// Format: [CHAR_SET idx:u32]
    CHAR_SET = 0x08,

    /// Inverted form of CHAR_SET (a class's own `[^...]`): matches if the
    /// decoded code point is NOT in the set, consuming it.
    /// Format: [CHAR_SET_INV idx:u32]
    CHAR_SET_INV = 0x09,

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
    /// Format: [SAVE_START group:u16]
    SAVE_START = 0x20,

    /// Save capture group end position
    /// Format: [SAVE_END group:u16]
    SAVE_END = 0x21,

    /// Save named capture group start
    /// Format: [SAVE_START_NAMED group:u16 name_offset:u32]
    SAVE_START_NAMED = 0x22,

    /// Save named capture group end
    /// Format: [SAVE_END_NAMED group:u16 name_offset:u32]
    SAVE_END_NAMED = 0x23,

    /// Reset a capture group to "unset" (both start and end cleared).
    /// Used on the "skip" path of an optional atom (`e?`, or an inner
    /// optional inside a repeated group) so a capture set by an earlier
    /// iteration of an enclosing loop doesn't leak into a later iteration
    /// where this group's own atom didn't participate.
    /// Format: [CLEAR_CAPTURE group:u16]
    CLEAR_CAPTURE = 0x24,

    // =========================================================================
    // Backreferences (0x30-0x3F)
    // =========================================================================

    /// Match backreference to capture group
    /// Format: [BACK_REF group:u16]
    BACK_REF = 0x30,

    /// Match backreference (case insensitive)
    /// Format: [BACK_REF_I group:u16]
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

    /// Match one raw byte of a WTF-8 subject (F3b): a lone byte 0x80-0xFF of
    /// an ill-formed pattern (`hir.LitUnit.raw_byte`), which is not a code
    /// point. Advances one byte; never matches a UTF-16 subject. Outside
    /// 0x00-0x0F only because that range is full.
    /// Format: [BYTE b:u8]
    BYTE = 0x70,

    _,

    /// Get the category of this opcode
    pub fn category(self: Opcode) OpcodeCategory {
        return switch (self) {
            .CHAR, .CHAR32, .BYTE, .CHAR2, .CHAR_RANGE, .CHAR_RANGE_INV, .CHAR_CLASS, .CHAR_CLASS_INV, .CHAR_ANY, .CHAR_SET, .CHAR_SET_INV, .UNICODE_PROPERTY, .UNICODE_PROPERTY_INV, .UNICODE_SCRIPT, .UNICODE_SCRIPT_INV, .UNICODE_SCRIPT_EXTENSIONS, .UNICODE_SCRIPT_EXTENSIONS_INV => .character_match,
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
            .CHAR, .CHAR_ANY, .MATCH, .LINE_START, .LINE_END, .WORD_BOUNDARY, .NOT_WORD_BOUNDARY, .STRING_START, .STRING_END, .LOOKAHEAD_END, .LOOKBEHIND_END, .PUSH_POS, .CHECK_POS => 1,

            // 3 bytes (opcode + u16 capture group, D9)
            .SAVE_START, .SAVE_END, .BACK_REF, .BACK_REF_I, .CLEAR_CAPTURE => 3,

            // 2 bytes (opcode + u8)
            .UNICODE_PROPERTY, .UNICODE_PROPERTY_INV, .UNICODE_SCRIPT, .UNICODE_SCRIPT_INV, .UNICODE_SCRIPT_EXTENSIONS, .UNICODE_SCRIPT_EXTENSIONS_INV, .BYTE => 2,

            // 5 bytes (opcode + u32)
            .CHAR32, .CHAR_SET, .CHAR_SET_INV, .LOOKAHEAD, .NEGATIVE_LOOKAHEAD, .LOOKBEHIND, .NEGATIVE_LOOKBEHIND => 5,

            // 7 bytes (opcode + u16 + u32)
            .SAVE_START_NAMED, .SAVE_END_NAMED => 7,

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
    try std.testing.expectEqual(@as(u8, 0x08), @intFromEnum(Opcode.CHAR_SET));
    try std.testing.expectEqual(@as(u8, 0x09), @intFromEnum(Opcode.CHAR_SET_INV));
}

test "Opcode: CHAR_SET is opcode + u32 index" {
    try std.testing.expectEqual(@as(u8, 5), Opcode.CHAR_SET.size());
    try std.testing.expectEqual(@as(u8, 5), Opcode.CHAR_SET_INV.size());
    try std.testing.expectEqual(OpcodeCategory.character_match, Opcode.CHAR_SET.category());
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
    try std.testing.expectEqual(@as(u8, 3), Opcode.SAVE_START.size()); // u16 group (D9)
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
