//! Bytecode format and encoding/decoding
//!
//! This module handles the serialization format for bytecode instructions.
//! All multi-byte values use little-endian encoding for portability.

const std = @import("std");
const opcodes = @import("opcodes.zig");
const Opcode = opcodes.Opcode;

/// A named capturing group's name and numeric group index. Capture groups
/// are always tracked by index at the bytecode/executor level; this is a
/// compile-time-only side table for resolving a name back to its index
/// (shared between the compiler, which produces it, and the high-level
/// matching API, which uses it to answer `getNamedCapture` lookups).
pub const NamedGroup = struct {
    name: []const u8,
    index: u8,
};

/// Instruction represents a decoded bytecode instruction
pub const Instruction = struct {
    /// The opcode
    opcode: Opcode,

    /// Instruction operands (max 2 for current opcodes)
    operands: [2]u32 = [_]u32{0} ** 2,

    /// Number of valid operands
    operand_count: u8 = 0,

    /// Size of this instruction in bytes
    size: u8,

    /// Create instruction with no operands
    pub fn simple(op: Opcode) Instruction {
        return .{
            .opcode = op,
            .size = op.size(),
        };
    }

    /// Create instruction with one operand
    pub fn with1(op: Opcode, operand1: u32) Instruction {
        return .{
            .opcode = op,
            .operands = [_]u32{ operand1, 0 },
            .operand_count = 1,
            .size = op.size(),
        };
    }

    /// Create instruction with two operands
    pub fn with2(op: Opcode, operand1: u32, operand2: u32) Instruction {
        return .{
            .opcode = op,
            .operands = [_]u32{ operand1, operand2 },
            .operand_count = 2,
            .size = op.size(),
        };
    }
};

/// Decode an instruction from bytecode at the given offset
pub fn decodeInstruction(bytecode: []const u8, offset: usize) !Instruction {
    if (offset >= bytecode.len) return error.UnexpectedEndOfBytecode;

    const opcode_byte = bytecode[offset];
    const opcode = @as(Opcode, @enumFromInt(opcode_byte));
    const inst_size = opcode.size();

    if (offset + inst_size > bytecode.len) return error.UnexpectedEndOfBytecode;

    var inst = Instruction{
        .opcode = opcode,
        .size = inst_size,
    };

    // Decode operands based on opcode
    switch (opcode) {
        // No operands
        .CHAR, .CHAR_ANY, .MATCH, .LINE_START, .LINE_END, .WORD_BOUNDARY, .NOT_WORD_BOUNDARY,
        .STRING_START, .STRING_END, .LOOKAHEAD_END, .LOOKBEHIND_END,
        .PUSH_POS, .CHECK_POS => {},

        // 1 byte operand
        .SAVE_START, .SAVE_END, .BACK_REF, .BACK_REF_I, .CLEAR_CAPTURE, .UNICODE_PROPERTY, .UNICODE_PROPERTY_INV, .UNICODE_SCRIPT, .UNICODE_SCRIPT_INV, .UNICODE_SCRIPT_EXTENSIONS, .UNICODE_SCRIPT_EXTENSIONS_INV => {
            inst.operands[0] = bytecode[offset + 1];
            inst.operand_count = 1;
        },

        // CHAR_CLASS and CHAR_CLASS_INV: 32 bytes inline bit table
        // Table data starts at offset + 1, executor reads it directly from bytecode
        .CHAR_CLASS, .CHAR_CLASS_INV => {
            // No operands to decode - executor will read table from bytecode
            inst.operand_count = 0;
        },

        // CHAR_CLASS_RANGES(_INV): count byte + fixed-size range table.
        // Executor reads both directly from bytecode.
        .CHAR_CLASS_RANGES, .CHAR_CLASS_RANGES_INV => {
            inst.operand_count = 0;
        },

        // CHAR_CLASS_UNICODE(_INV): range table + property-test table, both
        // fixed-size. Executor reads everything directly from bytecode, same
        // as CHAR_CLASS_RANGES(_INV).
        .CHAR_CLASS_UNICODE, .CHAR_CLASS_UNICODE_INV => {
            inst.operand_count = 0;
        },

        // CHAR_CLASS_SET_OP: op/result_negated bytes + two fixed-size
        // operand blocks. Executor reads everything directly from bytecode.
        .CHAR_CLASS_SET_OP => {
            inst.operand_count = 0;
        },

        // 4 byte operand (u32)
        .CHAR32, .LOOKAHEAD, .NEGATIVE_LOOKAHEAD, .LOOKBEHIND, .NEGATIVE_LOOKBEHIND => {
            inst.operands[0] = readU32(bytecode[offset + 1 ..]);
            inst.operand_count = 1;
        },

        // u8 + u32
        .SAVE_START_NAMED, .SAVE_END_NAMED => {
            inst.operands[0] = bytecode[offset + 1];
            inst.operands[1] = readU32(bytecode[offset + 2 ..]);
            inst.operand_count = 2;
        },

        // 2 * u32
        .CHAR2, .CHAR_RANGE, .CHAR_RANGE_INV => {
            inst.operands[0] = readU32(bytecode[offset + 1 ..]);
            inst.operands[1] = readU32(bytecode[offset + 5 ..]);
            inst.operand_count = 2;
        },

        // i32 (encoded as u32, reinterpret as needed)
        .GOTO => {
            inst.operands[0] = readU32(bytecode[offset + 1 ..]);
            inst.operand_count = 1;
        },

        // 2 * i32
        .SPLIT, .SPLIT_GREEDY, .SPLIT_LAZY, .SPLIT_POSSESSIVE => {
            inst.operands[0] = readU32(bytecode[offset + 1 ..]);
            inst.operands[1] = readU32(bytecode[offset + 5 ..]);
            inst.operand_count = 2;
        },

        // u8 + u32 + i32
        .LOOP => {
            inst.operands[0] = bytecode[offset + 1]; // counter index
            inst.operands[1] = readU32(bytecode[offset + 2 ..]); // max count
            // Note: offset is stored separately in actual implementation
            inst.operand_count = 2;
        },

        else => return error.UnknownOpcode,
    }

    return inst;
}

/// Encode an instruction to bytecode
pub fn encodeInstruction(inst: Instruction, buffer: []u8) !usize {
    if (buffer.len < inst.size) return error.BufferTooSmall;

    buffer[0] = @intFromEnum(inst.opcode);
    var pos: usize = 1;

    // Encode operands based on opcode
    switch (inst.opcode) {
        // No operands
        .CHAR, .CHAR_ANY, .MATCH, .LINE_START, .LINE_END, .WORD_BOUNDARY, .NOT_WORD_BOUNDARY,
        .STRING_START, .STRING_END, .LOOKAHEAD_END, .LOOKBEHIND_END,
        .PUSH_POS, .CHECK_POS, .CHAR_CLASS_RANGES, .CHAR_CLASS_RANGES_INV, .CHAR_CLASS_UNICODE, .CHAR_CLASS_UNICODE_INV, .CHAR_CLASS_SET_OP => {},

        // 1 byte operand
        .SAVE_START, .SAVE_END, .BACK_REF, .BACK_REF_I, .CLEAR_CAPTURE, .UNICODE_PROPERTY, .UNICODE_PROPERTY_INV, .UNICODE_SCRIPT, .UNICODE_SCRIPT_INV, .UNICODE_SCRIPT_EXTENSIONS, .UNICODE_SCRIPT_EXTENSIONS_INV => {
            buffer[pos] = @intCast(inst.operands[0]);
            pos += 1;
        },

        // 2 byte operand (u16)
        .CHAR_CLASS, .CHAR_CLASS_INV => {
            writeU16(buffer[pos..], @intCast(inst.operands[0]));
            pos += 2;
        },

        // 4 byte operand (u32)
        .CHAR32, .LOOKAHEAD, .NEGATIVE_LOOKAHEAD, .LOOKBEHIND, .NEGATIVE_LOOKBEHIND => {
            writeU32(buffer[pos..], inst.operands[0]);
            pos += 4;
        },

        // u8 + u32
        .SAVE_START_NAMED, .SAVE_END_NAMED => {
            buffer[pos] = @intCast(inst.operands[0]);
            pos += 1;
            writeU32(buffer[pos..], inst.operands[1]);
            pos += 4;
        },

        // 2 * u32
        .CHAR2, .CHAR_RANGE, .CHAR_RANGE_INV => {
            writeU32(buffer[pos..], inst.operands[0]);
            pos += 4;
            writeU32(buffer[pos..], inst.operands[1]);
            pos += 4;
        },

        // i32
        .GOTO => {
            writeU32(buffer[pos..], inst.operands[0]);
            pos += 4;
        },

        // 2 * i32
        .SPLIT, .SPLIT_GREEDY, .SPLIT_LAZY, .SPLIT_POSSESSIVE => {
            writeU32(buffer[pos..], inst.operands[0]);
            pos += 4;
            writeU32(buffer[pos..], inst.operands[1]);
            pos += 4;
        },

        // u8 + u32 + i32
        .LOOP => {
            buffer[pos] = @intCast(inst.operands[0]);
            pos += 1;
            writeU32(buffer[pos..], inst.operands[1]);
            pos += 4;
            // Offset would be written here in real implementation
            pos += 4;
        },

        else => return error.UnknownOpcode,
    }

    return pos;
}

/// Read a u16 in little-endian format
fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

/// Read a u32 in little-endian format
fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

/// Write a u16 in little-endian format
fn writeU16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .little);
}

/// Write a u32 in little-endian format
fn writeU32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
}

// =============================================================================
// Tests
// =============================================================================

test "Instruction: simple creation" {
    const inst = Instruction.simple(.MATCH);
    try std.testing.expectEqual(Opcode.MATCH, inst.opcode);
    try std.testing.expectEqual(@as(u8, 0), inst.operand_count);
    try std.testing.expectEqual(@as(u8, 1), inst.size);
}

test "Instruction: with1 creation" {
    const inst = Instruction.with1(.SAVE_START, 5);
    try std.testing.expectEqual(Opcode.SAVE_START, inst.opcode);
    try std.testing.expectEqual(@as(u8, 1), inst.operand_count);
    try std.testing.expectEqual(@as(u32, 5), inst.operands[0]);
}

test "Instruction: with2 creation" {
    const inst = Instruction.with2(.CHAR_RANGE, 'a', 'z');
    try std.testing.expectEqual(Opcode.CHAR_RANGE, inst.opcode);
    try std.testing.expectEqual(@as(u8, 2), inst.operand_count);
    try std.testing.expectEqual(@as(u32, 'a'), inst.operands[0]);
    try std.testing.expectEqual(@as(u32, 'z'), inst.operands[1]);
}

test "encode/decode: simple opcode" {
    const inst = Instruction.simple(.MATCH);
    var buffer: [10]u8 = undefined;

    const encoded_size = try encodeInstruction(inst, &buffer);
    try std.testing.expectEqual(@as(usize, 1), encoded_size);
    try std.testing.expectEqual(@as(u8, 0x10), buffer[0]);

    const decoded = try decodeInstruction(&buffer, 0);
    try std.testing.expectEqual(Opcode.MATCH, decoded.opcode);
    try std.testing.expectEqual(@as(u8, 0), decoded.operand_count);
}

test "encode/decode: opcode with u8 operand" {
    const inst = Instruction.with1(.SAVE_START, 3);
    var buffer: [10]u8 = undefined;

    const encoded_size = try encodeInstruction(inst, &buffer);
    try std.testing.expectEqual(@as(usize, 2), encoded_size);

    const decoded = try decodeInstruction(&buffer, 0);
    try std.testing.expectEqual(Opcode.SAVE_START, decoded.opcode);
    try std.testing.expectEqual(@as(u8, 1), decoded.operand_count);
    try std.testing.expectEqual(@as(u32, 3), decoded.operands[0]);
}

test "encode/decode: opcode with u32 operand" {
    const inst = Instruction.with1(.CHAR32, 0x1F600); // 😀
    var buffer: [10]u8 = undefined;

    const encoded_size = try encodeInstruction(inst, &buffer);
    try std.testing.expectEqual(@as(usize, 5), encoded_size);

    const decoded = try decodeInstruction(&buffer, 0);
    try std.testing.expectEqual(Opcode.CHAR32, decoded.opcode);
    try std.testing.expectEqual(@as(u8, 1), decoded.operand_count);
    try std.testing.expectEqual(@as(u32, 0x1F600), decoded.operands[0]);
}

test "encode/decode: opcode with 2 u32 operands" {
    const inst = Instruction.with2(.CHAR_RANGE, 'A', 'Z');
    var buffer: [10]u8 = undefined;

    const encoded_size = try encodeInstruction(inst, &buffer);
    try std.testing.expectEqual(@as(usize, 9), encoded_size);

    const decoded = try decodeInstruction(&buffer, 0);
    try std.testing.expectEqual(Opcode.CHAR_RANGE, decoded.opcode);
    try std.testing.expectEqual(@as(u8, 2), decoded.operand_count);
    try std.testing.expectEqual(@as(u32, 'A'), decoded.operands[0]);
    try std.testing.expectEqual(@as(u32, 'Z'), decoded.operands[1]);
}

test "encode: buffer too small" {
    const inst = Instruction.with2(.CHAR_RANGE, 'a', 'z');
    var buffer: [5]u8 = undefined;

    try std.testing.expectError(error.BufferTooSmall, encodeInstruction(inst, &buffer));
}

test "decode: unexpected end of bytecode" {
    var buffer: [1]u8 = .{@intFromEnum(Opcode.CHAR32)};

    try std.testing.expectError(error.UnexpectedEndOfBytecode, decodeInstruction(&buffer, 0));
}

test "readU16/writeU16: round trip" {
    var buffer: [2]u8 = undefined;
    writeU16(&buffer, 0xABCD);
    const value = readU16(&buffer);
    try std.testing.expectEqual(@as(u16, 0xABCD), value);
}

test "readU32/writeU32: round trip" {
    var buffer: [4]u8 = undefined;
    writeU32(&buffer, 0x12345678);
    const value = readU32(&buffer);
    try std.testing.expectEqual(@as(u32, 0x12345678), value);
}

test "little-endian encoding" {
    var buffer: [4]u8 = undefined;
    writeU32(&buffer, 0x12345678);

    // Little-endian: least significant byte first
    try std.testing.expectEqual(@as(u8, 0x78), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0x56), buffer[1]);
    try std.testing.expectEqual(@as(u8, 0x34), buffer[2]);
    try std.testing.expectEqual(@as(u8, 0x12), buffer[3]);
}
