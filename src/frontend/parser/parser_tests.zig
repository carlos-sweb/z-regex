//! Test aggregator for parser module

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
}
