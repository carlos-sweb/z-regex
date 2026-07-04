//! Bytecode reader and validator
//!
//! This module provides utilities for reading, validating, and
//! disassembling bytecode.

const std = @import("std");
const Allocator = std.mem.Allocator;
const opcodes = @import("opcodes.zig");
const format = @import("format.zig");
const Opcode = opcodes.Opcode;
const Instruction = format.Instruction;

/// Bytecode reader for iterating through instructions
pub const BytecodeReader = struct {
    bytecode: []const u8,
    offset: usize,

    const Self = @This();

    /// Initialize a reader
    pub fn init(bytecode: []const u8) Self {
        return .{
            .bytecode = bytecode,
            .offset = 0,
        };
    }

    /// Check if there are more instructions
    pub fn hasMore(self: Self) bool {
        return self.offset < self.bytecode.len;
    }

    /// Get current offset
    pub fn currentOffset(self: Self) usize {
        return self.offset;
    }

    /// Peek at the next opcode without advancing
    pub fn peekOpcode(self: Self) ?Opcode {
        if (self.offset >= self.bytecode.len) return null;
        return @enumFromInt(self.bytecode[self.offset]);
    }

    /// Read the next instruction
    pub fn next(self: *Self) !?Instruction {
        if (!self.hasMore()) return null;

        const inst = try format.decodeInstruction(self.bytecode, self.offset);
        self.offset += inst.size;
        return inst;
    }

    /// Reset to the beginning
    pub fn reset(self: *Self) void {
        self.offset = 0;
    }

    /// Seek to a specific offset
    pub fn seek(self: *Self, offset: usize) !void {
        if (offset > self.bytecode.len) return error.InvalidOffset;
        self.offset = offset;
    }
};

/// Validate bytecode structure
pub fn validate(bytecode: []const u8) !void {
    var reader = BytecodeReader.init(bytecode);

    var has_match = false;

    while (try reader.next()) |inst| {
        // Check for terminal instruction
        if (inst.opcode.isTerminal()) {
            has_match = true;
        }

        // Validate jump targets are within bounds
        if (inst.opcode.isControlFlow()) {
            switch (inst.opcode) {
                .GOTO => {
                    const offset = @as(i32, @bitCast(inst.operands[0]));
                    const target = @as(i32, @intCast(reader.offset)) + offset;
                    if (target < 0 or target > bytecode.len) {
                        return error.InvalidJumpTarget;
                    }
                },
                .SPLIT, .SPLIT_GREEDY, .SPLIT_LAZY => {
                    const offset1 = @as(i32, @bitCast(inst.operands[0]));
                    const offset2 = @as(i32, @bitCast(inst.operands[1]));

                    const target1 = @as(i32, @intCast(reader.offset)) + offset1;
                    const target2 = @as(i32, @intCast(reader.offset)) + offset2;

                    if (target1 < 0 or target1 > bytecode.len) {
                        return error.InvalidJumpTarget;
                    }
                    if (target2 < 0 or target2 > bytecode.len) {
                        return error.InvalidJumpTarget;
                    }
                },
                else => {},
            }
        }
    }

    // Bytecode should end with a terminal instruction
    if (!has_match) {
        return error.MissingTerminalInstruction;
    }
}

/// Disassemble bytecode to human-readable format
pub fn disassemble(bytecode: []const u8, writer: anytype) !void {
    var reader = BytecodeReader.init(bytecode);

    while (try reader.next()) |inst| {
        const offset = reader.offset - inst.size;
        try writer.print("{x:04}: {s}", .{ offset, inst.opcode.name() });

        // Print operands
        if (inst.operand_count > 0) {
            try writer.writeAll(" ");
            for (inst.operands[0..inst.operand_count], 0..) |operand, i| {
                if (i > 0) try writer.writeAll(", ");

                // Format based on opcode
                switch (inst.opcode) {
                    .CHAR32 => {
                        // Print as character if printable
                        if (operand < 128 and std.ascii.isPrint(@intCast(operand))) {
                            try writer.print("'{c}'", .{@as(u8, @intCast(operand))});
                        } else {
                            try writer.print("U+{X:04}", .{operand});
                        }
                    },
                    .GOTO, .SPLIT, .SPLIT_GREEDY, .SPLIT_LAZY => {
                        // Print as signed offset
                        const signed = @as(i32, @bitCast(operand));
                        const target = @as(i32, @intCast(offset)) + signed;
                        try writer.print("{d} -> {x:04}", .{ signed, target });
                    },
                    else => {
                        try writer.print("{}", .{operand});
                    },
                }
            }
        }

        try writer.writeAll("\n");
    }
}

// =============================================================================
// Tests
// =============================================================================

test "BytecodeReader: basic iteration" {
    // Simple bytecode: MATCH
    const bytecode = [_]u8{0x10};

    var reader = BytecodeReader.init(&bytecode);

    try std.testing.expect(reader.hasMore());

    const inst = (try reader.next()).?;
    try std.testing.expectEqual(Opcode.MATCH, inst.opcode);

    try std.testing.expect(!reader.hasMore());
    try std.testing.expectEqual(@as(?Instruction, null), try reader.next());
}

test "BytecodeReader: multiple instructions" {
    // SAVE_START(0), CHAR32('a'), SAVE_END(0), MATCH
    var bytecode: [8]u8 = undefined;
    bytecode[0] = 0x20; // SAVE_START
    bytecode[1] = 0;

    bytecode[2] = 0x01; // CHAR32
    std.mem.writeInt(u32, bytecode[3..7], 'a', .little);

    bytecode[7] = 0x10; // MATCH

    var reader = BytecodeReader.init(&bytecode);

    const inst1 = (try reader.next()).?;
    try std.testing.expectEqual(Opcode.SAVE_START, inst1.opcode);

    const inst2 = (try reader.next()).?;
    try std.testing.expectEqual(Opcode.CHAR32, inst2.opcode);

    const inst3 = (try reader.next()).?;
    try std.testing.expectEqual(Opcode.MATCH, inst3.opcode);

    try std.testing.expect(!reader.hasMore());
}

test "BytecodeReader: peek and reset" {
    const bytecode = [_]u8{0x10}; // MATCH

    var reader = BytecodeReader.init(&bytecode);

    const peeked = reader.peekOpcode();
    try std.testing.expectEqual(Opcode.MATCH, peeked.?);

    // Peek doesn't advance
    try std.testing.expect(reader.hasMore());

    _ = try reader.next();
    try std.testing.expect(!reader.hasMore());

    // Reset
    reader.reset();
    try std.testing.expect(reader.hasMore());
}

test "BytecodeReader: seek" {
    const bytecode = [_]u8{ 0x10, 0x20, 0x00, 0x10 };

    var reader = BytecodeReader.init(&bytecode);

    try reader.seek(2);
    try std.testing.expectEqual(@as(usize, 2), reader.currentOffset());

    const inst = (try reader.next()).?;
    try std.testing.expectEqual(@as(u8, 0), inst.operands[0]);
}

test "validate: valid bytecode" {
    const bytecode = [_]u8{
        0x01, 0x61, 0x00, 0x00, 0x00, // CHAR32 'a'
        0x10, // MATCH
    };

    try validate(&bytecode);
}

test "validate: missing terminal" {
    const bytecode = [_]u8{
        0x01, 0x61, 0x00, 0x00, 0x00, // CHAR32 'a'
    };

    try std.testing.expectError(error.MissingTerminalInstruction, validate(&bytecode));
}

test "validate: invalid jump target" {
    var bytecode: [10]u8 = undefined;
    bytecode[0] = 0x11; // GOTO
    // Jump way past end of bytecode
    std.mem.writeInt(i32, bytecode[1..5], 1000, .little);
    bytecode[5] = 0x10; // MATCH

    try std.testing.expectError(error.InvalidJumpTarget, validate(&bytecode));
}

test "disassemble: simple program" {
    const bytecode = [_]u8{
        0x01, 0x61, 0x00, 0x00, 0x00, // CHAR32 'a'
        0x10, // MATCH
    };

    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try disassemble(&bytecode, &aw.writer);

    const output = aw.written();

    // Check output contains opcode names
    try std.testing.expect(std.mem.indexOf(u8, output, "CHAR32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "MATCH") != null);

    // Check offset is printed
    try std.testing.expect(std.mem.indexOf(u8, output, "0000") != null);
}

test "disassemble: with jumps" {
    var bytecode: [10]u8 = undefined;
    bytecode[0] = 0x11; // GOTO (opcode + i32 = 5 bytes total)
    std.mem.writeInt(i32, bytecode[1..5], 5, .little); // Jump forward 5 bytes
    bytecode[5] = 0x10; // MATCH at offset 5

    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const bytecode_slice = bytecode[0..6];
    try disassemble(bytecode_slice, &aw.writer);

    const output = aw.written();

    // Should show jump target
    try std.testing.expect(std.mem.indexOf(u8, output, "GOTO") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "->") != null);
}

test "disassemble: character representation" {
    var bytecode: [6]u8 = undefined;
    bytecode[0] = 0x01; // CHAR32
    std.mem.writeInt(u32, bytecode[1..5], 'A', .little);
    bytecode[5] = 0x10; // MATCH

    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try disassemble(&bytecode, &aw.writer);

    const output = aw.written();

    // Should print as character
    try std.testing.expect(std.mem.indexOf(u8, output, "'A'") != null);
}
