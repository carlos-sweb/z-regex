//! Object pooling for zregex
//!
//! This module provides generic object pooling to reduce allocation
//! overhead for frequently created and destroyed objects during
//! regex execution.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generic object pool for type T
/// Manages a pool of reusable objects to reduce allocation overhead
pub fn Pool(comptime T: type) type {
    return struct {
        free_list: std.ArrayListUnmanaged(*T),
        allocator: Allocator,
        total_allocated: usize,
        total_acquired: usize,
        total_released: usize,

        const Self = @This();

        /// Initialize an empty pool
        pub fn init(allocator: Allocator) Self {
            return .{
                .free_list = .empty,
                .allocator = allocator,
                .total_allocated = 0,
                .total_acquired = 0,
                .total_released = 0,
            };
        }

        /// Initialize pool with pre-allocated objects
        pub fn initCapacity(allocator: Allocator, initial_capacity: usize) !Self {
            var self = Self.init(allocator);
            try self.free_list.ensureTotalCapacity(allocator, initial_capacity);

            // Pre-allocate objects
            for (0..initial_capacity) |_| {
                const obj = try allocator.create(T);
                try self.free_list.append(allocator, obj);
                self.total_allocated += 1;
            }

            return self;
        }

        /// Free all pooled objects
        pub fn deinit(self: *Self) void {
            // Destroy all objects in the pool
            for (self.free_list.items) |obj| {
                self.allocator.destroy(obj);
            }
            self.free_list.deinit(self.allocator);
            self.* = undefined;
        }

        /// Acquire an object from the pool
        /// If the pool is empty, allocates a new object
        pub fn acquire(self: *Self) !*T {
            self.total_acquired += 1;

            // Try to reuse from pool
            if (self.free_list.items.len > 0) {
                const last_idx = self.free_list.items.len - 1;
                const obj = self.free_list.items[last_idx];
                self.free_list.items.len = last_idx;
                return obj;
            }

            // Pool is empty, allocate a new object
            const obj = try self.allocator.create(T);
            self.total_allocated += 1;
            return obj;
        }

        /// Release an object back to the pool
        pub fn release(self: *Self, obj: *T) !void {
            self.total_released += 1;
            try self.free_list.append(self.allocator, obj);
        }

        /// Get the number of objects currently in the pool
        pub fn available(self: Self) usize {
            return self.free_list.items.len;
        }

        /// Get the total number of objects allocated
        pub fn totalAllocated(self: Self) usize {
            return self.total_allocated;
        }

        /// Get the number of objects currently in use
        pub fn inUse(self: Self) usize {
            return self.total_allocated - self.free_list.items.len;
        }

        /// Clear the pool, destroying all objects
        pub fn clear(self: *Self) void {
            for (self.free_list.items) |obj| {
                self.allocator.destroy(obj);
            }
            self.free_list.clearRetainingCapacity();
            self.total_allocated = 0;
        }

        /// Shrink the pool to a maximum size, destroying excess objects
        pub fn shrinkTo(self: *Self, max_size: usize) void {
            while (self.free_list.items.len > max_size) {
                const last_idx = self.free_list.items.len - 1;
                const obj = self.free_list.items[last_idx];
                self.free_list.items.len = last_idx;
                self.allocator.destroy(obj);
                self.total_allocated -= 1;
            }
        }

        /// Get statistics about pool usage
        pub fn stats(self: Self) PoolStats {
            return .{
                .total_allocated = self.total_allocated,
                .total_acquired = self.total_acquired,
                .total_released = self.total_released,
                .currently_available = self.free_list.items.len,
                .currently_in_use = self.inUse(),
            };
        }
    };
}

/// Pool statistics
pub const PoolStats = struct {
    total_allocated: usize,
    total_acquired: usize,
    total_released: usize,
    currently_available: usize,
    currently_in_use: usize,

    /// Calculate the reuse ratio (released / acquired)
    pub fn reuseRatio(self: PoolStats) f64 {
        if (self.total_acquired == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_released)) /
               @as(f64, @floatFromInt(self.total_acquired));
    }

    /// Calculate the allocation efficiency (1 - allocated / acquired)
    pub fn efficiency(self: PoolStats) f64 {
        if (self.total_acquired == 0) return 0.0;
        return 1.0 - (@as(f64, @floatFromInt(self.total_allocated)) /
                     @as(f64, @floatFromInt(self.total_acquired)));
    }
};

/// Scoped object that automatically releases to pool on destruction
pub fn Pooled(comptime T: type) type {
    return struct {
        object: *T,
        pool: *Pool(T),

        const Self = @This();

        /// Initialize a pooled object
        pub fn init(pool: *Pool(T)) !Self {
            return .{
                .object = try pool.acquire(),
                .pool = pool,
            };
        }

        /// Release the object back to the pool
        pub fn deinit(self: Self) void {
            self.pool.release(self.object) catch {
                // If release fails, just destroy the object
                self.pool.allocator.destroy(self.object);
            };
        }

        /// Get a pointer to the underlying object
        pub fn get(self: Self) *T {
            return self.object;
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const TestStruct = struct {
    value: u32,
    name: [16]u8,
};

test "Pool: init and deinit" {
    var pool = Pool(TestStruct).init(std.testing.allocator);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.available());
    try std.testing.expectEqual(@as(usize, 0), pool.totalAllocated());
}

test "Pool: initCapacity" {
    var pool = try Pool(TestStruct).initCapacity(std.testing.allocator, 10);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 10), pool.available());
    try std.testing.expectEqual(@as(usize, 10), pool.totalAllocated());
}

test "Pool: acquire and release" {
    var pool = Pool(u32).init(std.testing.allocator);
    defer pool.deinit();

    // Acquire from empty pool (allocates new)
    const obj1 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.totalAllocated());
    try std.testing.expectEqual(@as(usize, 0), pool.available());

    // Set a value
    obj1.* = 42;

    // Release back to pool
    try pool.release(obj1);
    try std.testing.expectEqual(@as(usize, 1), pool.available());

    // Acquire again (reuses from pool)
    const obj2 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.totalAllocated());
    try std.testing.expectEqual(@as(usize, 0), pool.available());

    // Should be the same object
    try std.testing.expectEqual(@as(u32, 42), obj2.*);

    try pool.release(obj2);
}

test "Pool: multiple acquire and release" {
    var pool = Pool(u32).init(std.testing.allocator);
    defer pool.deinit();

    var objects: [5]*u32 = undefined;

    // Acquire multiple objects
    for (&objects, 0..) |*obj, i| {
        obj.* = try pool.acquire();
        obj.*.* = @intCast(i);
    }

    try std.testing.expectEqual(@as(usize, 5), pool.totalAllocated());
    try std.testing.expectEqual(@as(usize, 5), pool.inUse());

    // Release all
    for (objects) |obj| {
        try pool.release(obj);
    }

    try std.testing.expectEqual(@as(usize, 5), pool.available());
    try std.testing.expectEqual(@as(usize, 0), pool.inUse());
}

test "Pool: clear" {
    var pool = try Pool(u32).initCapacity(std.testing.allocator, 10);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 10), pool.available());

    pool.clear();

    try std.testing.expectEqual(@as(usize, 0), pool.available());
    try std.testing.expectEqual(@as(usize, 0), pool.totalAllocated());
}

test "Pool: shrinkTo" {
    var pool = try Pool(u32).initCapacity(std.testing.allocator, 20);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 20), pool.available());

    pool.shrinkTo(10);

    try std.testing.expectEqual(@as(usize, 10), pool.available());
    try std.testing.expectEqual(@as(usize, 10), pool.totalAllocated());

    // Shrink to larger size should have no effect
    pool.shrinkTo(100);
    try std.testing.expectEqual(@as(usize, 10), pool.available());
}

test "Pool: stats" {
    var pool = Pool(u32).init(std.testing.allocator);
    defer pool.deinit();

    const obj1 = try pool.acquire();
    const obj2 = try pool.acquire();

    const stats1 = pool.stats();
    try std.testing.expectEqual(@as(usize, 2), stats1.total_allocated);
    try std.testing.expectEqual(@as(usize, 2), stats1.total_acquired);
    try std.testing.expectEqual(@as(usize, 0), stats1.total_released);
    try std.testing.expectEqual(@as(usize, 2), stats1.currently_in_use);

    try pool.release(obj1);
    try pool.release(obj2);

    const stats2 = pool.stats();
    try std.testing.expectEqual(@as(usize, 2), stats2.total_released);
    try std.testing.expectEqual(@as(usize, 0), stats2.currently_in_use);
    try std.testing.expectEqual(@as(usize, 2), stats2.currently_available);
}

test "PoolStats: reuseRatio" {
    const stats = PoolStats{
        .total_allocated = 10,
        .total_acquired = 100,
        .total_released = 90,
        .currently_available = 5,
        .currently_in_use = 5,
    };

    try std.testing.expectApproxEqAbs(@as(f64, 0.9), stats.reuseRatio(), 0.01);
}

test "PoolStats: efficiency" {
    const stats = PoolStats{
        .total_allocated = 10,
        .total_acquired = 100,
        .total_released = 90,
        .currently_available = 5,
        .currently_in_use = 5,
    };

    // Efficiency = 1 - (10/100) = 0.9
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), stats.efficiency(), 0.01);
}

test "Pooled: automatic release" {
    var pool = Pool(u32).init(std.testing.allocator);
    defer pool.deinit();

    {
        var pooled = try Pooled(u32).init(&pool);
        defer pooled.deinit();

        pooled.get().* = 42;

        try std.testing.expectEqual(@as(usize, 1), pool.inUse());
    }

    // After scope, should be released
    try std.testing.expectEqual(@as(usize, 0), pool.inUse());
    try std.testing.expectEqual(@as(usize, 1), pool.available());

    // Acquire again and verify value persists
    const obj = try pool.acquire();
    try std.testing.expectEqual(@as(u32, 42), obj.*);
    try pool.release(obj);
}

test "Pool: stress test" {
    var pool = try Pool(u32).initCapacity(std.testing.allocator, 5);
    defer pool.deinit();

    for (0..100) |i| {
        const obj = try pool.acquire();
        obj.* = @intCast(i);
        try pool.release(obj);
    }

    const final_stats = pool.stats();
    try std.testing.expect(final_stats.total_acquired == 100);
    try std.testing.expect(final_stats.total_released == 100);

    // Should have only allocated a few objects due to reuse
    try std.testing.expect(final_stats.total_allocated <= 10);
}

test "Pool: concurrent-style usage" {
    var pool = Pool(TestStruct).init(std.testing.allocator);
    defer pool.deinit();

    // Simulate usage pattern where objects are acquired and released
    // at different times (single-threaded for now)
    var active: [10]*TestStruct = undefined;

    // Acquire 10 objects
    for (&active) |*obj| {
        obj.* = try pool.acquire();
    }

    try std.testing.expectEqual(@as(usize, 10), pool.inUse());

    // Release half
    for (active[0..5]) |obj| {
        try pool.release(obj);
    }

    try std.testing.expectEqual(@as(usize, 5), pool.inUse());
    try std.testing.expectEqual(@as(usize, 5), pool.available());

    // Release the rest
    for (active[5..]) |obj| {
        try pool.release(obj);
    }

    try std.testing.expectEqual(@as(usize, 0), pool.inUse());
    try std.testing.expectEqual(@as(usize, 10), pool.available());
}
