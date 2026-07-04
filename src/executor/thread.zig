//! Execution thread for regex VM
//!
//! This module manages the state of a single execution thread in the VM,
//! including program counter, capture groups, and backtracking state.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum number of capture groups supported
pub const MAX_CAPTURES: usize = 32;

/// Capture group position
pub const Capture = struct {
    start: ?usize = null,
    end: ?usize = null,

    /// Check if capture is valid
    pub fn isValid(self: Capture) bool {
        return self.start != null and self.end != null;
    }

    /// Get capture length
    pub fn len(self: Capture) usize {
        if (!self.isValid()) return 0;
        return self.end.? - self.start.?;
    }
};

/// Execution thread state
pub const Thread = struct {
    /// Program counter (offset in bytecode)
    pc: usize,

    /// String position
    sp: usize,

    /// Capture groups
    captures: [MAX_CAPTURES]Capture,

    /// Number of active captures
    capture_count: usize,

    const Self = @This();

    /// Initialize a new thread
    pub fn init(pc: usize, sp: usize) Self {
        return .{
            .pc = pc,
            .sp = sp,
            .captures = [_]Capture{.{}} ** MAX_CAPTURES,
            .capture_count = 0,
        };
    }

    /// Clone this thread
    pub fn clone(self: Self) Self {
        return self;
    }

    /// Save capture start position
    pub fn saveStart(self: *Self, group: usize, pos: usize) void {
        if (group >= MAX_CAPTURES) return;
        self.captures[group].start = pos;
        if (group >= self.capture_count) {
            self.capture_count = group + 1;
        }
    }

    /// Save capture end position
    pub fn saveEnd(self: *Self, group: usize, pos: usize) void {
        if (group >= MAX_CAPTURES) return;
        self.captures[group].end = pos;
        if (group >= self.capture_count) {
            self.capture_count = group + 1;
        }
    }

    /// Get capture by index
    pub fn getCapture(self: Self, group: usize) ?Capture {
        if (group >= self.capture_count) return null;
        const cap = self.captures[group];
        if (!cap.isValid()) return null;
        return cap;
    }

    /// Clear all captures
    pub fn clearCaptures(self: *Self) void {
        self.captures = [_]Capture{.{}} ** MAX_CAPTURES;
        self.capture_count = 0;
    }
};

/// Thread queue for managing execution threads
pub const ThreadQueue = struct {
    threads: std.ArrayListUnmanaged(Thread),
    allocator: Allocator,

    const Self = @This();

    /// Initialize thread queue
    pub fn init(allocator: Allocator) Self {
        return .{
            .threads = .empty,
            .allocator = allocator,
        };
    }

    /// Free resources
    pub fn deinit(self: *Self) void {
        self.threads.deinit(self.allocator);
    }

    /// Add a thread to the queue
    pub fn add(self: *Self, thread: Thread) !void {
        try self.threads.append(self.allocator, thread);
    }

    /// Remove and return next thread
    pub fn pop(self: *Self) ?Thread {
        if (self.threads.items.len == 0) return null;
        return self.threads.orderedRemove(0);
    }

    /// Check if queue is empty
    pub fn isEmpty(self: Self) bool {
        return self.threads.items.len == 0;
    }

    /// Get queue size
    pub fn size(self: Self) usize {
        return self.threads.items.len;
    }

    /// Clear all threads
    pub fn clear(self: *Self) void {
        self.threads.clearRetainingCapacity();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Capture: isValid" {
    var cap = Capture{};
    try std.testing.expect(!cap.isValid());

    cap.start = 0;
    try std.testing.expect(!cap.isValid());

    cap.end = 5;
    try std.testing.expect(cap.isValid());
}

test "Capture: len" {
    var cap = Capture{ .start = 10, .end = 15 };
    try std.testing.expectEqual(@as(usize, 5), cap.len());

    cap.start = null;
    try std.testing.expectEqual(@as(usize, 0), cap.len());
}

test "Thread: init" {
    const thread = Thread.init(0, 0);
    try std.testing.expectEqual(@as(usize, 0), thread.pc);
    try std.testing.expectEqual(@as(usize, 0), thread.sp);
    try std.testing.expectEqual(@as(usize, 0), thread.capture_count);
}

test "Thread: saveStart and saveEnd" {
    var thread = Thread.init(0, 0);

    thread.saveStart(0, 10);
    thread.saveEnd(0, 20);

    const cap = thread.getCapture(0).?;
    try std.testing.expectEqual(@as(usize, 10), cap.start.?);
    try std.testing.expectEqual(@as(usize, 20), cap.end.?);
    try std.testing.expectEqual(@as(usize, 1), thread.capture_count);
}

test "Thread: multiple captures" {
    var thread = Thread.init(0, 0);

    thread.saveStart(0, 0);
    thread.saveEnd(0, 10);

    thread.saveStart(1, 5);
    thread.saveEnd(1, 8);

    try std.testing.expectEqual(@as(usize, 2), thread.capture_count);

    const cap0 = thread.getCapture(0).?;
    try std.testing.expectEqual(@as(usize, 10), cap0.len());

    const cap1 = thread.getCapture(1).?;
    try std.testing.expectEqual(@as(usize, 3), cap1.len());
}

test "Thread: clone" {
    var thread = Thread.init(5, 10);
    thread.saveStart(0, 10);
    thread.saveEnd(0, 20);

    const cloned = thread.clone();
    try std.testing.expectEqual(thread.pc, cloned.pc);
    try std.testing.expectEqual(thread.sp, cloned.sp);
    try std.testing.expectEqual(thread.capture_count, cloned.capture_count);

    const cap = cloned.getCapture(0).?;
    try std.testing.expectEqual(@as(usize, 10), cap.start.?);
}

test "Thread: clearCaptures" {
    var thread = Thread.init(0, 0);
    thread.saveStart(0, 10);
    thread.saveEnd(0, 20);

    thread.clearCaptures();
    try std.testing.expectEqual(@as(usize, 0), thread.capture_count);
    try std.testing.expect(thread.getCapture(0) == null);
}

test "ThreadQueue: basic operations" {
    var queue = ThreadQueue.init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), queue.size());

    const thread1 = Thread.init(0, 0);
    try queue.add(thread1);

    try std.testing.expect(!queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), queue.size());

    const thread2 = Thread.init(5, 10);
    try queue.add(thread2);

    try std.testing.expectEqual(@as(usize, 2), queue.size());

    const popped = queue.pop().?;
    try std.testing.expectEqual(@as(usize, 0), popped.pc);
    try std.testing.expectEqual(@as(usize, 1), queue.size());
}

test "ThreadQueue: clear" {
    var queue = ThreadQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.add(Thread.init(0, 0));
    try queue.add(Thread.init(1, 1));
    try queue.add(Thread.init(2, 2));

    try std.testing.expectEqual(@as(usize, 3), queue.size());

    queue.clear();
    try std.testing.expect(queue.isEmpty());
}

test "ThreadQueue: pop empty" {
    var queue = ThreadQueue.init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expect(queue.pop() == null);
}
