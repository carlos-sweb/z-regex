//! F4a: T0's Pike VM against the backtracker, on patterns T0 takes
//! (docs/REGEX_TIERS_PLAN.md, F4a). Every subject, every index (positions
//! and not), sticky and not, in WTF-8 and UTF-16: the same outcome and the
//! same `[start, end]`. The full run over the 7,453 eligible patterns of
//! the F2c corpus is reported in the F4a(2) commit; this is the part that
//! stays in the suite.

const std = @import("std");
const zregex = @import("zregex");
const testing = std.testing;
const tier0 = zregex.internal.tier0;

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
    // F4a(4): each prefilter, and where one must not apply.
    .{ "\u{E9}\u{20AC}", .{} }, // literal, non-ASCII
    .{ "\u{1F600}", .{} }, // surrogates without `u`: not a literal
    .{ "x\u{1F600}", .{} },
    .{ "[a-z]+", .{} }, // class_run
    .{ "\\d*", .{} },
    .{ "[0-9]+", .{ .i = true } },
    .{ "\\bfoo", .{} }, // first
    .{ "foo|bar", .{} },
    .{ "[^a]x", .{} },
    .{ "a|\u{E9}", .{} },
    .{ "12-", .{ .i = true } }, // literal under `i`, no letters
    .{ "^ab", .{ .m = true } }, // not anchored under `m`
};

const subjects = [_][]const u8{
    "",             "a",                            "ab",         "abcd",         "aaab",          "abab ab",
    "bab\nab",      "xAbAB",                        "123-4567 1", "joe@site.com", "\u{E9}\u{E9}x", "\u{1F600}x\u{1F600}",
    "a\u{2028}b",   "\xED\xA0\x80a",                "_\xff\xc3",  "ccbca",        "foo bar,foo",   "x\u{E9}\u{20AC}\u{E9}\u{20AC}",
    "ab\nab xyz09", "\u{1F600}\u{1F600}x\u{1F600}",
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
        const fe = try zregex.internal.lower.Frontend.init(gpa, pattern, .{}, .{ .ignore_case = f.i, .multiline = f.m, .dot_all = f.s });
        defer fe.deinit();
        testing.expectEqual(@as(?tier0.Ineligible, null), tier0.check(fe.root)) catch |err| {
            std.debug.print("/{s}/ is not T0-eligible\n", .{pattern});
            return err;
        };
        const prog = try tier0.compile(gpa, fe.root);
        defer prog.deinit(gpa);
        const plain = try tier0.compileWith(gpa, fe.root, .{ .prefilters = false });
        defer plain.deinit(gpa);
        // The backtracker, forced: the dispatcher would route this pattern to
        // the VM.
        var re = try zregex.Regex.compileWithOptions(gpa, pattern, .{ .case_insensitive = f.i, .multiline = f.m, .dot_all = f.s, .force_tier = .expert });
        defer re.deinit();
        try testing.expect(re.t0 == null);
        for (subjects) |s| {
            const s16 = try zregex.internal.subject.utf16FromWtf8(gpa, s);
            defer gpa.free(s16);
            try compareAll(&re, &prog, .{ .wtf8 = s }, &bt, &vs);
            try compareAll(&re, &prog, .{ .utf16 = s16 }, &bt, &vs);
            try compareAll(&re, &plain, .{ .wtf8 = s }, &bt, &vs);
            try compareAll(&re, &plain, .{ .utf16 = s16 }, &bt, &vs);
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
    // Routing to the VM: not in the forced-backtracker run (F4a(5)).
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    for (cases) |c| try testing.expect(try routedToVm(c[0], .{ .case_insensitive = c[1].i, .multiline = c[1].m, .dot_all = c[1].s }));
    // Groups and iterated nullable bodies: the tagged program (F4b).
    for ([_]struct { []const u8, u32 }{ .{ "(a)", 4 }, .{ "(?<n>a)b", 4 }, .{ "(?:a?)*", 2 }, .{ "((a)|b)+", 6 } }) |c| {
        const re = try zregex.Regex.compileWithOptions(testing.allocator, c[0], .{});
        defer re.deinit();
        try testing.expectEqual(c[1], re.t0.?.nslots);
    }
    // No groups, no nullable loop: F4a's program (no phase product).
    const plain = try zregex.Regex.compileWithOptions(testing.allocator, "(?:ab)+", .{});
    defer plain.deinit();
    for (plain.t0.?.insts) |inst| try testing.expect(inst != .fail and inst != .clear);
    // T2, T1, a raw pattern byte.
    for ([_][]const u8{ "a(?=b)", "(a)\\1", "(?<=a)b", "\xE9" }) |p|
        try testing.expect(!try routedToVm(p, .{}));
    // T1 goes to the VM since F5a (and with folding since F5b; see below);
    // `v` doesn't.
    try testing.expect(!try routedToVm("a", .{ .v = true }));
    try testing.expect(try routedToVm("\\u00e9", .{ .case_insensitive = true }));
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

fn expectUnavailable(pattern: []const u8, options: zregex.CompileOptions, expected: zregex.internal.TierUnavailable) !void {
    var diag: zregex.internal.TierUnavailable = undefined;
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
    // T0, but not what the VM takes: a raw pattern byte, and a tagged
    // program over the slot bound (1,200 groups: ~3,600 instructions x
    // 2,402 slots > 2^20).
    try expectUnavailable("\xE9", .{}, .{ .not_eligible = .raw_byte });
    const many = try std.mem.concat(testing.allocator, u8, &(.{"(a)"} ** 1200));
    defer testing.allocator.free(many);
    try expectUnavailable(many, .{}, .{ .not_eligible = .too_large });
    // Groups and nullable loops compile onto the VM since F4b.
    for ([_][]const u8{ "(a)b", "(?:a?)*" }) |p| {
        const re = try zregex.Regex.compileWithOptions(testing.allocator, p, .{ .force_tier = .regular });
        defer re.deinit();
        try testing.expect(re.t0 != null);
    }
    // An eligible pattern compiles onto the VM.
    const re = try zregex.Regex.compileWithOptions(testing.allocator, "a+b", .{ .force_tier = .regular });
    defer re.deinit();
    try testing.expect(re.t0 != null);
}

test "force_tier .expert and .unicode" {
    // Routing to the VM: not in the forced-backtracker run (F4a(5)).
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    try testing.expect(!try routedToVm("abc", .{ .force_tier = .expert }));
    // `.unicode` (F5a): the VM for T0 and for T1 without folding.
    try testing.expect(try routedToVm("abc", .{ .force_tier = .unicode }));
    try testing.expect(try routedToVm("\\p{L}+", .{ .unicode = true, .force_tier = .unicode }));
    // Since F5b, Unicode folding too; `v` still isn't built.
    try testing.expect(try routedToVm("\u{E9}", .{ .unicode = true, .case_insensitive = true, .force_tier = .unicode }));
    var diag: zregex.internal.TierUnavailable = undefined;
    try testing.expectError(error.TierUnavailable, zregex.Regex.compileWithOptions(testing.allocator, "[\\p{L}--[a]]", .{ .v = true, .force_tier = .unicode, .tier_diagnostic = &diag }));
    try testing.expectEqualDeep(zregex.internal.TierUnavailable{ .not_built = .unicode }, diag);
    try expectUnavailableTier("a(?=b)", .unicode, .{ .tier_too_high = .expert });
}

test "F5a: T1 without folding runs on T0's VM" {
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    for ([_][]const u8{ "a", "\\p{L}+", "[\\p{Script=Greek}\\d]+", "(\\p{Lu})\\p{Ll}*", "\\P{L}", ".", "\\u{1F600}" }) |p|
        testing.expect(try routedToVm(p, .{ .unicode = true })) catch |err| {
            std.debug.print("/{s}/u stays off the VM\n", .{p});
            return err;
        };
    // Still on the backtracker: `v` (F5c).
    try testing.expect(!try routedToVm("[\\p{L}--[a]]", .{ .v = true }));
}

test "F5b: T1 with Unicode case folding runs on T0's VM" {
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    // `iu`, and `i` without `u` on non-ASCII content: the folded sets are in
    // the HIR; `\b` counts the extended WordCharacters on the VM too.
    for ([_][]const u8{ "\\p{L}", "k", "\u{DF}+", "[\u{C0}-\u{D6}]", "\\w+\\b", "[^\\W]" }) |p|
        testing.expect(try routedToVm(p, .{ .unicode = true, .case_insensitive = true })) catch |err| {
            std.debug.print("/{s}/iu stays off the VM\n", .{p});
            return err;
        };
    for ([_][]const u8{ "\u{E9}", "[\u{C0}-\u{D6}]+", "\u{3C3}" }) |p|
        testing.expect(try routedToVm(p, .{ .case_insensitive = true })) catch |err| {
            std.debug.print("/{s}/i stays off the VM\n", .{p});
            return err;
        };
}

fn expectUnavailableTier(pattern: []const u8, tier: zregex.internal.analysis.Tier, expected: zregex.internal.TierUnavailable) !void {
    var diag: zregex.internal.TierUnavailable = undefined;
    try testing.expectError(error.TierUnavailable, zregex.Regex.compileWithOptions(testing.allocator, pattern, .{ .force_tier = tier, .tier_diagnostic = &diag }));
    try testing.expectEqualDeep(expected, diag);
}

test "the facade gives the same results on the VM and on the backtracker" {
    // Routing to the VM: not in the forced-backtracker run (F4a(5)).
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
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
    // Routing to the VM: not in the forced-backtracker run (F4a(5)).
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
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

test "execAt on the tagged VM (F4b): a warm composite scratch allocates nothing" {
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    const a = testing.allocator;
    var failing: std.testing.FailingAllocator = .init(a, .{});
    var scratch = zregex.Scratch.init(failing.allocator());
    defer scratch.deinit();
    for ([_][]const u8{ "(\\d{3})-(\\d{4})", "((a)|b)+c", "(?:x?)*y" }) |pattern| {
        var re = try zregex.Regex.compile(a, pattern);
        defer re.deinit();
        try testing.expect(re.t0 != null);
        var buf: [6]?usize = undefined;
        var out: zregex.MatchSlots = .{ .slots = buf[0..re.slotCount()] };
        const subject = "x555-1234 abac y";
        _ = try re.execAt(.{ .wtf8 = subject }, 0, &scratch, &out, .{});
        const warm = failing.allocations;
        const s16 = try zregex.internal.subject.utf16FromWtf8(a, subject);
        defer a.free(s16);
        _ = try re.execAt(.{ .utf16 = s16 }, 0, &scratch, &out, .{});
        const warm16 = failing.allocations;
        try testing.expectEqual(warm, warm16);
        for (0..subject.len) |i| {
            _ = try re.execAt(.{ .wtf8 = subject }, i, &scratch, &out, .{});
            _ = try re.execAt(.{ .utf16 = s16 }, i, &scratch, &out, .{});
        }
        try testing.expectEqual(warm, failing.allocations);
    }
    try testing.expect(!scratch.in_use);
}

// ------------------------------------------------ F4a(4) prep: path audit

test "unicode and v together are a SyntaxError, as in Flags.parse" {
    try testing.expectError(error.IncompatibleFlags, zregex.Regex.compileWithOptions(testing.allocator, "a", .{ .unicode = true, .v = true }));
    try testing.expectError(error.IncompatibleFlags, zregex.internal.analysis.Flags.parse("uv"));
    try testing.expectError(error.IncompatibleFlags, zregex.internal.compile(testing.allocator, "a", .{ .unicode = true, .v = true }));
}

test "Regex.findAll (F4a) and tier2 Matcher.findAll agree on the backtracker" {
    // Two implementations of the same facade loop since F4a(3): the Regex
    // one (dispatching) and the backtracker's own, still used by its tests.
    const a = testing.allocator;
    for (cases) |c| {
        const pattern, const f = c;
        const re = try zregex.Regex.compileWithOptions(a, pattern, .{ .case_insensitive = f.i, .multiline = f.m, .dot_all = f.s, .force_tier = .expert });
        defer re.deinit();
        const m = zregex.internal.tier2.matcher.Matcher.initCompiled(a, re.compiled);
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
        const fe = try zregex.internal.lower.Frontend.init(gpa, pattern, .{}, .{ .ignore_case = f.i, .multiline = f.m, .dot_all = f.s });
        defer fe.deinit();
        const prog = try tier0.compile(gpa, fe.root);
        defer prog.deinit(gpa);
        for (subjects) |s8| {
            const s16 = try zregex.internal.subject.utf16FromWtf8(gpa, s8);
            defer gpa.free(s16);
            for ([_]zregex.Subject{ .{ .wtf8 = s8 }, .{ .utf16 = s16 } }) |subj| {
                for (0..subj.len() + 1) |i| {
                    if (!subj.isPosition(i)) continue;
                    var budget: zregex.internal.Budget = .unlimited;
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

// --------------------------------------------------------- F4a(4): prefilters

fn prefilterKind(pattern: []const u8) !std.meta.Tag(tier0.prefilter.Prefilter.Kind) {
    const re = try zregex.Regex.compile(testing.allocator, pattern);
    defer re.deinit();
    return std.meta.activeTag(re.t0.?.prefilter.kind);
}

test "prefilters: which one each pattern gets" {
    // Routing to the VM: not in the forced-backtracker run (F4a(5)).
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    try testing.expectEqual(.literal, try prefilterKind("hello"));
    try testing.expectEqual(.class_run, try prefilterKind("[a-z]+"));
    try testing.expectEqual(.shift_and, try prefilterKind("\\d{3}-\\d{4}"));
    try testing.expectEqual(.shift_and, try prefilterKind("(\\d{3})-(\\d{4})"));
    try testing.expectEqual(.first, try prefilterKind("[\\w.+-]+@[\\w-]+\\.[\\w.]+"));
    try testing.expectEqual(.none, try prefilterKind("a?"));
    const off = try zregex.Regex.compileWithOptions(testing.allocator, "hello", .{ .t0_prefilters = false });
    defer off.deinit();
    try testing.expectEqual(.none, std.meta.activeTag(off.t0.?.prefilter.kind));
}

test "class_run sticky: only at the index" {
    // Routing to the VM: not in the forced-backtracker run (F4a(5)).
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    var re = try zregex.Regex.compileWithOptions(testing.allocator, "[a-z]+", .{ .sticky = true });
    defer re.deinit();
    var scratch = zregex.Scratch.init(testing.allocator);
    defer scratch.deinit();
    var buf: [2]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = &buf };
    // The first member is further on: no match.
    try testing.expect(!try re.execAt(.{ .wtf8 = "12ab" }, 0, &scratch, &out, .{}));
    try testing.expect(try re.execAt(.{ .wtf8 = "12ab" }, 2, &scratch, &out, .{}));
    try testing.expectEqual(@as(?usize, 4), buf[1]);
}

test "fast paths never touch the VM scratch" {
    // Routing to the VM: not in the forced-backtracker run (F4a(5)).
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var scratch = zregex.Scratch.init(failing.allocator());
    defer scratch.deinit();
    var buf: [2]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = &buf };
    for ([_][]const u8{ "hello", "[a-z]+", "\\d*", "\\d{3}-\\d{4}" }) |p| {
        var re = try zregex.Regex.compile(testing.allocator, p);
        defer re.deinit();
        const kind = std.meta.activeTag(re.t0.?.prefilter.kind);
        try testing.expect(kind == .literal or kind == .class_run or kind == .shift_and);
        _ = try re.execAt(.{ .wtf8 = "say hello 123" }, 0, &scratch, &out, .{});
        const s16 = [_]u16{ 'h', 'e', 'l', 'l', 'o' };
        _ = try re.execAt(.{ .utf16 = &s16 }, 0, &scratch, &out, .{});
    }
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    try testing.expectEqual(@as(usize, 0), scratch.vm.capacity);
}

test "forced-backtracker build: an eligible pattern stays on the backtracker" {
    const re = try zregex.Regex.compile(testing.allocator, "abc");
    defer re.deinit();
    try testing.expectEqual(zregex.internal.force_backtracker, re.t0 == null);
    // An explicit force_tier still wins.
    const forced = try zregex.Regex.compileWithOptions(testing.allocator, "abc", .{ .force_tier = .regular });
    defer forced.deinit();
    try testing.expect(forced.t0 != null);
}

// ---------------------------------------------------------------- F4b(2)

/// Patterns with groups where the backtracker is right (no group inside an
/// iterated body: it neither resets them per iteration nor rejects empty
/// iterations): the two passes against it, all slots.
const capture_cases = [_]struct { []const u8, Flags }{
    .{ "(a)|b", .{} },
    .{ "(a|ab)(c|bcd)(d*)", .{} },
    .{ "(\\d{3})-(\\d{4})", .{} },
    .{ "(\\w+)@(\\w+)\\.com", .{} },
    .{ "(a+?)(a*)", .{} },
    .{ "(?<x>a)(?<y>b)?", .{} },
    .{ "^(a)|(b)$", .{ .m = true } },
    .{ "(a)?b", .{} },
    .{ "(\\b\\w+\\b)", .{} },
    .{ "([^a]+)(a)", .{} },
    .{ "(A)(b)", .{ .i = true } },
    .{ "(.)(.)", .{ .s = true } },
    .{ "((.)\\2?)", .{} },
};

fn tagged(gpa: std.mem.Allocator, pattern: []const u8, f: Flags) !tier0.Program {
    const fe = try zregex.internal.lower.Frontend.init(gpa, pattern, .{}, .{ .ignore_case = f.i, .multiline = f.m, .dot_all = f.s });
    defer fe.deinit();
    return tier0.compileWith(gpa, fe.root, .{ .tagged = true });
}

test "tagged VM (two passes) matches the backtracker, all slots" {
    const gpa = testing.allocator;
    var bt: zregex.Scratch = .init(gpa);
    defer bt.deinit();
    var vs: tier0.VmScratch = .init(gpa);
    defer vs.deinit();
    for (capture_cases) |c| {
        const pattern, const f = c;
        // `((.)\2?)` has a backreference: not T0, not tagged-eligible.
        const prog = tagged(gpa, pattern, f) catch |err| {
            try testing.expectEqual(error.Ineligible, err);
            try testing.expectEqualStrings("((.)\\2?)", pattern);
            continue;
        };
        defer prog.deinit(gpa);
        var re = try zregex.Regex.compileWithOptions(gpa, pattern, .{ .case_insensitive = f.i, .multiline = f.m, .dot_all = f.s, .force_tier = .expert });
        defer re.deinit();
        const n = prog.nslots;
        for (subjects) |s| {
            const s16 = try zregex.internal.subject.utf16FromWtf8(gpa, s);
            defer gpa.free(s16);
            for ([_]zregex.Subject{ .{ .wtf8 = s }, .{ .utf16 = s16 } }) |subj| {
                for ([_]bool{ false, true }) |sticky| {
                    re.sticky = sticky;
                    for (0..subj.len() + 2) |i| {
                        var want: [16]?usize = undefined;
                        var out: zregex.MatchSlots = .{ .slots = want[0..n] };
                        const b = re.execAt(subj, i, &bt, &out, .{});
                        var got: [16]?usize = undefined;
                        const a = switch (subj) {
                            .wtf8 => |x| tier0.execCaptures(&prog, u8, x, .code_unit, i, sticky, &vs, got[0..n]),
                            .utf16 => |x| tier0.execCaptures(&prog, u16, x, .code_unit, i, sticky, &vs, got[0..n]),
                        };
                        const bf = b catch |err| {
                            try testing.expectError(err, a);
                            continue;
                        };
                        const af = try a;
                        testing.expectEqual(bf, af) catch |err| {
                            std.debug.print("/{s}/ {s} i={d} sticky={}\n", .{ pattern, @tagName(subj), i, sticky });
                            return err;
                        };
                        if (bf) testing.expectEqualSlices(?usize, want[0..n], got[0..n]) catch |err| {
                            std.debug.print("/{s}/ {s} i={d} sticky={}\n", .{ pattern, @tagName(subj), i, sticky });
                            return err;
                        };
                    }
                }
            }
        }
    }
}

test "tagged VM gives V8's captures where the backtracker doesn't (empty iterations)" {
    // V8's results, checked with Node (`d` flag). The backtracker keeps a
    // group from an earlier iteration (RepeatMatcher step 4: reset each
    // iteration, D4) and accepts the empty iteration of an optional or
    // iterated nullable body (D3); in UTF-16 indices.
    const gpa = testing.allocator;
    var vs: tier0.VmScratch = .init(gpa);
    defer vs.deinit();
    const n = null;
    const v8 = [_]struct { []const u8, []const u8, []const ?usize }{
        .{ "(a*)*", "", &.{ 0, 0, n, n } },
        .{ "(a*)*", "b", &.{ 0, 0, n, n } },
        .{ "(a*)+", "aa", &.{ 0, 2, 0, 2 } },
        .{ "((a*)*)*", "", &.{ 0, 0, n, n, n, n } },
        .{ "((a*)*)*", "a", &.{ 0, 1, 0, 1, 0, 1 } },
        .{ "(?:[^a]?(\\x62?)?)", "\nab", &.{ 0, 1, n, n } },
        .{ "(\u{E9}{0})?", "x", &.{ 0, 0, n, n } },
        .{ "(a{0})*\\B", "", &.{ 0, 0, n, n } },
        .{ "([^#/?]*)(.*)?", "ab", &.{ 0, 2, 0, 2, n, n } },
        .{ "(\\W|){2,}\\.", ".", &.{ 0, 1, 0, 0 } },
        .{ "(?:(a)|b)+", "ab", &.{ 0, 2, n, n } },
        .{ "(\\*{0,1}?)?", "*", &.{ 0, 1, 0, 1 } },
        .{ "(?<n0>0*?)?\u{3A3}", "\u{3A3}", &.{ 0, 1, n, n } },
        .{ "\\s\\w|\\*(\\*|)*\\.*", "**.", &.{ 0, 3, 1, 2 } },
        .{ "(k*?)+|", "kk", &.{ 0, 2, 1, 2 } },
        .{ "(?:(a)|b)*c", "abcd", &.{ 0, 3, n, n } },
        .{ "((a)|b)+", "ab", &.{ 0, 2, 1, 2, n, n } },
        .{ "(?:(a)(b)?)+", "aba", &.{ 0, 3, 2, 3, n, n } },
    };
    for (v8) |c| {
        const pattern, const s, const want = c;
        const prog = try tagged(gpa, pattern, .{});
        defer prog.deinit(gpa);
        const s16 = try zregex.internal.subject.utf16FromWtf8(gpa, s);
        defer gpa.free(s16);
        var got: [8]?usize = undefined;
        try testing.expect(try tier0.execCaptures(&prog, u16, s16, .code_unit, 0, false, &vs, got[0..prog.nslots]));
        testing.expectEqualSlices(?usize, want, got[0..prog.nslots]) catch |err| {
            std.debug.print("/{s}/ on {f}\n", .{ pattern, std.zig.fmtString(s) });
            return err;
        };
    }
}

test "tagged VM on the iteration corpus: V8's captures (F4b, D3 and D4)" {
    // tests/corpus/iter_v8.tsv: one pattern in 8 of the iteration corpus
    // (scripts/iter_corpus/gen.mjs), with V8's slots on each subject from
    // index 0. The random corpora never exercise the per-iteration reset;
    // this one does (a VM ignoring `clear` fails here).
    const gpa = testing.allocator;
    const subjects_iter = [_][]const u8{ "", "a", "ab", "abab", "aab c", "ba1b", "xabx", "1a2b3c" };
    var vs: tier0.VmScratch = .init(gpa);
    defer vs.deinit();
    var lines = std.mem.splitScalar(u8, @embedFile("corpus/iter_v8.tsv"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const pattern = cols.next().?;
        const prog = try tagged(gpa, pattern, .{});
        defer prog.deinit(gpa);
        const n = prog.nslots;
        for (subjects_iter) |s| {
            const want_col = cols.next().?;
            var want: [8]?usize = undefined;
            const found = !std.mem.eql(u8, want_col, "null");
            if (found) {
                var it = std.mem.splitScalar(u8, want_col, ',');
                var k: usize = 0;
                while (it.next()) |v| : (k += 1) want[k] = if (v[0] == '-') null else try std.fmt.parseInt(usize, v, 10);
                try testing.expectEqual(n, k);
            }
            const s16 = try zregex.internal.subject.utf16FromWtf8(gpa, s);
            defer gpa.free(s16);
            var got8: [8]?usize = undefined;
            var got16: [8]?usize = undefined;
            const found8 = try tier0.execCaptures(&prog, u8, s, .code_unit, 0, false, &vs, got8[0..n]);
            const found16 = try tier0.execCaptures(&prog, u16, s16, .code_unit, 0, false, &vs, got16[0..n]);
            testing.expectEqual(found, found8) catch |err| {
                std.debug.print("/{s}/ on \"{s}\"\n", .{ pattern, s });
                return err;
            };
            try testing.expectEqual(found, found16);
            if (!found) continue;
            testing.expectEqualSlices(?usize, want[0..n], got8[0..n]) catch |err| {
                std.debug.print("/{s}/ on \"{s}\"\n", .{ pattern, s });
                return err;
            };
            try testing.expectEqualSlices(?usize, want[0..n], got16[0..n]);
            checked += 1;
        }
    }
    try testing.expect(checked > 1000);
}

// ---------------------------------------------------------------- F5a

/// Every index of `subj` (and two past the end), sticky and not: the
/// dispatcher's route (the VM for these) against the backtracker, all
/// slots, errors included.
fn compareRoutes(vm_re: *zregex.Regex, bt_re: *zregex.Regex, subj: zregex.Subject) !void {
    var s1: zregex.Scratch = .init(testing.allocator);
    defer s1.deinit();
    var s2: zregex.Scratch = .init(testing.allocator);
    defer s2.deinit();
    var b1: [16]?usize = undefined;
    var b2: [16]?usize = undefined;
    const n = vm_re.slotCount();
    var o1: zregex.MatchSlots = .{ .slots = b1[0..n] };
    var o2: zregex.MatchSlots = .{ .slots = b2[0..n] };
    for ([_]bool{ false, true }) |sticky| {
        vm_re.sticky = sticky;
        bt_re.sticky = sticky;
        for (0..subj.len() + 2) |i| {
            const a = bt_re.execAt(subj, i, &s2, &o2, .{}) catch |err| {
                try testing.expectError(err, vm_re.execAt(subj, i, &s1, &o1, .{}));
                continue;
            };
            const b = try vm_re.execAt(subj, i, &s1, &o1, .{});
            const same = a == b and (!a or std.mem.eql(?usize, o1.slots, o2.slots));
            if (!same) {
                std.debug.print("/{s}/ index {d} sticky {}: vm {} {any}, backtracker {} {any}\n", .{ vm_re.pattern, i, sticky, b, o1.slots, a, o2.slots });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "F5a: the VM in code-point mode matches the backtracker on T1 patterns" {
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    const gpa = testing.allocator;
    const Case = struct { []const u8, zregex.CompileOptions };
    const u: zregex.CompileOptions = .{ .unicode = true };
    const t1_cases = [_]Case{
        .{ ".", u },                                       .{ ".+", u },                       .{ "^.$", u },
        .{ ".", .{ .unicode = true, .dot_all = true } },   .{ "[^a]", u },                     .{ "[^a]+", u },
        .{ "\\p{L}+", u },                                 .{ "\\P{L}", u },                   .{ "\\P{L}+?x", u },
        .{ "\\p{Script=Greek}+", u },                      .{ "(\\p{Lu})(\\p{Ll}*)", u },      .{ "[\\p{L}\\d]+", u },
        .{ "\\u{1F600}", u },                              .{ "[\\u{1F600}-\\u{1F64F}]+", u }, .{ "\\uD83D", u },
        .{ "\\b\\p{L}", u },                               .{ "\\B.", u },                     .{ "^\\p{N}", .{ .unicode = true, .multiline = true } },
        .{ "$", .{ .unicode = true, .multiline = true } }, .{ "(?:)", u },                     .{ "a*", u },
        .{ "(.)(?:\\p{L}|b)?", u },                        .{ "\\p{Any}", u },                 .{ "[\\0-\\u{10FFFF}]{2}", u },
        .{ "(\\P{Any})?x", u },
    };
    const t1_subjects = subjects ++ [_][]const u8{ "\u{3B1}\u{3B2}\u{391}x", "\xED\xB8\x80\u{1F600}\xED\xA0\x80", "A\u{1F600}b\u{1F601}C" };
    for (t1_cases) |c| {
        const pattern, const options = c;
        var vm_re = try zregex.Regex.compileWithOptions(gpa, pattern, options);
        defer vm_re.deinit();
        testing.expect(vm_re.t0 != null) catch |err| {
            std.debug.print("/{s}/ isn't routed to the VM\n", .{pattern});
            return err;
        };
        var o = options;
        o.force_tier = .expert;
        var bt_re = try zregex.Regex.compileWithOptions(gpa, pattern, o);
        defer bt_re.deinit();
        for (t1_subjects) |s| {
            const s16 = try zregex.internal.subject.utf16FromWtf8(gpa, s);
            defer gpa.free(s16);
            try compareRoutes(&vm_re, &bt_re, .{ .wtf8 = s });
            try compareRoutes(&vm_re, &bt_re, .{ .utf16 = s16 });
        }
    }
}

test "F5a: a group reset per iteration, as V8 (the backtracker keeps the stale group)" {
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    // `/(?:(\p{L})|\d)+/u` from 5 on "ab\nab xyz09": V8 gives [6, 11] with
    // group 1 undefined (the last iteration took `\d`, and each iteration
    // resets the group). The VM does; the backtracker keeps "z" (8, 9),
    // the iteration-reset bug F4b found on T0 patterns.
    var re = try zregex.Regex.compileWithOptions(testing.allocator, "(?:(\\p{L})|\\d)+", .{ .unicode = true });
    defer re.deinit();
    try testing.expect(re.t0 != null);
    var scratch: zregex.Scratch = .init(testing.allocator);
    defer scratch.deinit();
    var buf: [4]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = &buf };
    try testing.expect(try re.execAt(.{ .wtf8 = "ab\nab xyz09" }, 5, &scratch, &out, .{}));
    try testing.expectEqualSlices(?usize, &.{ 6, 11, null, null }, &buf);
}

// F5b(1b): `\b`/`\B` under `u` + `i` on T0's VM against the backtracker.
// `iu` patterns reach the VM through the dispatcher only after F5b's
// lowering (Part 2), so the VM runs here from the HIR directly, in code
// point mode, as the dispatcher will run it.
test "F5b: \\b under u + i, VM against the backtracker" {
    if (zregex.internal.force_backtracker) return error.SkipZigTest;
    const gpa = testing.allocator;
    const patterns = [_][]const u8{ "a\\b", "k\\b", "s\\B", "\\b\\w", "\\w\\b", "\\B" };
    const word_subjects = [_][]const u8{ "a\u{17F}", "a\u{212A}", "k\u{212A}!", "s\u{17F}x", "!\u{17F}x", "x\u{212A} y", "abc", "" };
    var extended_seen = false;
    for (patterns) |pattern| {
        const fe = try zregex.internal.lower.Frontend.init(gpa, pattern, .{ .unicode = true }, .{ .ignore_case = true });
        defer fe.deinit();
        const prog = try tier0.compile(gpa, fe.root);
        defer prog.deinit(gpa);
        try testing.expect(prog.word_ci);
        var bt = try zregex.Regex.compileWithOptions(gpa, pattern, .{ .unicode = true, .case_insensitive = true, .force_tier = .expert });
        defer bt.deinit();
        var scratch = tier0.VmScratch.init(gpa);
        defer scratch.deinit();
        var bt_scratch = zregex.Scratch.init(gpa);
        defer bt_scratch.deinit();
        for (word_subjects) |subj| {
            const s16 = try zregex.internal.subject.utf16FromWtf8(gpa, subj);
            defer gpa.free(s16);
            for ([_]zregex.Subject{ .{ .wtf8 = subj }, .{ .utf16 = s16 } }) |s| {
                var i: usize = 0;
                while (i <= s.len()) : (i += 1) {
                    if (!s.isPosition(i)) continue;
                    var vm_slots: [2]?usize = undefined;
                    const vm_found = switch (s) {
                        .wtf8 => |x| try tier0.exec(&prog, u8, x, .code_point, i, false, &scratch, &vm_slots),
                        .utf16 => |x| try tier0.exec(&prog, u16, x, .code_point, i, false, &scratch, &vm_slots),
                    };
                    var bt_buf: [2]?usize = undefined;
                    var out: zregex.MatchSlots = .{ .slots = &bt_buf };
                    const bt_found = try bt.execAt(s, i, &bt_scratch, &out, .{});
                    try testing.expectEqual(bt_found, vm_found);
                    if (vm_found) try testing.expectEqualSlices(?usize, &bt_buf, &vm_slots);
                }
            }
        }
        // The extension is live on the VM: `a\b` doesn't match "aſ".
        if (std.mem.eql(u8, pattern, "a\\b")) {
            var slots: [2]?usize = undefined;
            extended_seen = !try tier0.exec(&prog, u8, "a\u{17F}", .code_point, 0, false, &scratch, &slots);
        }
    }
    try testing.expect(extended_seen);
}
