//! Bit table para clases de caracteres
//!
//! Este módulo proporciona una estructura eficiente para representar
//! conjuntos de caracteres usando un bit table de 256 bits (32 bytes).

const std = @import("std");

/// Bit table para 256 caracteres (ASCII/Latin-1)
/// Cada bit representa si un carácter está en el conjunto
pub const BitTable = struct {
    /// 256 bits = 32 bytes
    bits: [32]u8 = @splat(0),

    const Self = @This();

    /// Crear una tabla vacía
    pub fn init() Self {
        return .{};
    }

    /// Establecer un carácter como presente en la clase
    pub fn set(self: *Self, char: u8) void {
        const byte_idx = char / 8;
        const bit_idx = @as(u3, @intCast(char % 8));
        self.bits[byte_idx] |= (@as(u8, 1) << bit_idx);
    }

    /// Verificar si un carácter está en la clase
    pub fn contains(self: Self, char: u8) bool {
        const byte_idx = char / 8;
        const bit_idx = @as(u3, @intCast(char % 8));
        return (self.bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    /// Agregar un rango de caracteres
    pub fn addRange(self: *Self, start: u8, end: u8) void {
        var c = start;
        while (c <= end) : (c += 1) {
            self.set(c);
            if (c == end) break; // Evitar overflow en u8
        }
    }

    /// Invertir todos los bits (para clases negadas)
    pub fn invert(self: *Self) void {
        for (&self.bits) |*byte| {
            byte.* = ~byte.*;
        }
    }

    /// Verificar si la tabla está vacía
    pub fn isEmpty(self: Self) bool {
        for (self.bits) |byte| {
            if (byte != 0) return false;
        }
        return true;
    }

    /// Contar cuántos caracteres están en la clase
    pub fn count(self: Self) usize {
        var total: usize = 0;
        for (self.bits) |byte| {
            total += @popCount(byte);
        }
        return total;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BitTable: set and contains" {
    var table = BitTable.init();

    try std.testing.expect(!table.contains('a'));

    table.set('a');
    try std.testing.expect(table.contains('a'));
    try std.testing.expect(!table.contains('b'));

    table.set('b');
    try std.testing.expect(table.contains('a'));
    try std.testing.expect(table.contains('b'));
}

test "BitTable: addRange" {
    var table = BitTable.init();

    table.addRange('a', 'z');

    try std.testing.expect(table.contains('a'));
    try std.testing.expect(table.contains('m'));
    try std.testing.expect(table.contains('z'));
    try std.testing.expect(!table.contains('A'));
    try std.testing.expect(!table.contains('0'));
}

test "BitTable: invert" {
    var table = BitTable.init();

    table.set('a');
    try std.testing.expect(table.contains('a'));
    try std.testing.expect(!table.contains('b'));

    table.invert();
    try std.testing.expect(!table.contains('a'));
    try std.testing.expect(table.contains('b'));
}

test "BitTable: isEmpty" {
    var table = BitTable.init();
    try std.testing.expect(table.isEmpty());

    table.set('x');
    try std.testing.expect(!table.isEmpty());
}

test "BitTable: count" {
    var table = BitTable.init();
    try std.testing.expectEqual(@as(usize, 0), table.count());

    table.set('a');
    try std.testing.expectEqual(@as(usize, 1), table.count());

    table.addRange('0', '9'); // 10 dígitos
    try std.testing.expectEqual(@as(usize, 11), table.count());
}

test "BitTable: ejemplo completo - \\w" {
    var table = BitTable.init();

    // \w = [a-zA-Z0-9_]
    table.addRange('a', 'z');
    table.addRange('A', 'Z');
    table.addRange('0', '9');
    table.set('_');

    // Verificar word characters
    try std.testing.expect(table.contains('a'));
    try std.testing.expect(table.contains('Z'));
    try std.testing.expect(table.contains('5'));
    try std.testing.expect(table.contains('_'));

    // Verificar non-word characters
    try std.testing.expect(!table.contains(' '));
    try std.testing.expect(!table.contains('!'));
    try std.testing.expect(!table.contains('-'));
}

test "BitTable: ejemplo completo - \\W (invertido)" {
    var table = BitTable.init();

    // \W = [^a-zA-Z0-9_]
    table.addRange('a', 'z');
    table.addRange('A', 'Z');
    table.addRange('0', '9');
    table.set('_');
    table.invert(); // Invertir

    // Verificar non-word characters
    try std.testing.expect(table.contains(' '));
    try std.testing.expect(table.contains('!'));
    try std.testing.expect(table.contains('-'));

    // Verificar word characters (no deberían estar)
    try std.testing.expect(!table.contains('a'));
    try std.testing.expect(!table.contains('Z'));
    try std.testing.expect(!table.contains('5'));
    try std.testing.expect(!table.contains('_'));
}
