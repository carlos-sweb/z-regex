//! Test aggregator for the unicode module
//!
//! This file imports all unicode module tests to ensure they are run
//! when the main test suite is executed.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("properties.zig");
    _ = @import("casefold.zig");
}
