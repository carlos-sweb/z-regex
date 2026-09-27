//! Bytecode writer for code generation
//!
//! This module provides a high-level API for generating bytecode
//! with support for labels, forward references, and patching.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DynBuf = @import("utils").dynbuf.DynBuf;
const opcodes = @import("opcodes.zig");
const format = @import("format.zig");
const Opcode = opcodes.Opcode;
const Instruction = format.Instruction;

/// Label for forward/backward jumps
pub const Label = struct {
    id: u32,
    position: ?usize, // null if not yet defined
};

/// Bytecode writer
pub const BytecodeWriter = struct {
    /// Output buffer
    code: DynBuf(u8),

    /// Label counter for unique IDs
    next_label_id: u32,

    /// Label positions (label_id -> bytecode offset)
    label_positions: std.AutoHashMapUnmanaged(u32, usize),

    /// Patches to apply when labels are defined
    /// (bytecode_offset, label_id, patch_size)
    patches: std.ArrayListUnmanaged(Patch),

    /// Allocator
    allocator: Allocator,

    const Self = @This();

    const Patch = struct {
        offset: usize, // Where to patch in bytecode
        label_id: u32, // Which label to patch with
        size: u8, // Size of patch (4 for i32)
        instruction_pc: usize, // PC of the instruction containing this operand
    };

    /// Initialize a new bytecode writer
    pub fn init(allocator: Allocator) Self {
        return .{
            .code = DynBuf(u8).init(allocator),
            .next_label_id = 0,
            .label_positions = .{},
            .patches = .empty,
            .allocator = allocator,
        };
    }

    /// Free all resources
    pub fn deinit(self: *Self) void {
        self.code.deinit();
        self.label_positions.deinit(self.allocator);
        self.patches.deinit(self.allocator);
    }

    /// Get the current bytecode offset
    pub fn offset(self: Self) usize {
        return self.code.len();
    }

    /// Create a new undefined label
    pub fn createLabel(self: *Self) !Label {
        const id = self.next_label_id;
        self.next_label_id += 1;
        return Label{ .id = id, .position = null };
    }

    /// Define a label at the current position
    pub fn defineLabel(self: *Self, label: *Label) !void {
        const pos = self.code.len();
        label.position = pos;
        try self.label_positions.put(self.allocator, label.id, pos);

        // Apply pending patches for this label
        try self.applyPatches(label.id);
    }

    /// Emit a simple instruction (no operands)
    pub fn emitSimple(self: *Self, opcode: Opcode) !void {
        const inst = Instruction.simple(opcode);
        try self.emitInstruction(inst);
    }

    /// Emit instruction with one operand
    pub fn emit1(self: *Self, opcode: Opcode, operand: u32) !void {
        const inst = Instruction.with1(opcode, operand);
        try self.emitInstruction(inst);
    }

    /// Emit instruction with two operands
    pub fn emit2(self: *Self, opcode: Opcode, op1: u32, op2: u32) !void {
        const inst = Instruction.with2(opcode, op1, op2);
        try self.emitInstruction(inst);
    }

    /// Emit CHAR_CLASS or CHAR_CLASS_INV with inline bit table
    pub fn emitCharClass(self: *Self, opcode: Opcode, table: *const [32]u8) !void {
        // Emit opcode
        try self.code.append(@intFromEnum(opcode));
        // Emit 32-byte bit table
        try self.code.appendSlice(table);
    }

    /// Emit a jump to a label
    pub fn emitJump(self: *Self, opcode: Opcode, target: Label) !void {
        const current_pos = self.code.len();

        if (target.position) |target_pos| {
            // Label already defined, calculate offset
            const jump_offset = @as(i32, @intCast(target_pos)) - @as(i32, @intCast(current_pos));
            try self.emit1(opcode, @bitCast(@as(u32, @bitCast(jump_offset))));
        } else {
            // Label not yet defined, emit placeholder and add patch
            try self.emit1(opcode, 0);
            try self.patches.append(self.allocator, .{
                .offset = current_pos + 1, // +1 to skip opcode byte
                .label_id = target.id,
                .size = 4,
                .instruction_pc = current_pos,
            });
        }
    }

    /// Emit a split instruction (two labels)
    pub fn emitSplit(self: *Self, opcode: Opcode, label1: Label, label2: Label) !void {
        const current_pos = self.code.len();

        // Calculate or defer both offsets
        const offset1 = if (label1.position) |pos|
            @as(i32, @intCast(pos)) - @as(i32, @intCast(current_pos))
        else
            0;

        const offset2 = if (label2.position) |pos|
            @as(i32, @intCast(pos)) - @as(i32, @intCast(current_pos))
        else
            0;

        try self.emit2(opcode, @bitCast(offset1), @bitCast(offset2));

        // Add patches if needed
        if (label1.position == null) {
            try self.patches.append(self.allocator, .{
                .offset = current_pos + 1,
                .label_id = label1.id,
                .size = 4,
                .instruction_pc = current_pos,
            });
        }
        if (label2.position == null) {
            try self.patches.append(self.allocator, .{
                .offset = current_pos + 5,
                .label_id = label2.id,
                .size = 4,
                .instruction_pc = current_pos,
            });
        }
    }

    /// Emit an instruction directly
    fn emitInstruction(self: *Self, inst: Instruction) !void {
        var buffer: [16]u8 = undefined;
        const size = try format.encodeInstruction(inst, &buffer);
        try self.code.appendSlice(buffer[0..size]);
    }

    /// Apply all pending patches for a label
    fn applyPatches(self: *Self, label_id: u32) !void {
        const target_pos = self.label_positions.get(label_id) orelse return;

        var i: usize = 0;
        while (i < self.patches.items.len) {
            const patch = self.patches.items[i];
            if (patch.label_id == label_id) {
                // Calculate offset from instruction PC to target
                const patch_offset = @as(i32, @intCast(target_pos)) - @as(i32, @intCast(patch.instruction_pc));

                // Write offset at patch location
                std.mem.writeInt(i32, self.code.items.ptr[patch.offset..][0..4], patch_offset, .little);

                // Remove this patch
                _ = self.patches.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Finalize and return the bytecode
    /// Verifies all patches are applied
    pub fn finalize(self: *Self) ![]const u8 {
        if (self.patches.items.len > 0) {
            return error.UnresolvedLabels;
        }
        return self.code.items;
    }

    /// Get bytecode without consuming writer
    pub fn bytecode(self: Self) []const u8 {
        return self.code.items;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BytecodeWriter: init and deinit" {
    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    try std.testing.expectEqual(@as(usize, 0), writer.offset());
}

test "BytecodeWriter: emit simple instruction" {
    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    try writer.emitSimple(.MATCH);

    const code = writer.bytecode();
    try std.testing.expectEqual(@as(usize, 1), code.len);
    try std.testing.expectEqual(@as(u8, 0x10), code[0]);
}

test "BytecodeWriter: emit instruction with operand" {
    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    try writer.emit1(.SAVE_START, 5);

    const code = writer.bytecode();
    try std.testing.expectEqual(@as(usize, 3), code.len); // opcode + u16 group
    try std.testing.expectEqual(@as(u8, 0x20), code[0]);
    try std.testing.expectEqual(@as(u8, 5), code[1]);
    try std.testing.expectEqual(@as(u8, 0), code[2]);
}

test "BytecodeWriter: emit instruction with 2 operands" {
    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    try writer.emit2(.CHAR_RANGE, 'a', 'z');

    const code = writer.bytecode();
    try std.testing.expectEqual(@as(usize, 9), code.len);
    try std.testing.expectEqual(@as(u8, 0x03), code[0]);
}

test "BytecodeWriter: labels - forward reference" {
    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var target = try writer.createLabel();

    // Emit jump to undefined label
    try writer.emitJump(.GOTO, target);

    // Define label
    try writer.defineLabel(&target);

    // Emit MATCH at label
    try writer.emitSimple(.MATCH);

    const code = try writer.finalize();

    // Check jump was patched correctly
    // GOTO is at offset 0, MATCH is at offset 5
    // Offset should be 5 - 0 = 5
    const jump_offset = std.mem.readInt(i32, code[1..5], .little);
    try std.testing.expectEqual(@as(i32, 5), jump_offset);
}

test "BytecodeWriter: labels - backward reference" {
    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var loop_start = try writer.createLabel();

    // Define label at start
    try writer.defineLabel(&loop_start);

    // Emit some instruction
    try writer.emit1(.CHAR32, 'a');

    // Jump back to start
    try writer.emitJump(.GOTO, loop_start);

    const code = try writer.finalize();

    // Jump is at offset 5, target is at offset 0
    // Offset should be 0 - 5 = -5
    const jump_offset = std.mem.readInt(i32, code[6..10], .little);
    try std.testing.expectEqual(@as(i32, -5), jump_offset);
}

test "BytecodeWriter: split instruction" {
    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    var label1 = try writer.createLabel();
    var label2 = try writer.createLabel();

    try writer.emitSplit(.SPLIT, label1, label2);

    try writer.defineLabel(&label1);
    try writer.emit1(.CHAR32, 'a');

    try writer.defineLabel(&label2);
    try writer.emit1(.CHAR32, 'b');

    _ = try writer.finalize();

    // Verify split instruction was patched
    // Both paths should have valid offsets
}

test "BytecodeWriter: finalize with unresolved labels" {
    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    const undefined_label = try writer.createLabel();
    try writer.emitJump(.GOTO, undefined_label);

    // Should fail because label is not defined
    try std.testing.expectError(error.UnresolvedLabels, writer.finalize());
}

test "BytecodeWriter: offset tracking" {
    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    try std.testing.expectEqual(@as(usize, 0), writer.offset());

    try writer.emitSimple(.MATCH); // 1 byte
    try std.testing.expectEqual(@as(usize, 1), writer.offset());

    try writer.emit1(.SAVE_START, 0); // 3 bytes (u16 group)
    try std.testing.expectEqual(@as(usize, 4), writer.offset());

    try writer.emit2(.CHAR_RANGE, 0, 0); // 9 bytes
    try std.testing.expectEqual(@as(usize, 13), writer.offset());
}

test "BytecodeWriter: complex program" {
    var writer = BytecodeWriter.init(std.testing.allocator);
    defer writer.deinit();

    // Build bytecode for pattern: (a|b)+
    // Simplified version

    var loop_start = try writer.createLabel();
    var alt_b = try writer.createLabel();
    var loop_end = try writer.createLabel();

    try writer.defineLabel(&loop_start);
    try writer.emitSplit(.SPLIT, alt_b, loop_end);

    // Match 'a'
    try writer.emit1(.CHAR32, 'a');
    try writer.emitJump(.GOTO, loop_start);

    // Match 'b'
    try writer.defineLabel(&alt_b);
    try writer.emit1(.CHAR32, 'b');
    try writer.emitJump(.GOTO, loop_start);

    try writer.defineLabel(&loop_end);
    try writer.emitSimple(.MATCH);

    const code = try writer.finalize();
    try std.testing.expect(code.len > 0);
}
