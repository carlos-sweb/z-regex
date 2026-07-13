//! Test aggregator for executor module

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("thread.zig");
    _ = @import("recursive_matcher.zig");
    _ = @import("matcher.zig");
}
