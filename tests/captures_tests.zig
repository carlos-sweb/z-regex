//! D9/D16 (docs/REGEX_TIERS_PLAN.md, F1c): capture groups have no fixed cap.
//! Group indices are u16 (a pattern with more than 65535 groups is
//! `error.TooManyCaptures`), and the matcher keeps one slot per group of the
//! pattern. Every test checks exact captures, not just "no crash".

const std = @import("std");
const zregex = @import("zregex");
const testing = std.testing;

/// `n` copies of `unit`.
fn repeat(gpa: std.mem.Allocator, unit: []const u8, n: usize) ![]u8 {
    const out = try gpa.alloc(u8, unit.len * n);
    for (0..n) |i| @memcpy(out[i * unit.len ..][0..unit.len], unit);
    return out;
}

/// `n` distinct printable ASCII characters, cycling.
fn distinctChars(gpa: std.mem.Allocator, n: usize) ![]u8 {
    const out = try gpa.alloc(u8, n);
    for (out, 0..) |*c, i| c.* = @intCast('!' + (i % 94));
    return out;
}

fn expectSequentialCaptures(n: usize) !void {
    const gpa = testing.allocator;
    const pattern = try repeat(gpa, "(.)", n);
    defer gpa.free(pattern);
    const input = try distinctChars(gpa, n);
    defer gpa.free(input);

    var re = try zregex.Regex.compile(gpa, pattern);
    defer re.deinit();
    const m = (try re.find(input)) orelse return error.TestExpectedMatch;
    defer m.deinit();
    try testing.expectEqual(n, m.end);
    for (1..n + 1) |g| {
        const cap = m.getCapture(g, input) orelse return error.TestExpectedCapture;
        try testing.expectEqualStrings(input[g - 1 .. g], cap);
    }
    try testing.expect(m.getCapture(n + 1, input) == null);
}

test "D9: 17 and 200 sequential groups capture exactly" {
    try expectSequentialCaptures(17);
    try expectSequentialCaptures(200);
}

test "D9: 1000 sequential groups hit the recursion limit through Regex (D14, F6a)" {
    // Each group costs three matchFrom levels, past the recursive matcher's
    // limit of 1000: a defined error, not a crash. The 1000-group captures
    // themselves are checked with the limit lifted in
    // tests/tier2_pipeline_tests.zig ("1000 groups capture exactly").
    const gpa = testing.allocator;
    const pattern = try repeat(gpa, "(.)", 1000);
    defer gpa.free(pattern);
    const input = try distinctChars(gpa, 1000);
    defer gpa.free(input);
    var re = try zregex.Regex.compile(gpa, pattern);
    defer re.deinit();
    try testing.expectError(error.RecursionLimitExceeded, re.find(input));
}

test "D16: group 256 is group 256, not the whole match" {
    const gpa = testing.allocator;
    for ([_]usize{ 255, 256, 257, 300 }) |n| {
        const pattern = try repeat(gpa, "(a)", n);
        defer gpa.free(pattern);
        var input = try repeat(gpa, "a", n + 1);
        defer gpa.free(input);
        input[n] = 'b';

        var re = try zregex.Regex.compile(gpa, pattern);
        defer re.deinit();
        const m = (try re.find(input)) orelse return error.TestExpectedMatch;
        defer m.deinit();
        try testing.expectEqual(@as(usize, 0), m.start);
        try testing.expectEqual(n, m.end);
        const last = m.getCaptureIndices(n) orelse return error.TestExpectedCapture;
        try testing.expectEqual(n - 1, last.start);
        try testing.expectEqual(n, last.end);
    }
}

test "D9: backreferences past \\9 and past 255 (\\17, \\200, \\300)" {
    const gpa = testing.allocator;
    // 300 groups with the reference: 900+ matchFrom levels, under the
    // recursion limit (1000 groups are covered in recursive_matcher.zig).
    for ([_]usize{ 17, 200, 300 }) |n| {
        const groups = try repeat(gpa, "(.)", n);
        defer gpa.free(groups);
        const pattern = try std.fmt.allocPrint(gpa, "{s}\\{d}", .{ groups, n });
        defer gpa.free(pattern);
        const chars = try distinctChars(gpa, n);
        defer gpa.free(chars);
        const input = try std.fmt.allocPrint(gpa, "{s}{c}", .{ chars, chars[n - 1] });
        defer gpa.free(input);

        var re = try zregex.Regex.compile(gpa, pattern);
        defer re.deinit();
        const m = (try re.find(input)) orelse return error.TestExpectedMatch;
        defer m.deinit();
        try testing.expectEqual(n + 1, m.end);

        // The wrong character after the groups: no match.
        const bad = try std.fmt.allocPrint(gpa, "{s}{c}", .{ chars, chars[0] ^ 0x40 });
        defer gpa.free(bad);
        try testing.expect((try re.find(bad)) == null);
    }
}

test "D9: 65535 groups compile, 65536 are TooManyCaptures" {
    const gpa = testing.allocator;
    const ok = try repeat(gpa, "()", 65535);
    defer gpa.free(ok);
    var re = try zregex.Regex.compile(gpa, ok);
    re.deinit();

    const too_many = try repeat(gpa, "()", 65536);
    defer gpa.free(too_many);
    try testing.expectError(error.TooManyCaptures, zregex.Regex.compile(gpa, too_many));
}

const Nested = struct {
    n: usize,
    ok: bool = false,

    fn run(self: *Nested) void {
        self.ok = self.check() catch false;
    }

    fn check(self: *Nested) !bool {
        const gpa = std.heap.page_allocator;
        const open = try repeat(gpa, "(", self.n);
        defer gpa.free(open);
        const close = try repeat(gpa, ")", self.n);
        defer gpa.free(close);
        const pattern = try std.fmt.allocPrint(gpa, "{s}a{s}", .{ open, close });
        defer gpa.free(pattern);
        var re = try zregex.Regex.compile(gpa, pattern);
        defer re.deinit();
        const m = (try re.find("xa")) orelse return false;
        defer m.deinit();
        for (1..self.n + 1) |g| {
            const c = m.getCaptureIndices(g) orelse return false;
            if (c.start != 1 or c.end != 2) return false;
        }
        return true;
    }
};

test "D9: 200 nested capturing groups capture exactly (T15 shape, on a large stack)" {
    // The recursive matcher needs several MiB of stack for this (D15/T15,
    // F6a); run it on a 64 MiB thread to test the captures, not the stack.
    var ctx: Nested = .{ .n = 200 };
    const t = try std.Thread.spawn(.{ .stack_size = 64 << 20 }, Nested.run, .{&ctx});
    t.join();
    try testing.expect(ctx.ok);
}

test "D9: lookaround snapshots restore every slot beyond the inline ones" {
    const gpa = testing.allocator;
    // 20 groups (heap slots), with a negative lookahead whose own group must
    // not leak and a positive one whose group must.
    const groups = try repeat(gpa, "(.)", 18);
    defer gpa.free(groups);
    const pattern = try std.fmt.allocPrint(gpa, "(?!(x))(?=(a)){s}", .{groups});
    defer gpa.free(pattern);
    const input = try distinctChars(gpa, 18);
    defer gpa.free(input);
    input[0] = 'a';

    var re = try zregex.Regex.compile(gpa, pattern);
    defer re.deinit();
    const m = (try re.find(input)) orelse return error.TestExpectedMatch;
    defer m.deinit();
    try testing.expect(m.getCapture(1, input) == null);
    try testing.expectEqualStrings("a", m.getCapture(2, input).?);
    try testing.expectEqualStrings(input[17..18], m.getCapture(20, input).?);
}

test "D9: compile and match don't leak on any allocation failure (heap captures)" {
    const gpa = testing.allocator;
    const groups = try repeat(gpa, "(.)", 20);
    defer gpa.free(groups);
    const pattern = try std.fmt.allocPrint(gpa, "(?=(.)){s}\\20", .{groups});
    defer gpa.free(pattern);
    try testing.checkAllAllocationFailures(gpa, struct {
        fn run(a: std.mem.Allocator, p: []const u8) !void {
            var re = try zregex.Regex.compile(a, p);
            defer re.deinit();
            if (try re.find("abcdefghijklmnopqrstt")) |m| m.deinit();
        }
    }.run, .{pattern});
}

test "a backreference to a group re-entered but not closed yet matches empty (was an overflow panic)" {
    // Found by zig build differential-v8 (F1c): the group's new start with
    // the previous iteration's end made `end - start` overflow.
    const gpa = testing.allocator;
    for ([_][]const u8{ "(?:(a)\\1?b\\1)*", "((?:x\\1|a)b)*c", "(\\1a|b){2}" }) |p| {
        var re = try zregex.Regex.compile(gpa, p);
        defer re.deinit();
        for ([_][]const u8{ "abab", "abxabc", "ba", "bbaba" }) |s| {
            if (try re.find(s)) |m| m.deinit();
        }
    }
    // Same answers as V8.
    var re = try zregex.Regex.compile(gpa, "(a\\1b)*");
    defer re.deinit();
    const m = (try re.find("abab")).?;
    defer m.deinit();
    try testing.expectEqual(@as(usize, 4), m.end);
    try testing.expectEqualStrings("ab", m.getCapture(1, "abab").?);
}

// --- Group names (F1c) ---

fn namedIndex(re: zregex.Regex, name: []const u8) ?u16 {
    for (re.compiled.named_groups) |g| {
        if (std.mem.eql(u8, g.name, name)) return g.index;
    }
    return null;
}

test "group names are RegExpIdentifierNames: Unicode, astral, escaped" {
    const gpa = testing.allocator;
    const cases = [_]struct { pattern: []const u8, name: []const u8, opts: zregex.CompileOptions }{
        .{ .pattern = "(?<\xCF\x80>a)", .name = "\xCF\x80", .opts = .{} }, // π
        .{ .pattern = "(?<\\u{03C0}>a)", .name = "\xCF\x80", .opts = .{} },
        .{ .pattern = "(?<\\u03C0>a)", .name = "\xCF\x80", .opts = .{ .unicode = true } },
        .{ .pattern = "(?<\xF0\x9D\x91\x93\xF0\x9D\x91\x9C\xF0\x9D\x91\xA5>a)", .name = "\xF0\x9D\x91\x93\xF0\x9D\x91\x9C\xF0\x9D\x91\xA5", .opts = .{} }, // 𝑓𝑜𝑥
        .{ .pattern = "(?<\\ud835\\udc53>a)", .name = "\xF0\x9D\x91\x93", .opts = .{} }, // escaped pair, no u
        .{ .pattern = "(?<$\xF0\x90\x92\xA4>a)", .name = "$\xF0\x90\x92\xA4", .opts = .{ .unicode = true } }, // $𐒤
        .{ .pattern = "(?<_\\u200C>a)", .name = "_\xE2\x80\x8C", .opts = .{} }, // ZWNJ
        .{ .pattern = "(?<_\\u200D>a)", .name = "_\xE2\x80\x8D", .opts = .{} }, // ZWJ
        .{ .pattern = "(?<\xE0\xB2\xA0_\xE0\xB2\xA0>a)", .name = "\xE0\xB2\xA0_\xE0\xB2\xA0", .opts = .{} }, // ಠ_ಠ
        .{ .pattern = "(?<a\xF0\x9D\x9F\x9A>a)", .name = "a\xF0\x9D\x9F\x9A", .opts = .{} }, // 𝟚 continues
    };
    for (cases) |c| {
        var re = try zregex.Regex.compileWithOptions(gpa, c.pattern, c.opts);
        defer re.deinit();
        try testing.expectEqual(@as(?u16, 1), namedIndex(re, c.name));
    }
}

test "invalid group names are SyntaxErrors" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        "(?<\xF0\x9F\xA6\x8A>a)", // 🦊 isn't ID_Start
        "(?<a\xF0\x9F\x90\x95>a)", // 🐕 isn't ID_Continue
        "(?<\xF0\x9D\x9F\x9A>a)", // 𝟚 can't start
        "(?<1a>a)",
        "(?<>a)",
        "(?<a-b>a)",
        "(?<\\u{110000}>a)",
        "(?<\\x41>a)",
    }) |p| {
        if (zregex.Regex.compile(gpa, p)) |re| {
            re.deinit();
            std.debug.print("\n/{s}/ compiled\n", .{p});
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "\\k<name> resolves after the parse: forward and self references" {
    const gpa = testing.allocator;
    const Case = struct { pattern: []const u8, input: []const u8, match: ?[]const u8 };
    for ([_]Case{
        .{ .pattern = "\\k<a>(?<a>b)\\w\\k<a>", .input = "bab", .match = "bab" },
        .{ .pattern = "(?<a>\\k<a>\\w)..", .input = "bab", .match = "bab" },
        .{ .pattern = "(?<b>b)\\k<a>(?<a>a)\\k<b>", .input = "bab", .match = "bab" },
        .{ .pattern = "(?<b>.).\\k<b>", .input = "baa", .match = null },
        .{ .pattern = "(?<\\u{03C0}>a)\\k<\xCF\x80>", .input = "aa", .match = "aa" },
    }) |c| {
        var re = try zregex.Regex.compile(gpa, c.pattern);
        defer re.deinit();
        const m = try re.find(c.input);
        defer if (m) |x| x.deinit();
        if (c.match) |want| {
            try testing.expectEqualStrings(want, m.?.group(c.input));
        } else try testing.expect(m == null);
    }
    try testing.expectError(error.UnknownGroupName, zregex.Regex.compile(gpa, "(?<a>x)\\k<b>"));
    try testing.expectError(error.UnknownGroupName, zregex.Regex.compile(gpa, "\\k<b>(?<a>x)"));
}

test "group names: no leak on any allocation failure" {
    for ([_][]const u8{ "\\k<a>(?<a>b)(?<\\u{03C0}>c)\\k<\xCF\x80>", "(?<a>x)|(?<a>y)\\k<a>", "(?<a>(?<b>x)\\k<b>)" }) |p| {
        try testing.checkAllAllocationFailures(testing.allocator, struct {
            fn run(a: std.mem.Allocator, pattern: []const u8) !void {
                var re = try zregex.Regex.compile(a, pattern);
                re.deinit();
            }
        }.run, .{p});
    }
}
