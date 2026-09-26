//! Internal differential (docs/REGEX_TIERS_PLAN.md §7.1, F3c): the same
//! pattern on a WTF-8 subject and on its UTF-16 form must give the same
//! match, with the same captures once the offsets are mapped, from every
//! position. Patterns: those of tests/test262_data.zig (the fuzz corpus),
//! with no flags, `u` and `v`; subjects include astral characters, lone
//! surrogates and line terminators.

const std = @import("std");
const zregex = @import("zregex");
const data = @import("test262_data.zig");
const dual = @import("dual_encoding.zig");

const subjects = [_][]const u8{
    "",
    "abc abc",
    "a\u{1F600}b\u{1F600}",
    "\u{E9}\u{C9}x\u{20AC}",
    "\xED\xA0\x80a\xED\xB0\x80",
    "a\nb\r\nc\u{2028}d",
    "\u{1D306}\u{1D306}x",
    "_Zk\u{212A}s\u{17F} 12",
};

test "differential: WTF-8 and UTF-16 subjects match the same (F3c)" {
    const a = std.testing.allocator;
    var runs: usize = 0;
    for (data.cases) |c| {
        for ([_]zregex.CompileOptions{ .{}, .{ .unicode = true }, .{ .v = true } }) |opts| {
            var re = zregex.Regex.compileWithOptions(a, c.pattern, opts) catch continue;
            defer re.deinit();
            for (subjects) |s| {
                try dual.expectSameInBoth(a, re, s);
                runs += 1;
            }
        }
    }
    try std.testing.expect(runs > 1000);
}
