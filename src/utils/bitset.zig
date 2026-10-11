//! Bit set implementation for fast character lookups
//!
//! This module provides efficient bit set operations used for
//! character classes in regular expressions. Supports both ASCII
//! and Unicode character ranges.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Fixed-size bit set for ASCII characters (0-255)
pub const BitSet256 = struct {
    bits: [4]u64 = @splat(0), // 4 * 64 = 256 bits

    const Self = @This();

    /// Initialize an empty bit set
    pub fn init() Self {
        return .{};
    }

    /// Initialize with all bits set
    pub fn initFull() Self {
        return .{ .bits = @splat(~@as(u64, 0)) };
    }

    /// Set a bit at the specified index
    pub fn set(self: *Self, index: u8) void {
        const word_index = index >> 6; // Divide by 64
        const bit_index = @as(u6, @truncate(index));
        self.bits[word_index] |= @as(u64, 1) << bit_index;
    }

    /// Clear a bit at the specified index
    pub fn unset(self: *Self, index: u8) void {
        const word_index = index >> 6;
        const bit_index = @as(u6, @truncate(index));
        self.bits[word_index] &= ~(@as(u64, 1) << bit_index);
    }

    /// Check if a bit is set
    pub fn isSet(self: Self, index: u8) bool {
        const word_index = index >> 6;
        const bit_index = @as(u6, @truncate(index));
        return (self.bits[word_index] & (@as(u64, 1) << bit_index)) != 0;
    }

    /// Set a range of bits [start, end] inclusive
    pub fn setRange(self: *Self, start: u8, end: u8) void {
        var i = start;
        while (i <= end) : (i += 1) {
            self.set(i);
            if (i == 255) break; // Prevent overflow
        }
    }

    /// Clear all bits
    pub fn clearAll(self: *Self) void {
        self.bits = @splat(0);
    }

    /// Set all bits
    pub fn setAll(self: *Self) void {
        self.bits = @splat(~@as(u64, 0));
    }

    /// Union with another bit set (self |= other)
    pub fn unionWith(self: *Self, other: Self) void {
        inline for (0..4) |i| {
            self.bits[i] |= other.bits[i];
        }
    }

    /// Intersect with another bit set (self &= other)
    pub fn intersectWith(self: *Self, other: Self) void {
        inline for (0..4) |i| {
            self.bits[i] &= other.bits[i];
        }
    }

    /// Subtract another bit set (self &= ~other)
    pub fn subtractWith(self: *Self, other: Self) void {
        inline for (0..4) |i| {
            self.bits[i] &= ~other.bits[i];
        }
    }

    /// Complement all bits (self = ~self)
    pub fn complement(self: *Self) void {
        inline for (0..4) |i| {
            self.bits[i] = ~self.bits[i];
        }
    }

    /// Check if the set is empty
    pub fn isEmpty(self: Self) bool {
        inline for (0..4) |i| {
            if (self.bits[i] != 0) return false;
        }
        return true;
    }

    /// Count the number of set bits
    pub fn count(self: Self) u32 {
        var total: u32 = 0;
        inline for (0..4) |i| {
            total += @popCount(self.bits[i]);
        }
        return total;
    }

    /// Check if this set equals another
    pub fn eql(self: Self, other: Self) bool {
        inline for (0..4) |i| {
            if (self.bits[i] != other.bits[i]) return false;
        }
        return true;
    }

    /// Clone the bit set
    pub fn clone(self: Self) Self {
        return self;
    }
};

/// Dynamic bit set for larger character ranges
pub const DynBitSet = struct {
    words: []u64,
    allocator: Allocator,

    const Self = @This();
    const bits_per_word = 64;

    /// Initialize a dynamic bit set with specified bit capacity
    pub fn init(allocator: Allocator, bit_capacity: usize) !Self {
        const word_count = (bit_capacity + bits_per_word - 1) / bits_per_word;
        const words = try allocator.alloc(u64, word_count);
        @memset(words, 0);

        return .{
            .words = words,
            .allocator = allocator,
        };
    }

    /// Free the bit set
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.words);
        self.* = undefined;
    }

    /// Get the capacity in bits
    pub fn capacity(self: Self) usize {
        return self.words.len * bits_per_word;
    }

    /// Set a bit at the specified index
    pub fn set(self: *Self, index: usize) !void {
        const word_index = index / bits_per_word;
        if (word_index >= self.words.len) return error.IndexOutOfBounds;

        const bit_index = @as(u6, @truncate(index % bits_per_word));
        self.words[word_index] |= @as(u64, 1) << bit_index;
    }

    /// Clear a bit at the specified index
    pub fn unset(self: *Self, index: usize) !void {
        const word_index = index / bits_per_word;
        if (word_index >= self.words.len) return error.IndexOutOfBounds;

        const bit_index = @as(u6, @truncate(index % bits_per_word));
        self.words[word_index] &= ~(@as(u64, 1) << bit_index);
    }

    /// Check if a bit is set
    pub fn isSet(self: Self, index: usize) bool {
        const word_index = index / bits_per_word;
        if (word_index >= self.words.len) return false;

        const bit_index = @as(u6, @truncate(index % bits_per_word));
        return (self.words[word_index] & (@as(u64, 1) << bit_index)) != 0;
    }

    /// Clear all bits
    pub fn clearAll(self: *Self) void {
        @memset(self.words, 0);
    }

    /// Set all bits
    pub fn setAll(self: *Self) void {
        @memset(self.words, ~@as(u64, 0));
    }

    /// Count the number of set bits
    pub fn count(self: Self) usize {
        var total: usize = 0;
        for (self.words) |word| {
            total += @popCount(word);
        }
        return total;
    }

    /// Check if the set is empty
    pub fn isEmpty(self: Self) bool {
        for (self.words) |word| {
            if (word != 0) return false;
        }
        return true;
    }

    /// Clone the bit set
    pub fn clone(self: Self, allocator: Allocator) !Self {
        const words = try allocator.alloc(u64, self.words.len);
        @memcpy(words, self.words);
        return .{
            .words = words,
            .allocator = allocator,
        };
    }
};

// =============================================================================
// Common Character Classes
// =============================================================================

/// Create a bit set for ASCII digits (0-9)
pub fn asciiDigits() BitSet256 {
    var set = BitSet256.init();
    set.setRange('0', '9');
    return set;
}

/// Create a bit set for ASCII lowercase letters (a-z)
pub fn asciiLower() BitSet256 {
    var set = BitSet256.init();
    set.setRange('a', 'z');
    return set;
}

/// Create a bit set for ASCII uppercase letters (A-Z)
pub fn asciiUpper() BitSet256 {
    var set = BitSet256.init();
    set.setRange('A', 'Z');
    return set;
}

/// Create a bit set for ASCII letters (a-z, A-Z)
pub fn asciiAlpha() BitSet256 {
    var set = BitSet256.init();
    set.setRange('a', 'z');
    set.setRange('A', 'Z');
    return set;
}

/// Create a bit set for ASCII alphanumeric (a-z, A-Z, 0-9)
pub fn asciiAlnum() BitSet256 {
    var set = BitSet256.init();
    set.setRange('a', 'z');
    set.setRange('A', 'Z');
    set.setRange('0', '9');
    return set;
}

/// Create a bit set for ASCII whitespace
pub fn asciiWhitespace() BitSet256 {
    var set = BitSet256.init();
    set.set(' ');
    set.set('\t');
    set.set('\n');
    set.set('\r');
    set.set('\x0B'); // Vertical tab
    set.set('\x0C'); // Form feed
    return set;
}

// =============================================================================
// Tests
// =============================================================================

test "BitSet256: init" {
    const set = BitSet256.init();
    try std.testing.expect(set.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), set.count());
}

test "BitSet256: initFull" {
    const set = BitSet256.initFull();
    try std.testing.expect(!set.isEmpty());
    try std.testing.expectEqual(@as(u32, 256), set.count());
}

test "BitSet256: set and isSet" {
    var set = BitSet256.init();

    set.set(0);
    set.set(64);
    set.set(128);
    set.set(255);

    try std.testing.expect(set.isSet(0));
    try std.testing.expect(set.isSet(64));
    try std.testing.expect(set.isSet(128));
    try std.testing.expect(set.isSet(255));
    try std.testing.expect(!set.isSet(1));
    try std.testing.expect(!set.isSet(127));
}

test "BitSet256: unset" {
    var set = BitSet256.init();

    set.set(42);
    try std.testing.expect(set.isSet(42));

    set.unset(42);
    try std.testing.expect(!set.isSet(42));
}

test "BitSet256: setRange" {
    var set = BitSet256.init();

    set.setRange('a', 'z');

    try std.testing.expect(set.isSet('a'));
    try std.testing.expect(set.isSet('m'));
    try std.testing.expect(set.isSet('z'));
    try std.testing.expect(!set.isSet('A'));
    try std.testing.expect(!set.isSet('0'));
}

test "BitSet256: clearAll and setAll" {
    var set = BitSet256.init();
    set.setRange(0, 100);

    try std.testing.expect(!set.isEmpty());

    set.clearAll();
    try std.testing.expect(set.isEmpty());

    set.setAll();
    try std.testing.expectEqual(@as(u32, 256), set.count());
}

test "BitSet256: unionWith" {
    var set1 = BitSet256.init();
    var set2 = BitSet256.init();

    set1.setRange('a', 'z');
    set2.setRange('0', '9');

    set1.unionWith(set2);

    try std.testing.expect(set1.isSet('a'));
    try std.testing.expect(set1.isSet('z'));
    try std.testing.expect(set1.isSet('0'));
    try std.testing.expect(set1.isSet('9'));
}

test "BitSet256: intersectWith" {
    var set1 = BitSet256.init();
    var set2 = BitSet256.init();

    set1.setRange(0, 100);
    set2.setRange(50, 150);

    set1.intersectWith(set2);

    try std.testing.expect(!set1.isSet(49));
    try std.testing.expect(set1.isSet(50));
    try std.testing.expect(set1.isSet(100));
    try std.testing.expect(!set1.isSet(101));
}

test "BitSet256: subtractWith" {
    var set1 = BitSet256.init();
    var set2 = BitSet256.init();

    set1.setRange(0, 100);
    set2.setRange(50, 150);

    set1.subtractWith(set2);

    try std.testing.expect(set1.isSet(0));
    try std.testing.expect(set1.isSet(49));
    try std.testing.expect(!set1.isSet(50));
    try std.testing.expect(!set1.isSet(100));
}

test "BitSet256: complement" {
    var set = BitSet256.init();
    set.setRange(0, 10);

    const count_before = set.count();
    set.complement();

    try std.testing.expectEqual(@as(u32, 256 - count_before), set.count());
    try std.testing.expect(!set.isSet(0));
    try std.testing.expect(!set.isSet(10));
    try std.testing.expect(set.isSet(11));
    try std.testing.expect(set.isSet(255));
}

test "BitSet256: count" {
    var set = BitSet256.init();

    try std.testing.expectEqual(@as(u32, 0), set.count());

    set.setRange('a', 'z');
    try std.testing.expectEqual(@as(u32, 26), set.count());

    set.setRange('A', 'Z');
    try std.testing.expectEqual(@as(u32, 52), set.count());
}

test "BitSet256: eql" {
    var set1 = BitSet256.init();
    var set2 = BitSet256.init();

    try std.testing.expect(set1.eql(set2));

    set1.set(42);
    try std.testing.expect(!set1.eql(set2));

    set2.set(42);
    try std.testing.expect(set1.eql(set2));
}

test "BitSet256: clone" {
    var set = BitSet256.init();
    set.setRange('0', '9');

    const cloned = set.clone();

    try std.testing.expect(set.eql(cloned));
    try std.testing.expectEqual(set.count(), cloned.count());
}

test "DynBitSet: init and deinit" {
    var set = try DynBitSet.init(std.testing.allocator, 1000);
    defer set.deinit();

    try std.testing.expect(set.capacity() >= 1000);
    try std.testing.expect(set.isEmpty());
}

test "DynBitSet: set and isSet" {
    var set = try DynBitSet.init(std.testing.allocator, 10000);
    defer set.deinit();

    try set.set(0);
    try set.set(5000);
    try set.set(9999);

    try std.testing.expect(set.isSet(0));
    try std.testing.expect(set.isSet(5000));
    try std.testing.expect(set.isSet(9999));
    try std.testing.expect(!set.isSet(1));
}

test "DynBitSet: unset" {
    var set = try DynBitSet.init(std.testing.allocator, 1000);
    defer set.deinit();

    try set.set(500);
    try std.testing.expect(set.isSet(500));

    try set.unset(500);
    try std.testing.expect(!set.isSet(500));
}

test "DynBitSet: clearAll and setAll" {
    var set = try DynBitSet.init(std.testing.allocator, 256);
    defer set.deinit();

    try set.set(100);
    try std.testing.expect(!set.isEmpty());

    set.clearAll();
    try std.testing.expect(set.isEmpty());

    set.setAll();
    try std.testing.expect(!set.isEmpty());
    try std.testing.expectEqual(set.capacity(), set.count());
}

test "DynBitSet: count" {
    var set = try DynBitSet.init(std.testing.allocator, 1000);
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 0), set.count());

    try set.set(10);
    try set.set(20);
    try set.set(30);

    try std.testing.expectEqual(@as(usize, 3), set.count());
}

test "DynBitSet: clone" {
    var set = try DynBitSet.init(std.testing.allocator, 1000);
    defer set.deinit();

    try set.set(100);
    try set.set(500);

    var cloned = try set.clone(std.testing.allocator);
    defer cloned.deinit();

    try std.testing.expect(cloned.isSet(100));
    try std.testing.expect(cloned.isSet(500));
    try std.testing.expectEqual(set.count(), cloned.count());
}

test "asciiDigits" {
    const set = asciiDigits();

    try std.testing.expect(set.isSet('0'));
    try std.testing.expect(set.isSet('5'));
    try std.testing.expect(set.isSet('9'));
    try std.testing.expect(!set.isSet('a'));
    try std.testing.expectEqual(@as(u32, 10), set.count());
}

test "asciiAlpha" {
    const set = asciiAlpha();

    try std.testing.expect(set.isSet('a'));
    try std.testing.expect(set.isSet('Z'));
    try std.testing.expect(!set.isSet('0'));
    try std.testing.expectEqual(@as(u32, 52), set.count());
}

test "asciiAlnum" {
    const set = asciiAlnum();

    try std.testing.expect(set.isSet('a'));
    try std.testing.expect(set.isSet('Z'));
    try std.testing.expect(set.isSet('5'));
    try std.testing.expectEqual(@as(u32, 62), set.count());
}

test "asciiWhitespace" {
    const set = asciiWhitespace();

    try std.testing.expect(set.isSet(' '));
    try std.testing.expect(set.isSet('\t'));
    try std.testing.expect(set.isSet('\n'));
    try std.testing.expect(set.isSet('\r'));
    try std.testing.expect(!set.isSet('a'));
}
