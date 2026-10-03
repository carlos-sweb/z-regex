//! ECMA-262's WordCharacters (F5b): what `\b`/`\B` count as a word
//! character. The three executors (T0's VM, its tagged VM, the backtracker)
//! share this, so they can't disagree.
//!
//! The ASCII word characters `[A-Za-z0-9_]`, plus, under `u`/`v` together
//! with `i`, every code point whose simple case folding class holds one of
//! them (`word_fold.extra`, generated from CaseFolding.txt: today U+017F
//! LATIN SMALL LETTER LONG S and U+212A KELVIN SIGN). Without `u`, `i`
//! adds nothing (no non-ASCII character canonicalizes to ASCII there).

const std = @import("std");
const word_fold = @import("word_fold.zig");

/// How many code points the extended set adds.
pub const extra_count = word_fold.extra.len;
/// The extended word characters beyond ASCII (`isWordChar(_, true)`).
pub const extra = word_fold.extra;

/// Whether `cp` is a word character; `extended` under `u`/`v` + `i`.
pub fn isWordChar(cp: u32, extended: bool) bool {
    if (cp < 0x80) return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9') or cp == '_';
    if (!extended) return false;
    for (word_fold.extra) |c| {
        if (c == cp) return true;
    }
    return false;
}

test "word: ASCII, and the extended set only when asked" {
    try std.testing.expect(isWordChar('a', false) and isWordChar('Z', false) and isWordChar('0', false) and isWordChar('_', false));
    try std.testing.expect(!isWordChar('-', true) and !isWordChar(' ', true));
    try std.testing.expect(!isWordChar(0x17F, false) and !isWordChar(0x212A, false));
    try std.testing.expect(isWordChar(0x17F, true) and isWordChar(0x212A, true));
    try std.testing.expect(!isWordChar(0xE9, true));
}
