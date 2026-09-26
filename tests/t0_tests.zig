//! F4a: T0's Pike VM against the backtracker, on patterns T0 takes
//! (docs/REGEX_TIERS_PLAN.md, F4a). Every subject, every index (positions
//! and not), sticky and not, in WTF-8 and UTF-16: the same outcome and the
//! same `[start, end]`. The full run over the 7,453 eligible patterns of
//! the F2c corpus is reported in the F4a(2) commit; this is the part that
//! stays in the suite.

const std = @import("std");
const zregex = @import("zregex");
const testing = std.testing;
const tier0 = zregex.tier0;

const Flags = struct { i: bool = false, m: bool = false, s: bool = false };

const cases = [_]struct { []const u8, Flags }{
    .{ "abc", .{} },
    .{ "a|ab", .{} },
    .{ "ab|a", .{} },
    .{ "(?:a|ab)(?:c|bcd)", .{} },
    .{ "a*", .{} },
    .{ "a+?", .{} },
    .{ "a*?b", .{} },
    .{ "a{2,4}", .{} },
    .{ "a{2,4}?", .{} },
    .{ "(?:ab){2,}", .{} },
    .{ "(?:a|b)*c", .{} },
    .{ "(?:a?b??)?x", .{} },
    .{ "(?:)?a", .{} },
    .{ "[^a]+", .{} },
    .{ "[a-c]+?c", .{} },
    .{ "\\d{3}-\\d{4}", .{} },
    .{ "\\w+@\\w+\\.com", .{} },
    .{ ".*?b", .{} },
    .{ ".+", .{ .s = true } },
    .{ "^a", .{} },
    .{ "^a|b$", .{ .m = true } },
    .{ "$", .{ .m = true } },
    .{ "^$", .{} },
    .{ "\\bab", .{} },
    .{ "\\Bb\\B", .{} },
    .{ "AB", .{ .i = true } },
    .{ "[a-z]+", .{ .i = true } },
    .{ "\u{E9}.", .{} },
    .{ "\u{1F600}", .{} },
    .{ "..", .{} },
    .{ "\\ud83d", .{} },
    .{ "[\\ud800-\\udbff][\\udc00-\\udfff]", .{} },
};

const subjects = [_][]const u8{
    "",           "a",             "ab",         "abcd",         "aaab",          "abab ab",
    "bab\nab",    "xAbAB",         "123-4567 1", "joe@site.com", "\u{E9}\u{E9}x", "\u{1F600}x\u{1F600}",
    "a\u{2028}b", "\xED\xA0\x80a", "_\xff\xc3",  "ccbca",
};

const Out = struct { found: bool, start: usize = 0, end: usize = 0 };

fn backtracker(re: zregex.Regex, subj: zregex.Subject, index: usize, scratch: *zregex.Scratch) !Out {
    var buf: [2]?usize = undefined;
    var slots: zregex.MatchSlots = .{ .slots = &buf };
    if (!try re.execAt(subj, index, scratch, &slots, .{})) return .{ .found = false };
    return .{ .found = true, .start = buf[0].?, .end = buf[1].? };
}

fn vm(prog: *const tier0.Program, subj: zregex.Subject, index: usize, sticky: bool, scratch: *tier0.VmScratch) !Out {
    var buf: [2]?usize = undefined;
    const found = switch (subj) {
        .wtf8 => |s| try tier0.exec(prog, u8, s, .code_unit, index, sticky, scratch, &buf),
        .utf16 => |s| try tier0.exec(prog, u16, s, .code_unit, index, sticky, scratch, &buf),
    };
    if (!found) return .{ .found = false };
    return .{ .found = true, .start = buf[0].?, .end = buf[1].? };
}

fn compareAll(re: *zregex.Regex, prog: *const tier0.Program, subj: zregex.Subject, bt: *zregex.Scratch, vs: *tier0.VmScratch) !void {
    for ([_]bool{ false, true }) |sticky| {
        re.sticky = sticky;
        for (0..subj.len() + 2) |i| {
            const a = backtracker(re.*, subj, i, bt) catch |err| {
                try testing.expectError(err, vm(prog, subj, i, sticky, vs));
                continue;
            };
            const b = try vm(prog, subj, i, sticky, vs);
            testing.expectEqual(a, b) catch |err| {
                std.debug.print("/{s}/ index {d} sticky {}\n", .{ re.pattern, i, sticky });
                return err;
            };
        }
    }
}

test "T0 VM matches the backtracker on eligible patterns" {
    const gpa = testing.allocator;
    var bt: zregex.Scratch = .init(gpa);
    defer bt.deinit();
    var vs: tier0.VmScratch = .init(gpa);
    defer vs.deinit();
    for (cases) |c| {
        const pattern, const f = c;
        const fe = try zregex.lower.Frontend.init(gpa, pattern, .{}, .{ .ignore_case = f.i, .multiline = f.m, .dot_all = f.s });
        defer fe.deinit();
        testing.expectEqual(@as(?tier0.Ineligible, null), tier0.check(fe.root)) catch |err| {
            std.debug.print("/{s}/ is not T0-eligible\n", .{pattern});
            return err;
        };
        const prog = try tier0.compile(gpa, fe.root);
        defer prog.deinit(gpa);
        var re = try zregex.Regex.compileWithOptions(gpa, pattern, .{ .case_insensitive = f.i, .multiline = f.m, .dot_all = f.s });
        defer re.deinit();
        for (subjects) |s| {
            const s16 = try zregex.subject.utf16FromWtf8(gpa, s);
            defer gpa.free(s16);
            try compareAll(&re, &prog, .{ .wtf8 = s }, &bt, &vs);
            try compareAll(&re, &prog, .{ .utf16 = s16 }, &bt, &vs);
        }
    }
}
