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

// --- \xHH above 0x7F (S15.10.2.10_A3.1_T1) ---

test "\\xHH is the code point U+00HH, also above 0x7F" {
    for ([_]zregex.CompileOptions{ annex_b, u }) |opts| {
        try expectMatch("\\xFF", opts, "\xC3\xBF", "\xC3\xBF"); // ÿ
        try expectMatch("\\xe9", opts, "caf\xC3\xA9", "\xC3\xA9"); // é
        try expectMatch("[\\xE0-\\xFF]+", opts, "caf\xC3\xA9\xC3\xBF", "\xC3\xA9\xC3\xBF");
        try expectMatch("\\x41", opts, "A", "A");
        // Same thing as the \u spelling.
        try expectMatch("\\xFF", opts, "\xC3\xBF", "\xC3\xBF");
        try expectMatch("\\u00FF", opts, "\xC3\xBF", "\xC3\xBF");
    }
    // The raw byte 0xFF (invalid UTF-8) is not U+00FF.
    try expectMatch("\\xFF", annex_b, "\xFF", null);
    try expectMatch("\\xe9", .{ .case_insensitive = true }, "\xC3\x89", "\xC3\x89"); // É
}

// --- D13: escaped surrogates ---

test "u: an escaped surrogate pair is one code point, in a class too" {
    const astral = "\xF0\x9D\x8C\x86"; // U+1D306
    try expectMatch("^\\ud834\\udf06$", u, astral, astral);
    try expectMatch("^[\\ud834\\udf06]$", u, astral, astral);
    try expectMatch("^\\u{1d306}$", u, astral, astral);
    // A class holding the pair doesn't match either half on its own.
    try expectMatch("[\\ud800\\udc00]", u, "\xED\xA0\x80", null); // lone U+D800
    try expectMatch("[\\ud800\\udc00]", u, "\xED\xB0\x80", null); // lone U+DC00
    // Two leads, or a lead and a non-surrogate, don't combine.
    try expectMatch("^\\ud834\\ud834$", u, "\xED\xA0\xB4\xED\xA0\xB4", "\xED\xA0\xB4\xED\xA0\xB4");
}

test "an escaped lone surrogate is its WTF-8 sequence, not a literal 'u'" {
    for ([_]zregex.CompileOptions{ annex_b, u }) |opts| {
        try expectMatch("\\ud800", opts, "a\xED\xA0\x80", "\xED\xA0\x80");
        try expectMatch("[\\udc00-\\udfff]", opts, "\xED\xB0\x80", "\xED\xB0\x80");
        try expectMatch("\\ud800", opts, "ud800", null);
    }
    // Without `u` the pair is two code units (not combined, D6).
    try expectMatch("\\ud834\\udf06", annex_b, "\xF0\x9D\x8C\x86", null);
}

// --- D12 (start positions): a search never starts inside a character ---

test "find never starts a match in the middle of a UTF-8 sequence" {
    for ([_]zregex.CompileOptions{ annex_b, u }) |opts| {
        // Before: the scan tried byte 1 of 💚 and `[^💚]` matched its tail.
        try expectMatch("[^\xF0\x9F\x92\x9A]", opts, "\xF0\x9F\x92\x9A", null);
        var re = try zregex.Regex.compileWithOptions(testing.allocator, "x", opts);
        defer re.deinit();
        const m = (try re.find("\xF0\x9F\x92\x9Ax")).?;
        defer m.deinit();
        try testing.expectEqual(@as(usize, 4), m.start);
    }
    // (.+).*\1 on "\u{10000}\ud800": \1 can't match a fragment of U+10000.
    try expectMatch("(.+).*\\1", u, "\xF0\x90\x80\x80\xED\xA0\x80", null);
}

test "findAll steps over whole characters after an empty match" {
    var re = try zregex.Regex.compile(testing.allocator, "");
    defer re.deinit();
    var all = try re.findAll("\xC3\xA9\xE2\x82\xAC"); // é€
    defer {
        for (all.items) |m| m.deinit();
        all.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 2), all.items.len);
    try testing.expectEqual(@as(usize, 0), all.items[0].start);
    try testing.expectEqual(@as(usize, 2), all.items[1].start);
}

// --- D4: \s is WhiteSpace + LineTerminator, with or without u ---

const js_whitespace = [_][]const u8{
    "\t", "\n", "\x0B", "\x0C", "\r", " ", "\xC2\xA0", // TAB..CR, SPACE, NBSP
    "\xE1\x9A\x80", // U+1680
    "\xE2\x80\x80", "\xE2\x80\x8A", // U+2000, U+200A
    "\xE2\x80\xA8", "\xE2\x80\xA9", // LS, PS
    "\xE2\x80\xAF", "\xE2\x81\x9F", // U+202F, U+205F
    "\xE3\x80\x80", "\xEF\xBB\xBF", // U+3000, ZWNBSP
};
const not_whitespace = [_][]const u8{ "a", "0", "_", "\xC3\xA9", "\xE2\x82\xAC", "\xE2\x80\x8B", "\xC2\x85", "\xF0\x9F\x92\x9A" }; // é € ZWSP NEL 💚

test "\\s and \\S follow ECMA-262 WhiteSpace + LineTerminator, standalone and in a class" {
    for ([_]zregex.CompileOptions{ annex_b, u }) |opts| {
        for (js_whitespace) |ws| {
            try expectMatch("^\\s$", opts, ws, ws);
            try expectMatch("^[\\s]$", opts, ws, ws);
            try expectMatch("^\\S$", opts, ws, null);
            try expectMatch("^[\\S]$", opts, ws, null);
            try expectMatch("^[^\\s]$", opts, ws, null);
        }
        for (not_whitespace) |c| {
            try expectMatch("^\\s$", opts, c, null);
            try expectMatch("^[\\s]$", opts, c, null);
            try expectMatch("^\\S$", opts, c, c);
            try expectMatch("^[\\S]$", opts, c, c);
            try expectMatch("^[^\\s]$", opts, c, c);
        }
    }
}

test "negated shorthands in a class cover every code point, not just 0-255" {
    for ([_]zregex.CompileOptions{ annex_b, u }) |opts| {
        // Before F1a these missed everything above U+00FF.
        for ([_][]const u8{ "\xE2\x82\xAC", "\xF0\x9F\x92\x9A", "\xEF\xBB\xBF" }) |c| {
            try expectMatch("^[\\D]$", opts, c, c);
            try expectMatch("^[\\W]$", opts, c, c);
        }
        try expectMatch("^[\\s\\S]+$", opts, "a \xE2\x82\xAC\n", "a \xE2\x82\xAC\n");
        try expectMatch("^[\\s\\d\\w-]+$", opts, "a-1\xC2\xA0", "a-1\xC2\xA0");
    }
}
