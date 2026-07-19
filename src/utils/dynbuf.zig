//! Dynamic buffer utilities for zregex
//!
//! This module provides a generic dynamic buffer implementation
//! built on top of Zig's ArrayListUnmanaged with additional
//! convenience methods for common operations.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generic dynamic buffer wrapper around ArrayListUnmanaged
/// Provides convenient append/insert/remove operations with efficient growth
pub fn DynBuf(comptime T: type) type {
    return struct {
        items: []T,
        capacity: usize,
        allocator: Allocator,

        const Self = @This();

        /// Initialize an empty dynamic buffer
        pub fn init(allocator: Allocator) Self {
            return .{
                .items = &[_]T{},
                .capacity = 0,
                .allocator = allocator,
            };
        }

        /// Initialize with a specific capacity
        pub fn initCapacity(allocator: Allocator, capacity: usize) !Self {
            var self = Self.init(allocator);
            try self.ensureCapacity(capacity);
            return self;
        }

        /// Free all allocated memory
        pub fn deinit(self: *Self) void {
            if (self.capacity > 0) {
                self.allocator.free(self.items.ptr[0..self.capacity]);
            }
            self.* = undefined;
        }

        /// Get the number of items in the buffer
        pub fn len(self: Self) usize {
            return self.items.len;
        }

        /// Check if the buffer is empty
        pub fn isEmpty(self: Self) bool {
            return self.items.len == 0;
        }

        /// Ensure the buffer has at least the specified capacity
        pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
            if (new_capacity <= self.capacity) return;

            const better_capacity = growCapacity(self.capacity, new_capacity);
            const new_memory = try self.allocator.alloc(T, better_capacity);

            if (self.items.len > 0) {
                @memcpy(new_memory[0..self.items.len], self.items);
            }

            if (self.capacity > 0) {
                self.allocator.free(self.items.ptr[0..self.capacity]);
            }

            self.items.ptr = new_memory.ptr;
            self.capacity = better_capacity;
        }

        /// Append a single item to the buffer
        pub fn append(self: *Self, item: T) !void {
            try self.ensureCapacity(self.items.len + 1);
            self.items.ptr[self.items.len] = item;
            self.items.len += 1;
        }

        /// Append multiple items to the buffer
        pub fn appendSlice(self: *Self, items: []const T) !void {
            try self.ensureCapacity(self.items.len + items.len);
            @memcpy(self.items.ptr[self.items.len..][0..items.len], items);
            self.items.len += items.len;
        }

        /// Insert an item at the specified index
        pub fn insert(self: *Self, index: usize, item: T) !void {
            if (index > self.items.len) return error.IndexOutOfBounds;

            try self.ensureCapacity(self.items.len + 1);

            // Shift items to the right
            if (index < self.items.len) {
                var i = self.items.len;
                while (i > index) : (i -= 1) {
                    self.items.ptr[i] = self.items.ptr[i - 1];
                }
            }

            self.items.ptr[index] = item;
            self.items.len += 1;
        }

        /// Remove and return the item at the specified index
        pub fn orderedRemove(self: *Self, index: usize) T {
            std.debug.assert(index < self.items.len);

            const item = self.items[index];

            // Shift items to the left
            var i = index;
            while (i < self.items.len - 1) : (i += 1) {
                self.items.ptr[i] = self.items.ptr[i + 1];
            }

            self.items.len -= 1;
            return item;
        }

        /// Remove the item at the specified index (unordered, O(1))
        pub fn swapRemove(self: *Self, index: usize) T {
            std.debug.assert(index < self.items.len);

            const item = self.items[index];

            if (index != self.items.len - 1) {
                self.items.ptr[index] = self.items.ptr[self.items.len - 1];
            }

            self.items.len -= 1;
            return item;
        }

        /// Remove and return the last item
        pub fn pop(self: *Self) ?T {
            if (self.items.len == 0) return null;

            self.items.len -= 1;
            return self.items.ptr[self.items.len];
        }

        /// Remove all items without deallocating
        pub fn clear(self: *Self) void {
            self.items.len = 0;
        }

        /// Resize the buffer to the specified length
        /// New elements are undefined
        pub fn resize(self: *Self, new_len: usize) !void {
            try self.ensureCapacity(new_len);
            self.items.len = new_len;
        }

        /// Get a pointer to the last item
        pub fn getLast(self: Self) ?*T {
            if (self.items.len == 0) return null;
            return &self.items.ptr[self.items.len - 1];
        }

        /// Get the last item by value
        pub fn last(self: Self) ?T {
            if (self.items.len == 0) return null;
            return self.items[self.items.len - 1];
        }

        /// Clone the buffer with a new allocator
        pub fn clone(self: Self, allocator: Allocator) !Self {
            var new_buf = try Self.initCapacity(allocator, self.items.len);
            try new_buf.appendSlice(self.items);
            return new_buf;
        }

        /// Shrink capacity to fit the current length exactly
        pub fn shrinkToFit(self: *Self) !void {
            if (self.capacity == self.items.len) return;

            if (self.items.len == 0) {
                if (self.capacity > 0) {
                    self.allocator.free(self.items.ptr[0..self.capacity]);
                }
                self.items = &[_]T{};
                self.capacity = 0;
                return;
            }

            const new_memory = try self.allocator.alloc(T, self.items.len);
            @memcpy(new_memory, self.items);

            if (self.capacity > 0) {
                self.allocator.free(self.items.ptr[0..self.capacity]);
            }

            self.items.ptr = new_memory.ptr;
            self.capacity = self.items.len;
        }

        /// Get available capacity
        pub fn availableCapacity(self: Self) usize {
            return self.capacity - self.items.len;
        }
    };
}

/// Calculate the next capacity for growth
/// Uses exponential growth strategy: new_capacity = max(old_capacity * 1.5, min_capacity)
fn growCapacity(current: usize, minimum: usize) usize {
    var new_capacity = current;
    while (true) {
        new_capacity +|= new_capacity / 2 + 8;
        if (new_capacity >= minimum) return new_capacity;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "DynBuf: init and deinit" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.len());
    try std.testing.expect(buf.isEmpty());
}

test "DynBuf: append single items" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try buf.append(1);
    try buf.append(2);
    try buf.append(3);

    try std.testing.expectEqual(@as(usize, 3), buf.len());
    try std.testing.expectEqual(@as(u32, 1), buf.items[0]);
    try std.testing.expectEqual(@as(u32, 2), buf.items[1]);
    try std.testing.expectEqual(@as(u32, 3), buf.items[2]);
}

test "DynBuf: append slice" {
    var buf = DynBuf(u8).init(std.testing.allocator);
    defer buf.deinit();

    try buf.appendSlice("hello");
    try buf.appendSlice(" world");

    try std.testing.expectEqual(@as(usize, 11), buf.len());
    try std.testing.expectEqualStrings("hello world", buf.items);
}

test "DynBuf: insert" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try buf.append(1);
    try buf.append(3);
    try buf.insert(1, 2); // Insert 2 between 1 and 3

    try std.testing.expectEqual(@as(usize, 3), buf.len());
    try std.testing.expectEqual(@as(u32, 1), buf.items[0]);
    try std.testing.expectEqual(@as(u32, 2), buf.items[1]);
    try std.testing.expectEqual(@as(u32, 3), buf.items[2]);

    // Insert at the beginning
    try buf.insert(0, 0);
    try std.testing.expectEqual(@as(u32, 0), buf.items[0]);

    // Insert at the end
    try buf.insert(buf.len(), 4);
    try std.testing.expectEqual(@as(u32, 4), buf.items[buf.len() - 1]);
}

test "DynBuf: orderedRemove" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try buf.appendSlice(&[_]u32{ 1, 2, 3, 4, 5 });

    const removed = buf.orderedRemove(2); // Remove 3
    try std.testing.expectEqual(@as(u32, 3), removed);
    try std.testing.expectEqual(@as(usize, 4), buf.len());
    try std.testing.expectEqual(@as(u32, 4), buf.items[2]);
}

test "DynBuf: swapRemove" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try buf.appendSlice(&[_]u32{ 1, 2, 3, 4, 5 });

    const removed = buf.swapRemove(1); // Remove 2, swap with 5
    try std.testing.expectEqual(@as(u32, 2), removed);
    try std.testing.expectEqual(@as(usize, 4), buf.len());
    try std.testing.expectEqual(@as(u32, 5), buf.items[1]);
}

test "DynBuf: pop" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try buf.appendSlice(&[_]u32{ 1, 2, 3 });

    try std.testing.expectEqual(@as(?u32, 3), buf.pop());
    try std.testing.expectEqual(@as(?u32, 2), buf.pop());
    try std.testing.expectEqual(@as(?u32, 1), buf.pop());
    try std.testing.expectEqual(@as(?u32, null), buf.pop());
}

test "DynBuf: clear" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try buf.appendSlice(&[_]u32{ 1, 2, 3 });
    const old_capacity = buf.capacity;

    buf.clear();

    try std.testing.expectEqual(@as(usize, 0), buf.len());
    try std.testing.expect(buf.isEmpty());
    try std.testing.expectEqual(old_capacity, buf.capacity); // Capacity unchanged
}

test "DynBuf: resize" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try buf.resize(10);
    try std.testing.expectEqual(@as(usize, 10), buf.len());

    // Fill with values
    for (buf.items, 0..) |*item, i| {
        item.* = @intCast(i);
    }

    // Resize smaller
    try buf.resize(5);
    try std.testing.expectEqual(@as(usize, 5), buf.len());
    try std.testing.expectEqual(@as(u32, 4), buf.items[4]);
}

test "DynBuf: getLast and last" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(?*u32, null), buf.getLast());
    try std.testing.expectEqual(@as(?u32, null), buf.last());

    try buf.append(42);
    try std.testing.expectEqual(@as(u32, 42), buf.getLast().?.*);
    try std.testing.expectEqual(@as(u32, 42), buf.last().?);

    // Modify through pointer
    buf.getLast().?.* = 99;
    try std.testing.expectEqual(@as(u32, 99), buf.items[0]);
}

test "DynBuf: clone" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try buf.appendSlice(&[_]u32{ 1, 2, 3 });

    var cloned = try buf.clone(std.testing.allocator);
    defer cloned.deinit();

    try std.testing.expectEqual(buf.len(), cloned.len());
    try std.testing.expectEqualSlices(u32, buf.items, cloned.items);

    // Verify they're independent
    try buf.append(4);
    try std.testing.expectEqual(@as(usize, 4), buf.len());
    try std.testing.expectEqual(@as(usize, 3), cloned.len());
}

test "DynBuf: shrinkToFit" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try buf.appendSlice(&[_]u32{ 1, 2, 3, 4, 5 });
    const len_before = buf.len();
    const cap_before = buf.capacity;

    try std.testing.expect(cap_before > len_before); // Should have extra capacity

    try buf.shrinkToFit();

    try std.testing.expectEqual(len_before, buf.len());
    try std.testing.expectEqual(buf.len(), buf.capacity);
}

test "DynBuf: initCapacity" {
    var buf = try DynBuf(u32).initCapacity(std.testing.allocator, 100);
    defer buf.deinit();

    try std.testing.expect(buf.capacity >= 100);
    try std.testing.expectEqual(@as(usize, 0), buf.len());
}

test "DynBuf: availableCapacity" {
    var buf = DynBuf(u32).init(std.testing.allocator);
    defer buf.deinit();

    try buf.append(1);
    try buf.append(2);

    const available = buf.availableCapacity();
    try std.testing.expectEqual(buf.capacity - buf.len(), available);
}

test "growCapacity: exponential growth" {
    try std.testing.expect(growCapacity(0, 1) >= 1);
    try std.testing.expect(growCapacity(10, 15) >= 15);
    try std.testing.expect(growCapacity(100, 200) >= 200);

    // Should grow exponentially
    const grown = growCapacity(100, 101);
    try std.testing.expect(grown > 101); // Should allocate more than minimum
}
