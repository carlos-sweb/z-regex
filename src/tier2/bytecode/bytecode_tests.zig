//! Test aggregator for bytecode module
//!
//! This file imports all bytecode module tests to ensure they are run
//! when the main test suite is executed.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("opcodes.zig");
    _ = @import("format.zig");
    _ = @import("writer.zig");
    _ = @import("reader.zig");
}
