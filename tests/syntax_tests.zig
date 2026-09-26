//! Pattern grammar rules closed in F1 (docs/REGEX_TIERS_PLAN.md). test262
//! measures a rejection only through a parse-negative test with an
//! extractable literal (V8 rejects a bad `new RegExp(...)` before zregex
//! sees it), so every rule gets its own test here, with the Annex B
//! (non-`u`) reading next to the `u` one.

const std = @import("std");
const zregex = @import("zregex");
const testing = std.testing;

const u: zregex.CompileOptions = .{ .unicode = true };
const annex_b: zregex.CompileOptions = .{};

fn expectRejected(pattern: []const u8, options: zregex.CompileOptions) !void {
    if (zregex.Regex.compileWithOptions(testing.allocator, pattern, options)) |re| {
        re.deinit();
        std.debug.print("\n/{s}/ (unicode={}) compiled; expected a SyntaxError\n", .{ pattern, options.unicode });
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    }
}

fn expectAccepted(pattern: []const u8, options: zregex.CompileOptions) !void {
    const re = zregex.Regex.compileWithOptions(testing.allocator, pattern, options) catch |err| {
        std.debug.print("\n/{s}/ (unicode={}) failed: {s}\n", .{ pattern, options.unicode, @errorName(err) });
        return err;
    };
    re.deinit();
}

fn expectMatch(pattern: []const u8, options: zregex.CompileOptions, input: []const u8, expected: ?[]const u8) !void {
    var re = try zregex.Regex.compileWithOptions(testing.allocator, pattern, options);
    defer re.deinit();
    const m = try re.find(input);
    defer if (m) |x| x.deinit();
    if (expected) |e| {
        const got = m orelse return error.TestExpectedMatch;
        try testing.expectEqualStrings(e, got.group(input));
    } else {
        try testing.expect(m == null);
    }
}

// --- \p{...} (property-escapes/grammar-extension-*) ---

test "u: a malformed property escape is a SyntaxError; Annex B reads it literally" {
    for ([_][]const u8{ "\\p", "\\P", "\\pL", "\\PL", "\\p}", "\\P}", "[\\p{}]", "[\\P{}]", "\\p{" }) |p| {
        try expectRejected(p, u);
    }
    try expectMatch("\\pL", annex_b, "pL", "pL");
    try expectMatch("[\\p{}]", annex_b, "}", "}");
    try expectAccepted("\\p{L}", u);
}

// --- quantified assertions ---

test "a lookbehind is never quantifiable" {
    for ([_][]const u8{ ".(?<=.)?", ".(?<!.)?", ".(?<=.){2,3}", ".(?<!.)*" }) |p| {
        try expectRejected(p, annex_b);
        try expectRejected(p, u);
    }
}

test "u: a lookahead isn't quantifiable; Annex B allows it" {
    for ([_][]const u8{ ".(?=.)?", ".(?!.)?", ".(?=.){2,3}", "(?=a)*" }) |p| {
        try expectRejected(p, u);
        try expectAccepted(p, annex_b);
    }
    try expectMatch("a(?=b)?", annex_b, "ac", "a");
}

// --- \k (named-groups/invalid-incomplete-groupname*) ---

test "with named groups ([N]) \\k must be a complete \\k<name>" {
    for ([_][]const u8{ "(?<a>.)\\k", "(?<a>.)\\k<a", "(?<a>.)\\k<>", "\\k<a(?<a>a)", "\\k(?<a>.)" }) |p| {
        try expectRejected(p, annex_b);
        try expectRejected(p, u);
    }
    try expectMatch("(?<a>x)\\k<a>", annex_b, "xx", "xx");
}

test "u: \\k is a SyntaxError even without named groups" {
    for ([_][]const u8{ "\\k", "\\k<a", "\\k<>" }) |p| try expectRejected(p, u);
}

test "Annex B: without named groups \\k is an identity escape" {
    try expectMatch("\\k", annex_b, "k", "k");
    try expectMatch("\\k<a", annex_b, "k<a", "k<a");
}

// --- decimal escapes ---

test "u: \\N past the last capturing group is a SyntaxError" {
    try expectRejected("\\1", u);
    try expectRejected("\\8", u);
    try expectRejected("(a)\\2", u);
    try expectAccepted("(a)\\1", u);
    // Counted over the whole pattern, not only the groups seen so far.
    try expectAccepted("\\1(a)", u);
}

// --- \c, \x, \u under u ---

test "u: malformed \\c, \\x and \\u escapes are SyntaxErrors" {
    for ([_][]const u8{ "\\c0", "[\\c0]", "\\c", "\\x4", "\\xg1", "\\u12", "\\u{1,}", "\\u{}", "\\u{110000}", "[\\u{110000}]" }) |p| {
        try expectRejected(p, u);
    }
    try expectAccepted("\\u{10FFFF}", u);
    try expectAccepted("\\u{0000000041}", u);
    try expectMatch("\\c0", annex_b, "\\c0", "c0");
    try expectMatch("\\x4", annex_b, "x4", "x4");
}

// --- class ranges with class escapes ---

test "u: a class escape can't be a range endpoint; Annex B makes the hyphen literal" {
    for ([_][]const u8{ "[\\d-a]", "[\\s-\\d]", "[%-\\d]", "[--\\d]", "[\\p{L}-z]" }) |p| {
        try expectRejected(p, u);
        try expectAccepted(p, annex_b);
    }
    try expectMatch("[\\d-a]+", annex_b, "x1-a", "1-a");
    try expectMatch("[%-\\d]+", annex_b, "x%-5", "%-5");
    // A hyphen before `]` stays literal in both modes.
    try expectMatch("[\\d-]+", u, "x1-", "1-");
}

test "a leading hyphen can start a range: [--0] is '-'..'0'" {
    for ([_]zregex.CompileOptions{ annex_b, u }) |opts| {
        try expectMatch("[--0]+", opts, "x-./0", "-./0");
        try expectMatch("[-a]+", opts, "x-a", "-a");
        try expectMatch("[--]+", opts, "x--", "--");
    }
    try expectRejected("[--!]", annex_b); // '-' (0x2D) > '!' (0x21)
}

test "the F1 syntax paths don't leak on any allocation failure" {
    const cases = [_]struct { []const u8, zregex.CompileOptions }{
        .{ "[\\p{L}-z]", u }, // rejected after the class owns a property node
        .{ "[a\\d-b]", u },
        .{ "[--0x]", annex_b },
        .{ "[a-]", annex_b }, // pre-F1 double free: `a` freed twice when `-` failed
        .{ "[%-\\d]", annex_b },
        .{ "(?<a>.)\\k<a", annex_b },
        .{ "a(?=b)*", u },
    };
    for (cases) |c| {
        try testing.checkAllAllocationFailures(testing.allocator, struct {
            fn run(gpa: std.mem.Allocator, pattern: []const u8, options: zregex.CompileOptions) !void {
                if (zregex.Regex.compileWithOptions(gpa, pattern, options)) |re| {
                    re.deinit();
                } else |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {},
                }
            }
        }.run, .{ c[0], c[1] });
    }
}
