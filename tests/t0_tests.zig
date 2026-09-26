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
        // The backtracker, forced: the dispatcher would route this pattern to
        // the VM.
        var re = try zregex.Regex.compileWithOptions(gpa, pattern, .{ .case_insensitive = f.i, .multiline = f.m, .dot_all = f.s, .force_tier = .expert });
        defer re.deinit();
        try testing.expect(re.t0 == null);
        for (subjects) |s| {
            const s16 = try zregex.subject.utf16FromWtf8(gpa, s);
            defer gpa.free(s16);
            try compareAll(&re, &prog, .{ .wtf8 = s }, &bt, &vs);
            try compareAll(&re, &prog, .{ .utf16 = s16 }, &bt, &vs);
        }
    }
}

// ---------------------------------------------------------------- F4a(3)

fn routedToVm(pattern: []const u8, options: zregex.CompileOptions) !bool {
    const re = try zregex.Regex.compileWithOptions(testing.allocator, pattern, options);
    defer re.deinit();
    return re.t0 != null;
}

test "dispatcher: eligible T0 patterns go to the VM, the rest to the backtracker" {
    for (cases) |c| try testing.expect(try routedToVm(c[0], .{ .case_insensitive = c[1].i, .multiline = c[1].m, .dot_all = c[1].s }));
    // Captures (F4b), T2, T1, a raw pattern byte.
    for ([_][]const u8{ "(a)", "(?<n>a)b", "a(?=b)", "(a)\\1", "(?<=a)b", "\xE9", "(?:a?)*" }) |p|
        try testing.expect(!try routedToVm(p, .{}));
    try testing.expect(!try routedToVm("a", .{ .unicode = true }));
    try testing.expect(!try routedToVm("a", .{ .v = true }));
    try testing.expect(!try routedToVm("\\u00e9", .{ .case_insensitive = true }));
}

test "dispatcher: an unclassifiable pattern goes to the backtracker, without error" {
    // Known deviations: D10 (`{n}` above 65536, clamped) and D8 (possessive,
    // compile's opt-in only). D1 was fixed in F1 and no longer exists.
    const a = testing.allocator;
    for ([_]struct { []const u8, zregex.CompileOptions }{
        .{ "a{70000}", .{} },
        .{ "x|a{65537}?", .{} },
        .{ "a*+b", .{ .possessive = true } },
        .{ "a?+", .{ .possessive = true } },
    }) |c| {
        const pattern, const options = c;
        var re = try zregex.Regex.compileWithOptions(a, pattern, options);
        defer re.deinit();
        try testing.expect(re.t0 == null);
    }
    // And it still runs, on the backtracker: `a*+` never gives back.
    var re = try zregex.Regex.compileWithOptions(a, "a*+a", .{ .possessive = true });
    defer re.deinit();
    try testing.expect(try re.find("aaa") == null);
}

fn expectUnavailable(pattern: []const u8, options: zregex.CompileOptions, expected: zregex.TierUnavailable) !void {
    var diag: zregex.TierUnavailable = undefined;
    var o = options;
    o.force_tier = .regular;
    o.tier_diagnostic = &diag;
    try testing.expectError(error.TierUnavailable, zregex.Regex.compileWithOptions(testing.allocator, pattern, o));
    try testing.expectEqualDeep(expected, diag);
}

test "force_tier .regular: the three reasons it can't be honored" {
    // Not classifiable.
    try expectUnavailable("a{70000}", .{}, .{ .not_classifiable = .{ .known_deviation = .d10_quantifier_min_clamped } });
    try expectUnavailable("a*+", .{ .possessive = true }, .{ .not_classifiable = .{ .known_deviation = .d8_possessive } });
    // A tier above T0.
    try expectUnavailable("a", .{ .unicode = true }, .{ .tier_too_high = .unicode });
    try expectUnavailable("\\p{L}", .{ .unicode = true }, .{ .tier_too_high = .unicode });
    try expectUnavailable("a(?=b)", .{}, .{ .tier_too_high = .expert });
    try expectUnavailable("(a)\\1", .{}, .{ .tier_too_high = .expert });
    // T0, but not what the VM takes in F4a.
    try expectUnavailable("(a)b", .{}, .{ .not_eligible = .capture });
    try expectUnavailable("(?:a?)*", .{}, .{ .not_eligible = .nullable_repeat });
    try expectUnavailable("\xE9", .{}, .{ .not_eligible = .raw_byte });
    // An eligible pattern compiles onto the VM.
    const re = try zregex.Regex.compileWithOptions(testing.allocator, "a+b", .{ .force_tier = .regular });
    defer re.deinit();
    try testing.expect(re.t0 != null);
}

test "force_tier .expert and .unicode" {
    try testing.expect(!try routedToVm("abc", .{ .force_tier = .expert }));
    try expectUnavailableTier("abc", .unicode, .{ .not_built = .unicode });
}

fn expectUnavailableTier(pattern: []const u8, tier: zregex.analysis.Tier, expected: zregex.TierUnavailable) !void {
    var diag: zregex.TierUnavailable = undefined;
    try testing.expectError(error.TierUnavailable, zregex.Regex.compileWithOptions(testing.allocator, pattern, .{ .force_tier = tier, .tier_diagnostic = &diag }));
    try testing.expectEqualDeep(expected, diag);
}

test "the facade gives the same results on the VM and on the backtracker" {
    const a = testing.allocator;
    const inputs = [_][]const u8{ "", "abc aab ab", "\u{E9}ab\u{1F600}abab", "xxaaaa" };
    for ([_][]const u8{ "ab", "a*", "a+?b", "(?:ab|a)", "\\bab", "$", "[^b]" }) |p| {
        var vm_re = try zregex.Regex.compile(a, p);
        defer vm_re.deinit();
        try testing.expect(vm_re.t0 != null);
        var bt_re = try zregex.Regex.compileWithOptions(a, p, .{ .force_tier = .expert });
        defer bt_re.deinit();
        for (inputs) |in| {
            var ms1 = try vm_re.findAll(in);
            defer {
                for (ms1.items) |m| m.deinit();
                ms1.deinit(a);
            }
            var ms2 = try bt_re.findAll(in);
            defer {
                for (ms2.items) |m| m.deinit();
                ms2.deinit(a);
            }
            try testing.expectEqual(ms2.items.len, ms1.items.len);
            for (ms1.items, ms2.items) |x, y| {
                try testing.expectEqual(y.start, x.start);
                try testing.expectEqual(y.end, x.end);
                try testing.expectEqual(@as(usize, 1), x.captures.len);
            }
            try testing.expectEqual(try bt_re.matchFull(in), try vm_re.matchFull(in));
            for (0..in.len + 1) |i| {
                const f1 = try vm_re.findAt(in, i);
                defer if (f1) |m| m.deinit();
                const f2 = try bt_re.findAt(in, i);
                defer if (f2) |m| m.deinit();
                try testing.expectEqual(f2 == null, f1 == null);
                if (f1) |m| try testing.expectEqual(f2.?.end, m.end);
            }
            const r1 = try vm_re.replaceAll(a, in, "<$&>");
            defer a.free(r1);
            const r2 = try bt_re.replaceAll(a, in, "<$&>");
            defer a.free(r2);
            try testing.expectEqualStrings(r2, r1);
        }
    }
}

test "execAt on the VM: a warm composite scratch allocates nothing" {
    const a = testing.allocator;
    var re = try zregex.Regex.compile(a, "a+b|c");
    defer re.deinit();
    try testing.expect(re.t0 != null);
    var failing: std.testing.FailingAllocator = .init(a, .{});
    var scratch = zregex.Scratch.init(failing.allocator());
    defer scratch.deinit();
    // `init` allocates nothing: each executor's buffers come on first use.
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    var buf: [2]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = &buf };
    _ = try re.execAt(.{ .wtf8 = "xaab c" }, 0, &scratch, &out, .{});
    const warm = failing.allocations;
    try testing.expect(warm > 0);
    const s16 = [_]u16{ 'x', 'a', 'b', 'c' };
    for (0..4) |i| {
        _ = try re.execAt(.{ .wtf8 = "xaab c" }, i, &scratch, &out, .{});
        _ = try re.execAt(.{ .utf16 = &s16 }, i, &scratch, &out, .{});
    }
    try testing.expectEqual(warm, failing.allocations);
    try testing.expect(!scratch.in_use);
}

// ------------------------------------------------ F4a(4) prep: path audit

test "unicode and v together are a SyntaxError, as in Flags.parse" {
    try testing.expectError(error.IncompatibleFlags, zregex.Regex.compileWithOptions(testing.allocator, "a", .{ .unicode = true, .v = true }));
    try testing.expectError(error.IncompatibleFlags, zregex.analysis.Flags.parse("uv"));
    try testing.expectError(error.IncompatibleFlags, zregex.compile(testing.allocator, "a", .{ .unicode = true, .v = true }));
}

test "Regex.findAll (F4a) and tier2 Matcher.findAll agree on the backtracker" {
    // Two implementations of the same facade loop since F4a(3): the Regex
    // one (dispatching) and the backtracker's own, still used by its tests.
    const a = testing.allocator;
    for (cases) |c| {
        const pattern, const f = c;
        const re = try zregex.Regex.compileWithOptions(a, pattern, .{ .case_insensitive = f.i, .multiline = f.m, .dot_all = f.s, .force_tier = .expert });
        defer re.deinit();
        const m = zregex.tier2.matcher.Matcher.initCompiled(a, re.compiled);
        for (subjects) |s| {
            var x = try re.findAll(s);
            defer {
                for (x.items) |r| r.deinit();
                x.deinit(a);
            }
            var y = try m.findAll(s, false);
            defer {
                for (y.items) |r| r.deinit();
                y.deinit(a);
            }
            try testing.expectEqual(y.items.len, x.items.len);
            for (x.items, y.items) |p, q| {
                try testing.expectEqual(q.start, p.start);
                try testing.expectEqual(q.end, p.end);
            }
        }
    }
}

test "existsAnchoredMatch at a position agrees with a sticky exec there" {
    const gpa = testing.allocator;
    var vs: tier0.VmScratch = .init(gpa);
    defer vs.deinit();
    for (cases) |c| {
        const pattern, const f = c;
        const fe = try zregex.lower.Frontend.init(gpa, pattern, .{}, .{ .ignore_case = f.i, .multiline = f.m, .dot_all = f.s });
        defer fe.deinit();
        const prog = try tier0.compile(gpa, fe.root);
        defer prog.deinit(gpa);
        for (subjects) |s8| {
            const s16 = try zregex.subject.utf16FromWtf8(gpa, s8);
            defer gpa.free(s16);
            for ([_]zregex.Subject{ .{ .wtf8 = s8 }, .{ .utf16 = s16 } }) |subj| {
                for (0..subj.len() + 1) |i| {
                    if (!subj.isPosition(i)) continue;
                    var budget: zregex.Budget = .unlimited;
                    const exists = try tier0.existsAnchoredMatch(&prog, subj, .code_unit, i, .forward, &vs, &budget);
                    const found = (try vm(&prog, subj, i, true, &vs)).found;
                    testing.expectEqual(found, exists) catch |err| {
                        std.debug.print("/{s}/ at {d} ({s})\n", .{ pattern, i, @tagName(subj) });
                        return err;
                    };
                }
            }
        }
    }
}
