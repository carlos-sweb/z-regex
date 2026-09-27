//! Test aggregator for codegen module

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("generator.zig");
    _ = @import("optimizer.zig");
}
