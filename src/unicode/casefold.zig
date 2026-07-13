//! Simple (1-to-1) Unicode case mapping, for case-insensitive matching of
//! codepoints beyond ASCII.
//!
//! "Simple" here means the Unicode Character Database's Simple_Uppercase/
//! Simple_Lowercase_Mapping fields (one codepoint maps to exactly one other
//! codepoint) -- not full case folding (`CaseFolding.txt`), which also
//! handles multi-codepoint expansions like German `ß` -> `ss`. JS regex
//! case-insensitive matching itself only does simple, per-codepoint folding
//! (a regex `/ß/i` does not match `"ss"` in JS either), so this is the
//! spec-correct primitive for that purpose.

const std = @import("std");
const tables = @import("tables.zig");

fn lookup(table: []const tables.CaseMapping, cp: u32) ?u32 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = table[mid];
        if (cp < entry.from) {
            hi = mid;
        } else if (cp > entry.from) {
            lo = mid + 1;
        } else {
            return entry.to;
        }
    }
    return null;
}

/// The codepoint's simple uppercase mapping, or `null` if it has none
/// (including if it's already uppercase, or has no case at all).
pub fn toUpper(cp: u32) ?u32 {
    return lookup(tables.LOWER_TO_UPPER, cp);
}

/// The codepoint's simple lowercase mapping, or `null` if it has none.
pub fn toLower(cp: u32) ?u32 {
    return lookup(tables.UPPER_TO_LOWER, cp);
}

test "casefold: ASCII" {
    try std.testing.expectEqual(@as(?u32, 'a'), toLower('A'));
    try std.testing.expectEqual(@as(?u32, 'A'), toUpper('a'));
    try std.testing.expect(toLower('5') == null);
}

test "casefold: non-ASCII" {
    // é (U+00E9) / É (U+00C9)
    try std.testing.expectEqual(@as(?u32, 0xE9), toLower(0xC9));
    try std.testing.expectEqual(@as(?u32, 0xC9), toUpper(0xE9));
    // Greek alpha: Α (U+0391) / α (U+03B1)
    try std.testing.expectEqual(@as(?u32, 0x3B1), toLower(0x391));
    try std.testing.expectEqual(@as(?u32, 0x391), toUpper(0x3B1));
}
