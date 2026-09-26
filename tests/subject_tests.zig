//! F3c: the test262-derived cases (tests/test262_data.zig) in both subject
//! encodings. `test262_conformance.zig` checks them against the expected
//! results on WTF-8; here every case must give the same match, with the
//! same captures, on the UTF-16 form of its input, from every position.

const std = @import("std");
const zregex = @import("zregex");
const data = @import("test262_data.zig");
const dual = @import("dual_encoding.zig");

fn optionsFromFlags(flags: []const u8) zregex.CompileOptions {
    var opts = zregex.CompileOptions{};
    for (flags) |c| switch (c) {
        'i' => opts.case_insensitive = true,
        'm' => opts.multiline = true,
        's' => opts.dot_all = true,
        'y' => opts.sticky = true,
        else => {},
    };
    return opts;
}

test "test262-derived cases: the same match on WTF-8 and UTF-16 subjects" {
    const a = std.testing.allocator;
    var checked: usize = 0;
    for (data.cases) |c| {
        var re = zregex.Regex.compileWithOptions(a, c.pattern, optionsFromFlags(c.flags)) catch continue;
        defer re.deinit();
        if (!dual.wellFormed(c.input)) continue;
        try dual.expectSameInBoth(a, re, c.input);
        checked += 1;
    }
    // Every case compiles and has well-formed input today.
    try std.testing.expectEqual(data.cases.len, checked);
}
