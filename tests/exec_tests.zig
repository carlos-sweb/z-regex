//! F3c: the execution primitive `Regex.execAt` over WTF-8 and UTF-16
//! subjects, `Scratch`, and what the byte-offset facade does with an index
//! inside a character (docs/REGEX_TIERS_PLAN.md, F3).

const std = @import("std");
const zregex = @import("zregex");
const testing = std.testing;
const subject = zregex.subject;
const Subject = zregex.Subject;

fn execBoth(re: zregex.Regex, s8: []const u8, index8: usize) !void {
    const a = testing.allocator;
    const s16 = try subject.utf16FromWtf8(a, s8);
    defer a.free(s16);
    var scratch = zregex.Scratch.init(a);
    defer scratch.deinit();
    const n = re.slotCount();
    const buf8 = try a.alloc(?usize, n);
    defer a.free(buf8);
    const buf16 = try a.alloc(?usize, n);
    defer a.free(buf16);
    var out8: zregex.MatchSlots = .{ .slots = buf8 };
    var out16: zregex.MatchSlots = .{ .slots = buf16 };
    const index16 = try subject.wtf8ToUtf16Index(s8, index8);
    const m8 = try re.execAt(.{ .wtf8 = s8 }, index8, &scratch, &out8, .{});
    const m16 = try re.execAt(.{ .utf16 = s16 }, index16, &scratch, &out16, .{});
    try testing.expectEqual(m8, m16);
    if (!m8) return;
    for (buf8, buf16) |x8, x16| {
        try testing.expectEqual(x8 == null, x16 == null);
        if (x8) |v| try testing.expectEqual(try subject.wtf8ToUtf16Index(s8, v), x16.?);
    }
}

test "execAt: WTF-8 and UTF-16 subjects give the same match" {
    const patterns = [_][]const u8{ "b", "(a)|(b)", "\\u00e9(.)", "(?<n>\\w+)\\s", "x*", "\\bb", "(?<=\\u00e9)x", "[^a]+" };
    const subjects = [_][]const u8{ "", "ab", "\u{E9}x\u{E9}\u{1F600}", "aa bb", "\u{1F600}b\u{E9}x" };
    for (patterns) |p| {
        var re = try zregex.Regex.compileWithOptions(testing.allocator, p, .{ .unicode = true });
        defer re.deinit();
        for (subjects) |s| {
            var i: usize = 0;
            while (i <= s.len) : (i = subject.Subject.advanceIndex(.{ .wtf8 = s }, .code_point, i)) try execBoth(re, s, i);
        }
    }
}

test "execAt: index past the end, inside a character, short slots" {
    var re = try zregex.Regex.compile(testing.allocator, "(a)");
    defer re.deinit();
    var scratch = zregex.Scratch.init(testing.allocator);
    defer scratch.deinit();
    var buf: [4]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = &buf };
    try testing.expect(!try re.execAt(.{ .wtf8 = "a" }, 2, &scratch, &out, .{}));
    try testing.expectError(error.InvalidIndex, re.execAt(.{ .wtf8 = "\u{E9}a" }, 1, &scratch, &out, .{}));
    var short: zregex.MatchSlots = .{ .slots = buf[0..3] };
    try testing.expectError(error.SlotsTooSmall, re.execAt(.{ .wtf8 = "a" }, 0, &scratch, &short, .{}));
    // A search from 0 reports the match and group 1.
    try testing.expect(try re.execAt(.{ .wtf8 = "xa" }, 0, &scratch, &out, .{}));
    try testing.expectEqualSlices(?usize, &.{ 1, 2, 1, 2 }, &buf);
}

test "execAt: sticky matches only at the index" {
    var re = try zregex.Regex.compileWithOptions(testing.allocator, "b", .{ .sticky = true });
    defer re.deinit();
    var scratch = zregex.Scratch.init(testing.allocator);
    defer scratch.deinit();
    var buf: [2]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = &buf };
    const units = [_]u16{ 'a', 'b' };
    try testing.expect(!try re.execAt(.{ .utf16 = &units }, 0, &scratch, &out, .{}));
    try testing.expect(try re.execAt(.{ .utf16 = &units }, 1, &scratch, &out, .{}));
    try testing.expectEqualSlices(?usize, &.{ 1, 2 }, &buf);
}

test "compile options reach CompileResult.mode (F3c)" {
    const Case = struct { opts: zregex.CompileOptions, mode: subject.Mode };
    const cases = [_]Case{
        .{ .opts = .{}, .mode = .code_unit },
        .{ .opts = .{ .unicode = true }, .mode = .code_point },
        .{ .opts = .{ .v = true }, .mode = .code_point },
        .{ .opts = .{ .unicode = true, .v = true }, .mode = .code_point },
    };
    for (cases) |c| {
        const r = try zregex.compile(testing.allocator, "a", c.opts);
        defer r.deinit();
        try testing.expectEqual(c.mode, r.mode);
        var re = try zregex.Regex.compileWithOptions(testing.allocator, "a", c.opts);
        defer re.deinit();
        try testing.expectEqual(c.mode, re.compiled.mode);
    }
    var plain = try zregex.Regex.compile(testing.allocator, "a");
    defer plain.deinit();
    try testing.expectEqual(subject.Mode.code_unit, plain.compiled.mode);
}

// F3b's old-vs-new comparison found 15,513 `findAt` calls at an offset inside
// a character. 13,543 were at `b+2` of a 4-byte sequence, which is a position
// (between the two UTF-16 halves): there the trail half decodes. The other
// 1,970 were at offsets that aren't positions, where the old matcher decoded
// byte by byte and could match: from F3c those are no match.
test "findAt inside a character: no match off a position, the trail half at b+2 (F3c)" {
    const a = testing.allocator;
    const Sample = struct { pattern: []const u8, input: []const u8 };
    const samples = [_]Sample{
        .{ .pattern = ".", .input = "\u{E9}x\u{1F600}y\u{20AC}" },
        .{ .pattern = "[^a]{2}", .input = "\u{1F600}x\u{1F600}" },
        .{ .pattern = "", .input = "a\u{1D306}b\u{E9}" },
        .{ .pattern = "\\P{Lu}", .input = "\u{E9}\u{A9}x\u{1F600}y" },
        .{ .pattern = "(.)..|abc", .input = "\u{1F600}x\u{1F600}" },
    };
    var checked: usize = 0;
    for (samples) |smp| {
        var re = try zregex.Regex.compile(a, smp.pattern);
        defer re.deinit();
        const s: Subject = .{ .wtf8 = smp.input };
        var p: usize = 0;
        while (p <= smp.input.len) : (p += 1) {
            if (s.isPosition(p)) continue;
            checked += 1;
            try testing.expect((try re.findAt(smp.input, p)) == null);
        }
    }
    try testing.expect(checked >= 10);

    // At b+2 `.` takes the trail half: the rest of the 4-byte sequence.
    var dot = try zregex.Regex.compile(a, ".");
    defer dot.deinit();
    const m = (try dot.findAt("\u{1F600}", 2)) orelse return error.TestExpectedMatch;
    defer m.deinit();
    try testing.expectEqual(@as(usize, 2), m.start);
    try testing.expectEqual(@as(usize, 4), m.end);
}

/// Counts allocations, to check that a warm scratch doesn't allocate.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawAlloc(len, al, ra);
    }
    fn resize(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len) self.count += 1;
        return self.child.rawResize(mem, al, new_len, ra);
    }
    fn remap(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len) self.count += 1;
        return self.child.rawRemap(mem, al, new_len, ra);
    }
    fn free(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, al, ra);
    }
};

fn runAll(re: zregex.Regex, s: Subject, scratch: *zregex.Scratch, out: *zregex.MatchSlots) !usize {
    var matches: usize = 0;
    var i: usize = 0;
    while (i <= s.len()) {
        if (!try re.execAt(s, i, scratch, out, .{})) break;
        matches += 1;
        const end = out.slots[1].?;
        i = if (end == out.slots[0].?) re.advanceIndex(s, end) else end;
    }
    return matches;
}

test "execAt with a warm scratch doesn't allocate (the bench's cases)" {
    const Case = struct { pattern: []const u8, opts: zregex.CompileOptions = .{}, input: []const u8 };
    const cases = [_]Case{
        .{ .pattern = "hello", .input = "say hello to the world, hello again" },
        .{ .pattern = "[a-z]+", .input = "some words here and there" },
        .{ .pattern = "\\d{3}-\\d{4}", .input = "call 555-1234 or 12-34 and 999-0000" },
        .{ .pattern = "[\\w.]+@\\w+\\.com", .input = "mail a.b@c.com or x@y.com now" },
        .{ .pattern = "\\p{L}+", .opts = .{ .unicode = true }, .input = "λόγος word привет 漢字" },
        .{ .pattern = "[\\p{L}--\\p{Lu}]", .opts = .{ .v = true }, .input = "Ωμέγα abc" },
        .{ .pattern = "<(\\w+)>.*?<\\/\\1>", .input = "<p>x</p> <b>y</b>" },
        .{ .pattern = "(?<=\\$)\\d+", .input = "cost $12 and $345" },
        .{ .pattern = "(a+)+b", .input = "aaaaaaaaaaaaab" },
        .{ .pattern = "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)(m)(n)(o)(p)(q)(r)", .input = "xabcdefghijklmnopqr" },
    };
    for (cases) |c| {
        var re = try zregex.Regex.compileWithOptions(testing.allocator, c.pattern, c.opts);
        defer re.deinit();
        const s16 = try subject.utf16FromWtf8(testing.allocator, c.input);
        defer testing.allocator.free(s16);
        const buf = try testing.allocator.alloc(?usize, re.slotCount());
        defer testing.allocator.free(buf);
        var out: zregex.MatchSlots = .{ .slots = buf };

        var counting: CountingAllocator = .{ .child = testing.allocator };
        var scratch = zregex.Scratch.init(counting.allocator());
        defer scratch.deinit();
        for ([_]Subject{ .{ .wtf8 = c.input }, .{ .utf16 = s16 } }) |s| {
            const warm = try runAll(re, s, &scratch, &out);
            const before = counting.count;
            const again = try runAll(re, s, &scratch, &out);
            try testing.expectEqual(warm, again);
            try testing.expect(warm > 0);
            if (counting.count != before) {
                std.debug.print("/{s}/ allocated {d} times with a warm scratch\n", .{ c.pattern, counting.count - before });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "Scratch marks itself in use during an execution" {
    var scratch = zregex.Scratch.init(testing.allocator);
    defer scratch.deinit();
    try testing.expect(!scratch.in_use);
    scratch.acquire();
    if (std.debug.runtime_safety) try testing.expect(scratch.in_use);
    scratch.release();
    try testing.expect(!scratch.in_use);
}
