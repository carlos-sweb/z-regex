//! Historical bugs as permanent regression tests (docs/REGEX_TIERS_PLAN.md,
//! F0d; §8.2 "bugs históricos → tests permanentes"). These are the bugs a
//! parser/matcher rewrite (F1 onward) is most likely to reintroduce.
//!
//! Bugs that already had a dedicated test are *not* duplicated here; this
//! index points at them so the full list lives in one place:
//!
//! | Bug (origin)                                                        | Existing test |
//! |---------------------------------------------------------------------|---------------|
//! | `/(a*)b\1+/` on "baaac" segfaulted (Phase 6)                        | src/executor/recursive_matcher.zig: "RecursiveMatcher: quantified backreference to an empty capture doesn't crash" |
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

// D14: the recursive matcher bounds recursion depth, not stack bytes, so
// whether this pattern answers or crashes depends on the caller's stack.
const d14_html = "<html>\n<body onXXX=\"alert(event.type);\">\n<p>Kibology for all</p>\n<p>All for Kibology</p>\n</body>\n</html>";
const d14_pattern = "<body.*>((.*\\n?)*?)<\\/body>";

fn runD14(result: *?[2]usize) void {
    var re = zregex.Regex.compileWithOptions(std.heap.page_allocator, d14_pattern, .{ .case_insensitive = true }) catch return;
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
    // 1 MiB in both. D14 itself stays open until F6a: the matcher still
    // bounds recursion depth, not stack bytes.
    const r = (try d14OnStack(1 << 20)) orelse return error.TestExpectedMatch;
    try testing.expectEqual(@as(usize, 7), r[0]);
    try testing.expectEqual(@as(usize, 96), r[1]);
}

// D15, found by the parser fuzzer (F0d, tests/fuzz_stress.zig; original
// input `\2{9007199254740991}\[*`). Each level of the matchFrom ->
// matchBackRef chain cost ~25 KiB of stack in ReleaseSafe (~75 KiB in
// Debug) until F1c, so the recursion limit (1000) needed ~25 MiB to fire.
// Since D9 (F1c) a level costs ~1.8 KiB (~11 KiB in Debug): on 8 MiB,
// ReleaseSafe now reaches the limit and returns RecursionLimitExceeded
// instead of crashing, but Debug still overflows, and neither gives the
// spec answer. F6a fixes it (explicit heap stack with a byte limit); when
// F6a closes, remove this skip and the test has to pass (the spec answer is
// an empty match).
test "regression: a chain of empty backreferences doesn't overflow the stack (fuzz, D15)" {
    if (true) return error.SkipZigTest;
    var re = try zregex.Regex.compile(testing.allocator, "()\\1{1000}");
    defer re.deinit();
    const m = (try re.find("")) orelse return error.TestExpectedMatch;
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.end);
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
