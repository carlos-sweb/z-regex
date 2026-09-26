//! Parser fuzzing, stress part (docs/REGEX_TIERS_PLAN.md, F0d): 20,000
//! patterns built from a fixed seed and a regex-syntax-biased token
//! alphabet. Takes ~16 s in Debug, so it is its own step, run by hand or in
//! weekly CI: `zig build test-fuzz-stress`. What each pattern goes through,
//! and what the matcher doesn't cover yet, is in tests/fuzz_common.zig.

const std = @import("std");
const common = @import("fuzz_common.zig");

const tokens = [_][]const u8{
    // atoms
    "a",          "b",     "\\d",  "\\w",          "\\s",    "\\D",    ".",       "[a-z]", "[^a]",               "[]",
    "[^]",        "\\1",   "\\2",  "\\10",         "\\k<n>", "\\p{L}", "\\P{Lu}", "\\p{",  "\\u{1F600}",         "\\u{",
    "\xC3\xA9",   "\\x41", "\\x4", "\\u0041",      "\\u00",  "\\cA",   "\\c",     "\\0",   "\\q{ab}",            "\\",
    "\\b",        "\\B",   "\xFF", "\xED\xB0\x80",
    // groups and assertions
    "(",      ")",      "(?:",     "(?=",   "(?!",                "(?<=",
    "(?<!",       "(?<n>", "(?<n", "(?",
    // quantifiers
              "*",      "+",      "?",       "*?",    "+?",                 "??",
    "*+",         "{",     "}",    "{2}",          "{1,3}",  "{,3}",   "{3,1}",   "{2,}?", "{9007199254740991}",
    // alternation, anchors, class syntax
    "|",
    "^",          "$",     "[",    "]",            "-",      "--",     "&&",      ",",     "[a-",                "[\\d-z]",
    "[[a]--[b]]",
};

test "fuzz: deterministic stress over 20,000 syntax-biased patterns" {
    common.stats = .{};
    var prng = std.Random.DefaultPrng.init(0xF0D_F022);
    const rand = prng.random();
    var buf: [512]u8 = undefined;
    for (0..20_000) |_| {
        var len: usize = 0;
        const n = 1 + rand.uintLessThan(usize, 16);
        for (0..n) |_| {
            const tok = tokens[rand.uintLessThan(usize, tokens.len)];
            if (len + tok.len > buf.len) break;
            @memcpy(buf[len..][0..tok.len], tok);
            len += tok.len;
        }
        common.checkPattern(std.testing.allocator, buf[0..len]) catch |err| {
            std.debug.print("fuzz stress failed on pattern: {s}\n", .{buf[0..len]});
            return err;
        };
    }
    // A broken execution filter must not leave the matcher untested unnoticed.
    try std.testing.expect(common.stats.executed > 0);
}
