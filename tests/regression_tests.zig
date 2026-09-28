//! Historical bugs as permanent regression tests (docs/REGEX_TIERS_PLAN.md,
//! F0d; §8.2 "bugs históricos → tests permanentes"). These are the bugs a
//! parser/matcher rewrite (F1 onward) is most likely to reintroduce.
//!
//! Bugs that already had a dedicated test are *not* duplicated here; this
//! index points at them so the full list lives in one place:
//!
//! | Bug (origin)                                                        | Existing test |
//! |---------------------------------------------------------------------|---------------|
//! | `/(a*)b\1+/` on "baaac" segfaulted (Phase 6)                        | tests/tier2_pipeline_tests.zig: "RecursiveMatcher: quantified backreference to an empty capture doesn't crash" |
//! | `/[a-z]+/i` ignored case in ranges (Phase 6)                         | src/regex.zig: "Regex: case_insensitive character ranges match both cases (test262 S15.10.2.8_A5_T1)" |
//! | `/[^o]/i` negated class ignored case (Phase 6)                       | src/regex.zig: "Regex: case_insensitive negated character class matches both cases (test262 S15.10.2.6_A3_T7)" |
//! | `/(123){1,}/` lost its last iteration's capture (Phase 6)           | src/regex.zig: "Regex: a quantified capturing group retains its last iteration's capture (test262 S15.10.2.7_A6_T4)" |
//! | `/(a)*/` was not greedy (Phase 6)                                    | src/regex.zig: "Regex: `*` on a capturing group is greedy (test262-style, was matching zero reps)" |
//! | `/^.*?$/` lazy star stuck after one iteration (Phase 6)              | src/regex.zig: "Regex: lazy star `.*?` can expand across multiple iterations (was stuck after one)" |
//! | stale capture across outer iterations (Phase 6)                      | src/regex.zig: "Regex: an optional group nested in a repeated group doesn't leak a stale capture across iterations (test262 S15.10.2.5_A1_T4)" |
//! | backref to a non-participating group failed (Phase 6)                | src/regex.zig: "Regex: a backreference to a group that never participated matches empty (spec, not a failure)" |
//! | negative lookahead's captures leaked (Phase 6)                       | src/regex.zig: "Regex: a negative lookahead's own captures don't leak out, whether it succeeds or fails (test262 S15.10.2.8_A2_T1)" |
//! | metacharacters in a class (`[*&$]`, `[.]`) (Phase 6)                 | src/regex.zig: "Regex: regex metacharacters are literal inside a character class" |
//! | shorthand classes as class members (`[a-c\d]`) (Phase 6)             | src/regex.zig: "Regex: shorthand classes as character class members" |
//! | `[^]` (Phase 6)                                                      | src/regex.zig: "Regex: [^] (negated empty class) matches any character" |
//! | `\s`/`\S` missing `\f`/`\v` (Phase 6)                                | src/regex.zig: "Regex: \\s and \\S include form feed and vertical tab" |
//! | nullable quantifier stack overflow (ce885bf)                        | tests/integration_tests.zig: "Integration: nullable star does not stack-overflow and matches" |
//! | multiline / dot_all / escapes / `{2,1}` (Phase 0)                    | src/regex.zig: "Regex: multiline flag ...", "Regex: dot excludes newline unless dot_all is set", "Regex: \\xHH, \\uHHHH, \\u{...}, \\0 and \\cX escapes", "Regex: invalid quantifier range {n,m} with n > m is rejected" |
//! | duplicate names in exclusive branches (Phase 2)                     | src/regex.zig: "Regex: duplicate named groups in mutually exclusive alternation branches are allowed" (+ the neighbouring duplicate-name tests) |
//!
//! New tests below cover the historical bugs that had no test yet.

const std = @import("std");
const zregex = @import("zregex");
const testing = std.testing;

fn expectFind(pattern: []const u8, input: []const u8, expected: []const u8) !void {
    var re = try zregex.Regex.compile(testing.allocator, pattern);
    defer re.deinit();
    const m = (try re.find(input)) orelse return error.TestExpectedMatch;
    defer m.deinit();
    try testing.expectEqualStrings(expected, m.group(input));
}

// Phase 6: `?` on a capturing group tried "skip" before "consume", so
// `/(a)?a/` on "aa" matched only "a".
test "regression: `?` on a capturing group is greedy (Phase 6)" {
    try expectFind("(a)?a", "aa", "aa");
    var re = try zregex.Regex.compile(testing.allocator, "(a)?a");
    defer re.deinit();
    const m = (try re.find("aa")).?;
    defer m.deinit();
    try testing.expectEqualStrings("a", m.getCapture(1, "aa").?);
}

// a30acf8: `{n}` counts near 2**53-1 overflowed the u32 count accumulator
// (a safety-check panic) before counts were saturated and bounded. What
// matters here is "no panic, no overflow": today such a count compiles
// (min clamped, D10); from F5 it may instead be error.PatternTooLarge.
// Either outcome is acceptable, a crash is not.
test "regression: astronomically large quantifier counts don't overflow (a30acf8)" {
    const patterns = [_][]const u8{
        "b{9007199254740991}",
        "b{9007199254740991,}",
        "b{0,9007199254740991}",
        "b{99999999999999999999999999999999}",
    };
    for (patterns) |p| {
        if (zregex.Regex.compile(testing.allocator, p)) |re| {
            re.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {}, // a defined compile error is fine; a panic is not
        }
    }
}

// 7d36074: a WTF-8 lone surrogate (here U+DC00, bytes ED B0 80) was walked
// one raw byte at a time instead of as the single code point it encodes.
test "regression: a WTF-8 lone surrogate is one code point (7d36074)" {
    const lone = "\xED\xB0\x80";
    var re = try zregex.Regex.compile(testing.allocator, "^.$");
    defer re.deinit();
    const m = (try re.find(lone)) orelse return error.TestExpectedMatch;
    defer m.deinit();
    try testing.expectEqual(@as(usize, 3), m.end);

    var two = try zregex.Regex.compile(testing.allocator, "^..$");
    defer two.deinit();
    try testing.expect((try two.find(lone)) == null);
}

// F3b: `^` with `m` looked for a LineTerminator ending at `pos` by also
// testing the byte at `pos - 3` (for the 3-byte LS/PS), which was true for a
// lone LF/CR there too: `/^x/m` matched in "\nabx". Found by the F3b
// old-vs-new comparison.
test "regression: ^ with m needs a LineTerminator right before (F3b)" {
    var re = try zregex.Regex.compileWithOptions(testing.allocator, "^x", .{ .multiline = true });
    defer re.deinit();
    try testing.expect((try re.find("\nabx")) == null);
    try testing.expect((try re.find("\r\nax")) == null);
    const m = (try re.find("ab\u{2028}x")) orelse return error.TestExpectedMatch;
    defer m.deinit();
    try testing.expectEqual(@as(usize, 5), m.start);
}

// F3b: a literal above U+007F is one code point, so it never matches an
// ill-formed byte with the same value, and a raw pattern byte (BYTE) only
// matches that byte.
test "regression: a non-ASCII literal doesn't match a lone byte of its value (F3b)" {
    var re = try zregex.Regex.compile(testing.allocator, "\\u00e9");
    defer re.deinit();
    try testing.expect((try re.find("\xE9")) == null);
    const m = (try re.find("a\u{E9}")) orelse return error.TestExpectedMatch;
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.start);
    try testing.expectEqual(@as(usize, 3), m.end);

    var raw = try zregex.Regex.compile(testing.allocator, "\xE9");
    defer raw.deinit();
    const r = (try raw.find("a\xE9")) orelse return error.TestExpectedMatch;
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.start);
    try testing.expect((try raw.find("\u{E9}")) == null);
}

// F0a: AST constructors leaked the new node when appending its child failed
// (found by checkAllAllocationFailures on analyze). Same check on the full
// compile path, over the constructors that append a child.
test "regression: compile doesn't leak on any allocation failure (F0a)" {
    const patterns = [_][]const u8{ "(a)b", "(?:ab)*c", "a{2,3}?", "a|b|c", "(?=a)b", "(?<!x)y", "(?<n>a)\\k<n>" };
    for (patterns) |p| {
        try testing.checkAllAllocationFailures(testing.allocator, struct {
            fn run(gpa: std.mem.Allocator, pattern: []const u8) !void {
                var re = try zregex.Regex.compile(gpa, pattern);
                re.deinit();
            }
        }.run, .{p});
    }
}

// D14: the recursive matcher bounded recursion depth, not stack bytes, so
// whether this pattern answered or crashed depended on the caller's stack.
// Closed in F6a (the explicit-stack backtracker). The pattern is T0, so it
// is forced onto the backtracker here.
const d14_html = "<html>\n<body onXXX=\"alert(event.type);\">\n<p>Kibology for all</p>\n<p>All for Kibology</p>\n</body>\n</html>";
const d14_pattern = "<body.*>((.*\\n?)*?)<\\/body>";

fn runD14(result: *?[2]usize) void {
    var re = zregex.Regex.compileWithOptions(std.heap.page_allocator, d14_pattern, .{ .case_insensitive = true, .force_tier = .expert }) catch return;
    defer re.deinit();
    const m = (re.find(d14_html) catch return) orelse return;
    defer m.deinit();
    result.* = .{ m.start, m.end };
}

fn d14OnStack(stack_size: usize) !?[2]usize {
    var result: ?[2]usize = null;
    const t = try std.Thread.spawn(.{ .stack_size = stack_size }, runD14, .{&result});
    t.join();
    return result;
}

test "regression: D14 pattern answers on an 8 MiB stack (test262 S15.10.2.8_A3_T17)" {
    const r = (try d14OnStack(8 << 20)) orelse return error.TestExpectedMatch;
    try testing.expectEqual(@as(usize, 7), r[0]);
    try testing.expectEqual(@as(usize, 96), r[1]);
}

test "regression: D14 pattern answers on a 1 MiB stack" {
    // Crashed until F1c (D14): the recursive matcher needed more than 1 MiB
    // here. D9's smaller MatchResult (captures out of every frame) brought
    // it to ~103 KiB in ReleaseSafe and ~615 KiB in Debug, so it answers on
    // 1 MiB in both. F6a closed D14 itself (see the 64 KiB test).
    const r = (try d14OnStack(1 << 20)) orelse return error.TestExpectedMatch;
    try testing.expectEqual(@as(usize, 7), r[0]);
    try testing.expectEqual(@as(usize, 96), r[1]);
}

test "regression: D14 pattern answers on a 64 KiB stack (F6a)" {
    // Since F6a the backtracker keeps its choicepoints on the heap: the
    // caller's stack no longer decides whether a match answers.
    const r = (try d14OnStack(64 << 10)) orelse return error.TestExpectedMatch;
    try testing.expectEqual(@as(usize, 7), r[0]);
    try testing.expectEqual(@as(usize, 96), r[1]);
}

// D15, found by the parser fuzzer (F0d, tests/fuzz_stress.zig; original
// input `\2{9007199254740991}\[*`). The recursive matcher spent a stack
// frame per instruction, so the 1000 empty backreferences crashed (Debug,
// or 1 MiB stacks) or hit its depth limit of 1000 (ReleaseSafe, 8 MiB)
// instead of giving the spec's answer. F6a's explicit stack gives it.
test "regression: a chain of empty backreferences matches empty (fuzz, D15)" {
    var re = try zregex.Regex.compile(testing.allocator, "()\\1{1000}");
    defer re.deinit();
    const m = (try re.find("")) orelse return error.TestExpectedMatch;
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.end);
    try testing.expectEqual(@as(usize, 0), m.getCaptureIndices(1).?.end);
}

test "regression: D15 on a 64 KiB stack (F6a)" {
    const Ctx = struct {
        end: ?usize = null,
        fn run(ctx: *@This()) void {
            var re = zregex.Regex.compile(std.heap.page_allocator, "()\\1{1000}") catch return;
            defer re.deinit();
            const m = (re.find("") catch return) orelse return;
            defer m.deinit();
            ctx.end = m.end;
        }
    };
    var ctx: Ctx = .{};
    const t = try std.Thread.spawn(.{ .stack_size = 64 << 10 }, Ctx.run, .{&ctx});
    t.join();
    try testing.expectEqual(@as(?usize, 0), ctx.end);
}

/// `pattern` (flags: `i` only) on `input` with the backtracker forced
/// (`force_tier = .expert`), against V8's `indices` (`null` = unset).
fn expectExpert(pattern: []const u8, ignore_case: bool, input: []const u8, expected: []const ?usize) !void {
    return expectExpertLimits(pattern, ignore_case, input, expected, .{});
}

fn expectExpertLimits(pattern: []const u8, ignore_case: bool, input: []const u8, expected: ?[]const ?usize, limits: zregex.ExecLimits) !void {
    const a = testing.allocator;
    var re = try zregex.Regex.compileWithOptions(a, pattern, .{ .case_insensitive = ignore_case, .force_tier = .expert });
    defer re.deinit();
    var scratch = zregex.Scratch.init(a);
    defer scratch.deinit();
    const slots = try a.alloc(?usize, re.slotCount());
    defer a.free(slots);
    var out: zregex.MatchSlots = .{ .slots = slots };
    const found = try re.execAt(.{ .wtf8 = input }, 0, &scratch, &out, limits);
    const want = expected orelse return testing.expect(!found);
    try testing.expect(found);
    try testing.expectEqualSlices(?usize, want, slots);
}

// Bugs of the backtracker's Phase 6 (docs/ECMASCRIPT_COMPATIBILITY_PLAN.md,
// index at the top of this file), each on the backtracker itself (F6a):
// the tests listed in the index run on T0's VM since F4a when the pattern
// is T0. Expected values are V8's.
test "regression: Phase 6 bugs on the backtracker (F6a)" {
    try expectExpert("(a*)b\\1+", false, "baaac", &.{ 0, 1, 0, 0 });
    try expectExpert("[a-z]+", true, "xABCz", &.{ 0, 5 });
    try expectExpert("[^o]", true, "Oa", &.{ 1, 2 });
    try expectExpert("(123){1,}", false, "123123", &.{ 0, 6, 3, 6 });
    try expectExpert("(a)*", false, "aaa", &.{ 0, 3, 2, 3 });
    try expectExpert("^.*?$", false, "abc", &.{ 0, 3 });
    try expectExpert("(z)((a+)?(b+)?(c))*", false, "zaacbbbcac", &.{ 0, 10, 0, 1, 8, 10, 8, 9, null, null, 9, 10 });
    try expectExpert("(a)?\\1b", false, "b", &.{ 0, 1, null, null });
    try expectExpert("(.*?)a(?!(a+)b\\2c)\\2(.*)", false, "baaabaac", &.{ 0, 8, 0, 2, null, null, 3, 8 });
    try expectExpert("[*&$]", false, "a*b", &.{ 1, 2 });
    try expectExpert("[a-c\\d]+", false, "x1a2", &.{ 1, 4 });
    try expectExpert("[^]", false, "\n", &.{ 0, 1 });
    try expectExpert("\\s\\S", false, "\x0c\x0bx", &.{ 1, 3 });
    try expectExpert("(a)?a", false, "aa", &.{ 0, 2, 0, 1 });
}

// A loop whose body isn't a single atom cost the recursive matcher a stack
// frame per instruction: past ~330 iterations it hit its depth limit (or
// crashed on a small stack). V8's answers.
test "regression: long non-simple loops on the backtracker (F6a)" {
    const a = testing.allocator;
    const xs = try std.mem.concat(a, u8, &.{ "x", "ab" ** 5000, "x" });
    defer a.free(xs);
    try expectExpert("(x)(?:ab)*\\1", false, xs, &.{ 0, 10002, 0, 1 });
    try expectExpert("(?:(a)|b)*\\1", false, "b" ** 2000, &.{ 0, 2000, null, null });
}

test "regression: the backtracker's limits are errors, not crashes (F6a)" {
    // One choicepoint (and one loop guard) per iteration of `(?:ab)*`.
    try testing.expectError(error.BacktrackStackExhausted, expectExpertLimits("(x)(?:ab)*\\1", false, "x" ++ "ab" ** 100 ++ "x", null, .{ .max_backtrack_stack_bytes = 1024 }));
    try expectExpertLimits("(x)(?:ab)*\\1", false, "x" ++ "ab" ** 100 ++ "x", &.{ 0, 202, 0, 1 }, .{ .max_backtrack_stack_bytes = 64 << 10 });
    try testing.expectError(error.StepLimitExceeded, expectExpertLimits("(a+)+b", false, "a" ** 41, null, .{}));
    try testing.expectError(error.StepLimitExceeded, expectExpertLimits("(a|aa)*c", false, "a" ** 41, null, .{}));
    // 0 lifts each limit.
    try expectExpertLimits("()\\1{1000}", false, "", &.{ 0, 0, 0, 0 }, .{ .max_backtrack_stack_bytes = 0 });
}

// Bug F (docs/F6A_PRECHECK.md): once a positive lookahead succeeded, its
// captures survived a later backtrack past it (the recursive matcher kept
// them outside any rollback). The trail undoes them (F6a). V8's indices;
// the last three pin the lookahead capture rules that don't change.
test "regression: a positive lookahead's captures are undone when backtracking past it (bug F, F6a)" {
    try expectExpert("(?:(?=(a))ab|ac)", false, "ac", &.{ 0, 2, null, null });
    try expectExpert("(?=(a))?.b|..", false, "ac", &.{ 0, 2, null, null });
    try expectExpert("(?:(?=(a+))a*x|a*)", false, "aay", &.{ 0, 2, null, null });
    try expectExpert("(?=(a+))a*b\\1", false, "baaabac", &.{ 3, 6, 3, 4 });
    try expectExpert("(?=(a))a", false, "a", &.{ 0, 1, 0, 1 });
    try expectExpert("(?!(a)b)a", false, "ac", &.{ 0, 1, null, null });
    try expectExpert("(?!(a))\\1b", false, "b", &.{ 0, 1, null, null });
}

test "regression: a pattern with a lookbehind stays on the recursive matcher until F6b" {
    var lb = try zregex.Regex.compile(testing.allocator, "(?<!\\$)\\d+");
    defer lb.deinit();
    try testing.expect(lb.compiled.has_lookbehind);
    var la = try zregex.Regex.compile(testing.allocator, "(?!\\$)\\d+");
    defer la.deinit();
    try testing.expect(!la.compiled.has_lookbehind);
}

// Found by the F1c long fuzz run (reduced from
// `(?<n>A\u{1F600}{9007199254740991}){9007199254740991}`): nested
// counted repeats are unrolled, so the counts multiply (here 2^32 copies);
// the codegen built bytecode past 2 GiB and panicked on an i32 jump offset.
// It is now error.PatternTooLarge past MAX_PROGRAM_BYTES. Reachable only
// since F1b, when `\10{` stopped rejecting the pattern that contained it.
test "regression: nested counted repeats past the program cap are PatternTooLarge, not a panic (F1c fuzz)" {
    for ([_][]const u8{ "(?:a{65536}){65536}", "(?:(?:a{1000}){1000}){1000}", "(\\u{1F600}{70000}){70000}" }) |p| {
        try testing.expectError(error.PatternTooLarge, zregex.Regex.compile(testing.allocator, p));
    }
    // Large but reasonable unrolling still compiles.
    var re = try zregex.Regex.compile(testing.allocator, "(?:a{100}){100}");
    re.deinit();
}

test "PatternTooLarge is exactly MAX_PROGRAM_BYTES (16 MiB) of bytecode" {
    const max = zregex.MAX_PROGRAM_BYTES;
    try testing.expectEqual(@as(usize, 16 << 20), max);
    // `a{65536}` is 327680 bytes of copies (5 per `a`) plus MATCH: 51 copies
    // fit the cap, 52 don't.
    const at_cap = try zregex.compile(testing.allocator, "(?:a{65536}){51}", .{});
    defer at_cap.deinit();
    try testing.expect(at_cap.bytecode.len <= max);
    try testing.expect(at_cap.bytecode.len > max - 327680);
    try testing.expectError(error.PatternTooLarge, zregex.compile(testing.allocator, "(?:a{65536}){52}", .{}));
}

// F3c: a lone surrogate written in WTF-8 inside the pattern (bytes ED A0 80),
// and `\` before a non-ASCII character, were split into raw bytes (BYTE),
// which only a WTF-8 subject can match and which a quantifier binds to the
// last byte of. Found by the fuzz's WTF-8 vs UTF-16 comparison.
test "regression: a WTF-8 surrogate or an escaped non-ASCII character in the pattern is one character (F3c)" {
    const a = testing.allocator;
    var lone = try zregex.Regex.compile(a, "^\xED\xA0\x80+$");
    defer lone.deinit();
    const m = (try lone.find("\xED\xA0\x80\xED\xA0\x80")) orelse return error.TestExpectedMatch;
    m.deinit();
    var scratch = zregex.Scratch.init(a);
    defer scratch.deinit();
    var buf: [2]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = &buf };
    const units = [_]u16{ 0xD800, 0xD800 };
    try testing.expect(try lone.execAt(.{ .utf16 = &units }, 0, &scratch, &out, .{}));
    try testing.expectEqualSlices(?usize, &.{ 0, 2 }, &buf);

    var esc = try zregex.Regex.compile(a, "^\\\u{E9}+$");
    defer esc.deinit();
    const e = (try esc.find("\u{E9}\u{E9}")) orelse return error.TestExpectedMatch;
    e.deinit();
}

/// One `execAt` of `pattern` on the backtracker (`force_tier = .expert`),
/// with LookLinear on or off: the slots, how many delegated sites the
/// pattern has and how often the VM and the memo answered.
const LookRun = struct { found: bool, slots: [4]?usize, sites: usize, evals: u64, memo_hits: u64 };

fn lookRun(pattern: []const u8, input: []const u8, look_linear: bool, limits: zregex.ExecLimits) !LookRun {
    const a = testing.allocator;
    var re = try zregex.Regex.compileWithOptions(a, pattern, .{ .force_tier = .expert, .t2_look_linear = look_linear });
    defer re.deinit();
    var scratch = zregex.Scratch.init(a);
    defer scratch.deinit();
    var r: LookRun = .{ .found = false, .slots = @splat(null), .sites = re.compiled.linear.len, .evals = 0, .memo_hits = 0 };
    var out: zregex.MatchSlots = .{ .slots = r.slots[0..re.slotCount()] };
    r.found = try re.execAt(.{ .wtf8 = input }, 0, &scratch, &out, limits);
    r.evals = scratch.bt.look_evals;
    r.memo_hits = scratch.bt.look_memo_hits;
    return r;
}

// LookLinear (F6a, docs/REGEX_TIERS_PLAN.md §4.4 D-B): the switch, both
// ways. On, the lookahead is a delegated site and T0's VM answers it; off,
// there is no site and the VM never runs. Same answer (V8's) either way.
test "LookLinear: t2_look_linear on delegates the lookahead to T0's VM" {
    const r = try lookRun("(?=\\d{3})\\d+", "ab12x12345", true, .{});
    try testing.expect(r.found);
    try testing.expectEqual(@as(usize, 1), r.sites);
    try testing.expect(r.evals > 0);
    try testing.expectEqualSlices(?usize, &.{ 5, 10 }, r.slots[0..2]);
}

test "LookLinear: t2_look_linear off leaves the lookahead to the backtracker" {
    const r = try lookRun("(?=\\d{3})\\d+", "ab12x12345", false, .{});
    try testing.expect(r.found);
    try testing.expectEqual(@as(usize, 0), r.sites);
    try testing.expectEqual(@as(u64, 0), r.evals);
    try testing.expectEqualSlices(?usize, &.{ 5, 10 }, r.slots[0..2]);
}

test "LookLinear: which lookaheads are delegated" {
    const Case = struct { pattern: []const u8, input: []const u8, sites: usize, want: ?[2]usize };
    const cases = [_]Case{
        .{ .pattern = "(?=foo)\\w+", .input = "a foobar", .sites = 1, .want = .{ 2, 8 } },
        .{ .pattern = "(?!\\$)\\d+", .input = "$12 34", .sites = 1, .want = .{ 1, 3 } },
        // A capture, a backreference or a nested lookaround in the body:
        // the backtracker (only the inner, capture-free lookahead goes).
        .{ .pattern = "(?=(a))a", .input = "ba", .sites = 0, .want = .{ 1, 2 } },
        .{ .pattern = "(a)(?=\\1)a", .input = "aa", .sites = 0, .want = .{ 0, 2 } },
        .{ .pattern = "(?=(?=a)a)a", .input = "ba", .sites = 1, .want = .{ 1, 2 } },
        // Lookbehind: the recursive matcher until F6b, no site.
        .{ .pattern = "(?<!\\$)\\d+", .input = "$12 34", .sites = 0, .want = .{ 2, 3 } },
    };
    for (cases) |c| {
        const on = try lookRun(c.pattern, c.input, true, .{});
        const off = try lookRun(c.pattern, c.input, false, .{});
        try testing.expectEqual(c.sites, on.sites);
        try testing.expectEqual(on.found, off.found);
        try testing.expectEqualSlices(?usize, &on.slots, &off.slots);
        const want = c.want orelse {
            try testing.expect(!on.found);
            continue;
        };
        try testing.expect(on.found);
        try testing.expectEqualSlices(?usize, &.{ want[0], want[1] }, on.slots[0..2]);
    }
}

test "LookLinear: the memo answers repeated positions, and off gives the same" {
    // Every start position re-walks the `a`s, asking the lookahead at the
    // same positions again (V8: no match; with the `c`, [2, 6]).
    for ([_][]const u8{ "aaaaaaaab", "abaaac" }) |input| {
        const memo = try lookRun("(?:(?=a)[ab])*c", input, true, .{});
        const no_memo = try lookRun("(?:(?=a)[ab])*c", input, true, .{ .max_memo_bytes = 0 });
        try testing.expect(memo.memo_hits > 0);
        try testing.expectEqual(@as(u64, 0), no_memo.memo_hits);
        try testing.expect(no_memo.evals > memo.evals);
        try testing.expectEqual(memo.found, no_memo.found);
        try testing.expectEqualSlices(?usize, &memo.slots, &no_memo.slots);
    }
    const hit = try lookRun("(?:(?=a)[ab])*c", "abaaac", true, .{});
    try testing.expectEqualSlices(?usize, &.{ 2, 6 }, hit.slots[0..2]);
}

test "LookLinear: the step budget covers the VM too" {
    const long = "a" ** 2000;
    try testing.expectError(error.StepLimitExceeded, lookRun("(?=a+b)", long, true, .{ .max_steps = 500 }));
    try testing.expectError(error.StepLimitExceeded, lookRun("(?=a+b)", long, false, .{ .max_steps = 500 }));
    const r = try lookRun("(?=a+b)", long, true, .{});
    try testing.expect(!r.found);
}

// F5b(1b): backreferences under `i` compare with ECMA-262's Canonicalize
// (unicode.casefold, the tables the lowering folds with), not ASCII
// folding; `\b`/`\B` count the extended WordCharacters under `u` + `i`
// (ir.word), in all three executors. Every expected value is V8's.

/// Whether `pattern` with `flags` (`i`, `u`) finds a match in `input`
/// (UTF-16, so astral characters are whole under `u`).
fn v8Test(pattern: []const u8, flags: []const u8, input: []const u8) !bool {
    const a = testing.allocator;
    var re = try zregex.Regex.compileWithOptions(a, pattern, .{
        .case_insensitive = std.mem.indexOfScalar(u8, flags, 'i') != null,
        .unicode = std.mem.indexOfScalar(u8, flags, 'u') != null,
        .v = std.mem.indexOfScalar(u8, flags, 'v') != null,
    });
    defer re.deinit();
    var scratch = zregex.Scratch.init(a);
    defer scratch.deinit();
    const slots = try a.alloc(?usize, re.slotCount());
    defer a.free(slots);
    var out: zregex.MatchSlots = .{ .slots = slots };
    const s16 = try zregex.subject.utf16FromWtf8(a, input);
    defer a.free(s16);
    const found16 = try re.execAt(.{ .utf16 = s16 }, 0, &scratch, &out, .{});
    // The same answer over WTF-8.
    const found8 = try re.execAt(.{ .wtf8 = input }, 0, &scratch, &out, .{});
    if (found16 != found8) {
        std.debug.print("/{s}/{s} on \"{s}\": UTF-16 {}, WTF-8 {}\n", .{ pattern, flags, input, found16, found8 });
        return error.TestUnexpectedResult;
    }
    return found16;
}

test "F7a: \\u{...} is a code point escape only with u or v (bug E, V8)" {
    const Case = struct { []const u8, []const u8, []const u8, bool };
    // Values checked with Node 22 (V8). Without `u`/`v`, Annex B reads `\u`
    // as the letter and `{...}` as a quantifier when it forms one, text
    // otherwise; inside a class the braces and digits are members.
    const cases = [_]Case{
        .{ "\\u{1F600}", "", "u{1F600}", true },
        .{ "\\u{1F600}", "", "\u{1F600}", false },
        .{ "^\\u{2}$", "", "uu", true },
        .{ "^\\u{2}$", "", "\u{2}", false },
        .{ "^\\u{2,3}$", "", "uuu", true },
        .{ "^\\u{41}$", "", "u{41}", false },
        .{ "^[\\u{1F600}]$", "", "u", true },
        .{ "^[\\u{1F600}]$", "", "{", true },
        .{ "^[\\u{1F600}]$", "", "F", true },
        .{ "^[\\u{1F600}]$", "", "}", true },
        .{ "^[\\u{1F600}]$", "", "\u{1F600}", false },
        .{ "\\u{1F600}", "u", "\u{1F600}", true },
        .{ "\\u{1F600}", "v", "\u{1F600}", true },
        .{ "^[\\u{1F600}]$", "u", "\u{1F600}", true },
    };
    for (cases) |c| {
        const got = try v8Test(c[0], c[1], c[2]);
        if (got != c[3]) {
            std.debug.print("/{s}/{s} on \"{s}\": got {}, V8 {}\n", .{ c[0], c[1], c[2], got, c[3] });
            return error.TestUnexpectedResult;
        }
    }
}

test "F5b: backreferences under i canonicalize (V8)" {
    const Case = struct { []const u8, []const u8, []const u8, bool };
    const cases = [_]Case{
        .{ "(\u{E9})\\1", "i", "\u{E9}\u{C9}", true },
        .{ "(k)\\1", "iu", "k\u{212A}", true },
        .{ "^(\u{DF})\\1$", "i", "\u{DF}\u{DF}", true },
        .{ "^(\u{DF})\\1$", "i", "\u{DF}SS", false },
        .{ "^(\u{FB01})\\1$", "i", "\u{FB01}\u{FB01}", true },
        .{ "^(\u{FB01})\\1$", "i", "\u{FB01}FI", false },
        // Without `u`, the Kelvin sign doesn't fold; σ/ς/Σ is one class;
        // ᾀ's full uppercase is two characters, so it only matches itself.
        .{ "(k)\\1", "i", "k\u{212A}", false },
        .{ "(\u{3C3})\\1", "i", "\u{3C3}\u{3C2}", true },
        .{ "(\u{1F80})\\1", "i", "\u{1F80}\u{1F88}", false },
        .{ "(\u{1F80})\\1", "iu", "\u{1F80}\u{1F88}", true },
        // An astral character canonicalizes whole under `u` only.
        .{ "(\u{10400})\\1", "iu", "\u{10400}\u{10428}", true },
        .{ "(\u{10400})\\1", "i", "\u{10400}\u{10428}", false },
        // Without `i`, no folding.
        .{ "(\u{E9})\\1", "", "\u{E9}\u{C9}", false },
    };
    for (cases) |c| {
        const got = try v8Test(c[0], c[1], c[2]);
        if (got != c[3]) {
            std.debug.print("/{s}/{s} on \"{s}\": got {}, V8 {}\n", .{ c[0], c[1], c[2], got, c[3] });
            return error.TestUnexpectedResult;
        }
    }
}

test "F5b: \\b and \\B count the extended WordCharacters under u + i (V8)" {
    const Case = struct { []const u8, []const u8, []const u8, bool };
    const cases = [_]Case{
        .{ "a\\b", "iu", "a\u{17F}", false },
        .{ "a\\b", "iu", "a\u{212A}", false },
        .{ "^\u{17F}\\B", "iu", "\u{17F}a", true },
        .{ "\u{17F}\\b", "iu", "\u{17F}!", true },
        .{ "\u{17F}\\b", "iu", "\u{17F}a", false },
        // Anchored at the `s`/`k`: the next character (ſ, K) is a word
        // character. (Unanchored, V8 matches `s`/`k` on that second
        // character, which needs the literals folded: F5b's Part 2.)
        .{ "^s\\b", "iu", "s\u{17F}", false },
        .{ "^k\\b", "iu", "k\u{212A}", false },
        // Without `i`, or without `u`, no extension.
        .{ "a\\b", "u", "a\u{17F}", true },
        .{ "a\\b", "i", "a\u{17F}", true },
        .{ "^s\\b", "u", "s\u{17F}", true },
        .{ "^s\\b", "i", "s\u{17F}", true },
    };
    for (cases) |c| {
        const got = try v8Test(c[0], c[1], c[2]);
        if (got != c[3]) {
            std.debug.print("/{s}/{s} on \"{s}\": got {}, V8 {}\n", .{ c[0], c[1], c[2], got, c[3] });
            return error.TestUnexpectedResult;
        }
    }
}

/// `pattern` (flags `i`, `u`) on `input` from index 0: the match's [start,
/// end] in UTF-16 units, or null.
fn spanOf(pattern: []const u8, input: []const u8, unicode: bool) !?[2]usize {
    const a = testing.allocator;
    var re = try zregex.Regex.compileWithOptions(a, pattern, .{ .case_insensitive = true, .unicode = unicode });
    defer re.deinit();
    var scratch = zregex.Scratch.init(a);
    defer scratch.deinit();
    const slots = try a.alloc(?usize, re.slotCount());
    defer a.free(slots);
    var out: zregex.MatchSlots = .{ .slots = slots };
    const s16 = try zregex.subject.utf16FromWtf8(a, input);
    defer a.free(s16);
    if (!try re.execAt(.{ .utf16 = s16 }, 0, &scratch, &out, .{})) return null;
    return .{ slots[0].?, slots[1].? };
}

// Backreferences never run on T0 (tier0.check rejects them), so there is
// no T0/T2 cross for them. The two backtrackers share checkBackRef: a
// pattern with a lookbehind runs on the recursive matcher, one without on
// the explicit-stack one; the same backreference gives the same span on
// both (and V8's).
test "F5b: backreferences under i agree on both backtrackers" {
    try testing.expectEqual(@as(?[2]usize, .{ 1, 3 }), try spanOf("(?<=x)(\u{E9})\\1", "x\u{E9}\u{C9}", false));
    try testing.expectEqual(@as(?[2]usize, .{ 1, 3 }), try spanOf("(\u{E9})\\1", "x\u{E9}\u{C9}", false));
    try testing.expectEqual(@as(?[2]usize, .{ 1, 3 }), try spanOf("(?<=x)(k)\\1", "xk\u{212A}", true));
    try testing.expectEqual(@as(?[2]usize, .{ 1, 3 }), try spanOf("(k)\\1", "xk\u{212A}", true));
}

// F5b(2): literals, ranges, classes, \w/\W and properties fold at compile
// time under `i`; each case with and without `u`, V8's answers (F5b's
// pre-check table), on whatever executor the dispatcher picks.
test "F5b: literals, classes and properties fold under i (V8)" {
    const Case = struct { pattern: []const u8, subject: []const u8, i: bool, iu: bool };
    const cases = [_]Case{
        .{ .pattern = "k", .subject = "\u{212A}", .i = false, .iu = true },
        .{ .pattern = "\u{212A}", .subject = "k", .i = false, .iu = true },
        .{ .pattern = "s", .subject = "\u{17F}", .i = false, .iu = true },
        .{ .pattern = "\u{DF}", .subject = "\u{1E9E}", .i = false, .iu = true },
        .{ .pattern = "\u{1E9E}", .subject = "\u{DF}", .i = false, .iu = true },
        .{ .pattern = "\u{DF}", .subject = "ss", .i = false, .iu = false },
        .{ .pattern = "\u{FB00}", .subject = "ff", .i = false, .iu = false },
        .{ .pattern = "\u{FB01}", .subject = "FI", .i = false, .iu = false },
        .{ .pattern = "\u{FB05}", .subject = "\u{FB06}", .i = false, .iu = true },
        .{ .pattern = "\u{3C3}", .subject = "\u{3C2}", .i = true, .iu = true },
        .{ .pattern = "\u{3C2}", .subject = "\u{3A3}", .i = true, .iu = true },
        .{ .pattern = "\u{390}", .subject = "\u{1FD3}", .i = false, .iu = true },
        .{ .pattern = "\u{1F80}", .subject = "\u{1F88}", .i = false, .iu = true },
        .{ .pattern = "\u{E9}", .subject = "\u{C9}", .i = true, .iu = true },
        .{ .pattern = "\u{345}", .subject = "\u{1FBE}", .i = true, .iu = true },
        .{ .pattern = "\u{130}", .subject = "i", .i = false, .iu = false },
        .{ .pattern = "\u{131}", .subject = "I", .i = false, .iu = false },
        .{ .pattern = "\\u{10400}", .subject = "\u{10428}", .i = false, .iu = true },
        .{ .pattern = "\\w", .subject = "\u{17F}", .i = false, .iu = true },
        .{ .pattern = "\\w", .subject = "\u{212A}", .i = false, .iu = true },
        .{ .pattern = "\\W", .subject = "\u{17F}", .i = true, .iu = false },
        .{ .pattern = "\\W", .subject = "\u{212A}", .i = true, .iu = false },
        .{ .pattern = "[\\W]", .subject = "\u{17F}", .i = true, .iu = false },
        .{ .pattern = "[\\W]", .subject = "s", .i = false, .iu = false },
        .{ .pattern = "[^\\w]", .subject = "\u{17F}", .i = true, .iu = false },
        .{ .pattern = "\\W", .subject = "S", .i = false, .iu = false },
        .{ .pattern = "[a-z]", .subject = "\u{212A}", .i = false, .iu = true },
        .{ .pattern = "[\u{C0}-\u{D6}]", .subject = "\u{E0}", .i = true, .iu = true },
        .{ .pattern = "[\u{C0}-\u{D6}]", .subject = "\u{212B}", .i = false, .iu = true },
        .{ .pattern = "[^k]", .subject = "\u{212A}", .i = true, .iu = false },
        // `\b` on the second character, which `s`/`k` now match.
        .{ .pattern = "s\\b", .subject = "s\u{17F}", .i = true, .iu = true },
        .{ .pattern = "k\\b", .subject = "k\u{212A}", .i = true, .iu = true },
    };
    for (cases) |c| {
        for ([_]struct { []const u8, bool }{ .{ "i", c.i }, .{ "iu", c.iu } }) |mode| {
            const got = try v8Test(c.pattern, mode[0], c.subject);
            if (got != mode[1]) {
                std.debug.print("/{s}/{s} on \"{s}\": got {}, V8 {}\n", .{ c.pattern, mode[0], c.subject, got, mode[1] });
                return error.TestUnexpectedResult;
            }
        }
    }
    // Properties (only with `u`: without it `\p` is the letter p).
    const props = [_]struct { []const u8, []const u8, bool }{
        .{ "\\p{Lu}", "a", true },
        .{ "\\P{Lu}", "A", true },
        .{ "[\\p{Lu}]", "a", true },
        .{ "[^\\p{Lu}]", "a", false },
        .{ "\\p{Script=Greek}", "\u{3C3}", true },
        .{ "\\p{ASCII}", "\u{212A}", true },
        .{ "\\p{Nd}", "a", false },
    };
    for (props) |c| {
        const got = try v8Test(c[0], "iu", c[1]);
        if (got != c[2]) {
            std.debug.print("/{s}/iu on \"{s}\": got {}, V8 {}\n", .{ c[0], c[1], got, c[2] });
            return error.TestUnexpectedResult;
        }
    }
}
