//! Unicode property lookup, for `\p{...}`/`\P{...}`.
//!
//! Backed by `tables.zig` (generated from the Unicode Character Database's
//! UnicodeData.txt/PropList.txt/DerivedCoreProperties.txt -- see
//! scripts/gen_unicode_tables.py). Supports General_Category (`L`, `Lu`, ...)
//! and a curated set of binary properties (`White_Space`, `Alphabetic`,
//! `Uppercase`, `Lowercase`, plus the trivial `ASCII`/`Any`). Not supported:
//! Script/Script_Extensions, and most other binary properties; see
//! docs/KNOWN_LIMITATIONS.md for what's deferred and why.

const std = @import("std");
const tables = @import("tables.zig");

pub const CodepointRange = tables.CodepointRange;

/// Unicode properties this engine recognizes for `\p{...}`/`\P{...}`: the
/// seven General_Category major categories (`L`, `M`, `N`, `P`, `S`, `Z`,
/// `C`) and their two-letter subcategories, a curated set of binary
/// properties, and the two trivial properties every codepoint's status is
/// computable without any table (`ASCII`, `Any`).
pub const UnicodeProperty = enum(u8) {
    L,
    Lu,
    Ll,
    Lt,
    Lm,
    Lo,
    M,
    Mn,
    Mc,
    Me,
    N,
    Nd,
    Nl,
    No,
    P,
    Pc,
    Pd,
    Ps,
    Pe,
    Pi,
    Pf,
    Po,
    S,
    Sm,
    Sc,
    Sk,
    So,
    Z,
    Zs,
    Zl,
    Zp,
    C,
    Cc,
    Cf,
    Co,
    Cs,
    // Binary properties from PropList.txt / DerivedCoreProperties.txt: every
    // ECMA-262 `\p{...}` binary property available from those two files (see
    // scripts/gen_unicode_tables.py's BINARY_PROPERTIES for the exact split
    // and what's excluded -- mainly the Emoji_*/Extended_Pictographic
    // properties, which need a separate `emoji-data.txt` not fetched here).
    ASCII_Hex_Digit,
    Bidi_Control,
    Dash,
    Deprecated,
    Diacritic,
    Extender,
    Hex_Digit,
    IDS_Binary_Operator,
    IDS_Trinary_Operator,
    Ideographic,
    Join_Control,
    Logical_Order_Exception,
    Noncharacter_Code_Point,
    Pattern_Syntax,
    Pattern_White_Space,
    Quotation_Mark,
    Radical,
    Regional_Indicator,
    Sentence_Terminal,
    Soft_Dotted,
    Terminal_Punctuation,
    Unified_Ideograph,
    Variation_Selector,
    White_Space,
    Alphabetic,
    Cased,
    Case_Ignorable,
    Changes_When_Casefolded,
    Changes_When_Casemapped,
    Changes_When_Lowercased,
    Changes_When_Titlecased,
    Changes_When_Uppercased,
    Default_Ignorable_Code_Point,
    Grapheme_Base,
    Grapheme_Extend,
    ID_Continue,
    ID_Start,
    Lowercase,
    Math,
    Uppercase,
    XID_Continue,
    XID_Start,
    // Emoji binary properties (from emoji-data.txt).
    Emoji,
    Emoji_Component,
    Emoji_Modifier,
    Emoji_Modifier_Base,
    Emoji_Presentation,
    Extended_Pictographic,
    // Binary properties sourced directly from UnicodeData.txt (no separate
    // range-list file needed): `Bidi_Mirrored` is a plain Y/N column;
    // `Assigned` is "any codepoint UnicodeData.txt lists at all".
    Bidi_Mirrored,
    Assigned,
    // Trivial binary properties (no table needed).
    ASCII,
    Any,
};

/// Long-form aliases JS regexes commonly use for General_Category, mapped to
/// their short Unicode abbreviation. Not exhaustive of every alias the
/// Unicode Property Value Aliases file defines -- just the common ones.
/// Binary properties (`White_Space`, `Alphabetic`, ...) need no alias table:
/// their canonical Unicode name already matches the enum tag directly.
const LONG_ALIASES = [_]struct { name: []const u8, cat: UnicodeProperty }{
    .{ .name = "Letter", .cat = .L },
    .{ .name = "Uppercase_Letter", .cat = .Lu },
    .{ .name = "Lowercase_Letter", .cat = .Ll },
    .{ .name = "Titlecase_Letter", .cat = .Lt },
    .{ .name = "Modifier_Letter", .cat = .Lm },
    .{ .name = "Other_Letter", .cat = .Lo },
    .{ .name = "Mark", .cat = .M },
    .{ .name = "Nonspacing_Mark", .cat = .Mn },
    .{ .name = "Spacing_Mark", .cat = .Mc },
    .{ .name = "Enclosing_Mark", .cat = .Me },
    .{ .name = "Number", .cat = .N },
    .{ .name = "Decimal_Number", .cat = .Nd },
    .{ .name = "Letter_Number", .cat = .Nl },
    .{ .name = "Other_Number", .cat = .No },
    .{ .name = "Punctuation", .cat = .P },
    .{ .name = "Connector_Punctuation", .cat = .Pc },
    .{ .name = "Dash_Punctuation", .cat = .Pd },
    .{ .name = "Open_Punctuation", .cat = .Ps },
    .{ .name = "Close_Punctuation", .cat = .Pe },
    .{ .name = "Initial_Punctuation", .cat = .Pi },
    .{ .name = "Final_Punctuation", .cat = .Pf },
    .{ .name = "Other_Punctuation", .cat = .Po },
    .{ .name = "Symbol", .cat = .S },
    .{ .name = "Math_Symbol", .cat = .Sm },
    .{ .name = "Currency_Symbol", .cat = .Sc },
    .{ .name = "Modifier_Symbol", .cat = .Sk },
    .{ .name = "Other_Symbol", .cat = .So },
    .{ .name = "Separator", .cat = .Z },
    .{ .name = "Space_Separator", .cat = .Zs },
    .{ .name = "Line_Separator", .cat = .Zl },
    .{ .name = "Paragraph_Separator", .cat = .Zp },
    .{ .name = "Other", .cat = .C },
    .{ .name = "Control", .cat = .Cc },
    .{ .name = "Format", .cat = .Cf },
    .{ .name = "Private_Use", .cat = .Co },
    .{ .name = "Surrogate", .cat = .Cs },
};

/// Resolve a `\p{Name}` property name to a `UnicodeProperty`. Accepts the
/// short General_Category abbreviation (`L`, `Lu`, ...), the common
/// long-form General_Category spelling (`Letter`, `Uppercase_Letter`, ...),
/// an optional `General_Category=`/`gc=` prefix (e.g. `\p{gc=Lu}`), and a
/// binary property's canonical name directly (`White_Space`, `Alphabetic`,
/// `Uppercase`, `Lowercase`, `ASCII`, `Any`). Returns `null` for anything
/// else (including real Unicode properties this engine doesn't implement
/// yet, like `Script` -- callers should surface that as a compile error,
/// not silently ignore the property).
pub fn resolveUnicodeProperty(raw_name: []const u8) ?UnicodeProperty {
    var name = raw_name;
    if (std.mem.startsWith(u8, name, "General_Category=")) {
        name = name["General_Category=".len..];
    } else if (std.mem.startsWith(u8, name, "gc=")) {
        name = name["gc=".len..];
    }

    if (std.meta.stringToEnum(UnicodeProperty, name)) |cat| {
        return cat;
    }
    for (LONG_ALIASES) |alias| {
        if (std.mem.eql(u8, alias.name, name)) {
            return alias.cat;
        }
    }
    return null;
}

/// If `raw_name` has a `Script=`/`sc=` prefix (JS's syntax for
/// `\p{Script=Greek}`/`\p{sc=Greek}}`), return the script name after it.
/// Otherwise `null` -- a bare `\p{Greek}` (no prefix) is not valid JS syntax
/// for a script (unlike General_Category, which *can* be used bare), so
/// this must not be tried as a fallback the way `resolveUnicodeProperty`'s
/// `gc=` handling is. `Script_Extensions=`/`scx=` are a different property
/// (see `stripScriptExtensionsPrefix`/`isInScriptExtensions`) and are not
/// recognized by this function -- callers must check
/// `stripScriptExtensionsPrefix` first.
pub fn stripScriptPrefix(raw_name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, raw_name, "Script=")) {
        return raw_name["Script=".len..];
    }
    if (std.mem.startsWith(u8, raw_name, "sc=")) {
        return raw_name["sc=".len..];
    }
    return null;
}

/// If `raw_name` has a `Script_Extensions=`/`scx=` prefix (JS's syntax for
/// `\p{Script_Extensions=Greek}`/`\p{scx=Greek}`), return the script name
/// after it. Otherwise `null`. The name is resolved the same way as `Script`
/// (`resolveScript` accepts both long names and short aliases) -- a script's
/// *identity* doesn't change between `Script` and `Script_Extensions`, only
/// which codepoints count as using it (`isInScriptExtensions` instead of
/// `isInScript`).
pub fn stripScriptExtensionsPrefix(raw_name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, raw_name, "Script_Extensions=")) {
        return raw_name["Script_Extensions=".len..];
    }
    if (std.mem.startsWith(u8, raw_name, "scx=")) {
        return raw_name["scx=".len..];
    }
    return null;
}

/// Resolve a Script name (already stripped of its `Script=`/`sc=` prefix by
/// `stripScriptPrefix`) to an index into `tables.SCRIPT_NAMES`/
/// `SCRIPT_RANGES`. Accepts both the canonical long name (e.g. `Greek`) and
/// the short alias (`Grek`, from `tables.SCRIPT_ALIAS_NAMES`/
/// `SCRIPT_ALIAS_INDICES`, generated from PropertyValueAliases.txt) -- both
/// are valid JS `\p{Script=...}` syntax. Each table is generated pre-sorted,
/// so both lookups are binary searches; the alias table is tried first since
/// short names and long names never collide.
pub fn resolveScript(name: []const u8) ?u8 {
    if (binarySearchNames(tables.SCRIPT_ALIAS_NAMES, name)) |i| {
        return tables.SCRIPT_ALIAS_INDICES[i];
    }
    if (binarySearchNames(tables.SCRIPT_NAMES, name)) |i| {
        return @intCast(i);
    }
    return null;
}

fn binarySearchNames(names: []const []const u8, name: []const u8) ?usize {
    var lo: usize = 0;
    var hi: usize = names.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, name, names[mid])) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => return mid,
        }
    }
    return null;
}

/// Whether codepoint `cp` belongs to the script at `script_index` (as
/// returned by `resolveScript`), via binary search over that script's
/// sorted, merged range list.
pub fn isInScript(cp: u32, script_index: u8) bool {
    return binarySearchRanges(tables.SCRIPT_RANGES[script_index], cp);
}

/// Whether codepoint `cp`'s Script_Extensions set (a broader, possibly
/// multi-valued property than the single-valued Script -- e.g. a combining
/// accent's Script is `Inherited` but its Script_Extensions includes every
/// script it's actually combined with, like Latin and Cyrillic) includes the
/// script at `script_index`. Same index space as `isInScript`/
/// `resolveScript` -- `tables.SCRIPT_EXTENSIONS_RANGES` is generated as
/// `SCRIPT_RANGES` plus/minus the overrides `ScriptExtensions.txt` lists for
/// the (few hundred) codepoints where the two properties actually diverge.
pub fn isInScriptExtensions(cp: u32, script_index: u8) bool {
    return binarySearchRanges(tables.SCRIPT_EXTENSIONS_RANGES[script_index], cp);
}

fn binarySearchRanges(ranges: []const tables.CodepointRange, cp: u32) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.start) {
            hi = mid;
        } else if (cp > r.end) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn rangesFor(cat: UnicodeProperty) []const CodepointRange {
    return switch (cat) {
        .L => tables.RANGES_L,
        .Lu => tables.RANGES_Lu,
        .Ll => tables.RANGES_Ll,
        .Lt => tables.RANGES_Lt,
        .Lm => tables.RANGES_Lm,
        .Lo => tables.RANGES_Lo,
        .M => tables.RANGES_M,
        .Mn => tables.RANGES_Mn,
        .Mc => tables.RANGES_Mc,
        .Me => tables.RANGES_Me,
        .N => tables.RANGES_N,
        .Nd => tables.RANGES_Nd,
        .Nl => tables.RANGES_Nl,
        .No => tables.RANGES_No,
        .P => tables.RANGES_P,
        .Pc => tables.RANGES_Pc,
        .Pd => tables.RANGES_Pd,
        .Ps => tables.RANGES_Ps,
        .Pe => tables.RANGES_Pe,
        .Pi => tables.RANGES_Pi,
        .Pf => tables.RANGES_Pf,
        .Po => tables.RANGES_Po,
        .S => tables.RANGES_S,
        .Sm => tables.RANGES_Sm,
        .Sc => tables.RANGES_Sc,
        .Sk => tables.RANGES_Sk,
        .So => tables.RANGES_So,
        .Z => tables.RANGES_Z,
        .Zs => tables.RANGES_Zs,
        .Zl => tables.RANGES_Zl,
        .Zp => tables.RANGES_Zp,
        .C => tables.RANGES_C,
        .Cc => tables.RANGES_Cc,
        .Cf => tables.RANGES_Cf,
        .Co => tables.RANGES_Co,
        .Cs => tables.RANGES_Cs,
        .ASCII_Hex_Digit => tables.RANGES_ASCII_Hex_Digit,
        .Bidi_Control => tables.RANGES_Bidi_Control,
        .Dash => tables.RANGES_Dash,
        .Deprecated => tables.RANGES_Deprecated,
        .Diacritic => tables.RANGES_Diacritic,
        .Extender => tables.RANGES_Extender,
        .Hex_Digit => tables.RANGES_Hex_Digit,
        .IDS_Binary_Operator => tables.RANGES_IDS_Binary_Operator,
        .IDS_Trinary_Operator => tables.RANGES_IDS_Trinary_Operator,
        .Ideographic => tables.RANGES_Ideographic,
        .Join_Control => tables.RANGES_Join_Control,
        .Logical_Order_Exception => tables.RANGES_Logical_Order_Exception,
        .Noncharacter_Code_Point => tables.RANGES_Noncharacter_Code_Point,
        .Pattern_Syntax => tables.RANGES_Pattern_Syntax,
        .Pattern_White_Space => tables.RANGES_Pattern_White_Space,
        .Quotation_Mark => tables.RANGES_Quotation_Mark,
        .Radical => tables.RANGES_Radical,
        .Regional_Indicator => tables.RANGES_Regional_Indicator,
        .Sentence_Terminal => tables.RANGES_Sentence_Terminal,
        .Soft_Dotted => tables.RANGES_Soft_Dotted,
        .Terminal_Punctuation => tables.RANGES_Terminal_Punctuation,
        .Unified_Ideograph => tables.RANGES_Unified_Ideograph,
        .Variation_Selector => tables.RANGES_Variation_Selector,
        .White_Space => tables.RANGES_White_Space,
        .Alphabetic => tables.RANGES_Alphabetic,
        .Cased => tables.RANGES_Cased,
        .Case_Ignorable => tables.RANGES_Case_Ignorable,
        .Changes_When_Casefolded => tables.RANGES_Changes_When_Casefolded,
        .Changes_When_Casemapped => tables.RANGES_Changes_When_Casemapped,
        .Changes_When_Lowercased => tables.RANGES_Changes_When_Lowercased,
        .Changes_When_Titlecased => tables.RANGES_Changes_When_Titlecased,
        .Changes_When_Uppercased => tables.RANGES_Changes_When_Uppercased,
        .Default_Ignorable_Code_Point => tables.RANGES_Default_Ignorable_Code_Point,
        .Grapheme_Base => tables.RANGES_Grapheme_Base,
        .Grapheme_Extend => tables.RANGES_Grapheme_Extend,
        .ID_Continue => tables.RANGES_ID_Continue,
        .ID_Start => tables.RANGES_ID_Start,
        .Lowercase => tables.RANGES_Lowercase,
        .Math => tables.RANGES_Math,
        .Uppercase => tables.RANGES_Uppercase,
        .XID_Continue => tables.RANGES_XID_Continue,
        .XID_Start => tables.RANGES_XID_Start,
        .Emoji => tables.RANGES_Emoji,
        .Emoji_Component => tables.RANGES_Emoji_Component,
        .Emoji_Modifier => tables.RANGES_Emoji_Modifier,
        .Emoji_Modifier_Base => tables.RANGES_Emoji_Modifier_Base,
        .Emoji_Presentation => tables.RANGES_Emoji_Presentation,
        .Extended_Pictographic => tables.RANGES_Extended_Pictographic,
        .Bidi_Mirrored => tables.RANGES_Bidi_Mirrored,
        .Assigned => tables.RANGES_Assigned,
        // ASCII/Any are handled directly in isInCategory (no table needed).
        .ASCII, .Any => unreachable,
    };
}

/// Whether codepoint `cp` belongs to Unicode property `cat` (binary search
/// over the property's sorted, merged range list, except for the two
/// trivial properties computed directly).
pub fn isInCategory(cp: u32, cat: UnicodeProperty) bool {
    switch (cat) {
        .ASCII => return cp <= 0x7F,
        .Any => return cp <= 0x10FFFF,
        else => {},
    }

    const ranges = rangesFor(cat);
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.start) {
            hi = mid;
        } else if (cp > r.end) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

test "properties: resolveUnicodeProperty short and long General_Category forms" {
    try std.testing.expectEqual(UnicodeProperty.L, resolveUnicodeProperty("L").?);
    try std.testing.expectEqual(UnicodeProperty.Lu, resolveUnicodeProperty("Lu").?);
    try std.testing.expectEqual(UnicodeProperty.L, resolveUnicodeProperty("Letter").?);
    try std.testing.expectEqual(UnicodeProperty.Lu, resolveUnicodeProperty("Uppercase_Letter").?);
    try std.testing.expectEqual(UnicodeProperty.Lu, resolveUnicodeProperty("gc=Lu").?);
    try std.testing.expectEqual(UnicodeProperty.Lu, resolveUnicodeProperty("General_Category=Lu").?);
    try std.testing.expect(resolveUnicodeProperty("Bogus") == null);
    try std.testing.expect(resolveUnicodeProperty("Script=Greek") == null);
}

test "properties: resolveUnicodeProperty binary properties" {
    try std.testing.expectEqual(UnicodeProperty.White_Space, resolveUnicodeProperty("White_Space").?);
    try std.testing.expectEqual(UnicodeProperty.Alphabetic, resolveUnicodeProperty("Alphabetic").?);
    try std.testing.expectEqual(UnicodeProperty.Uppercase, resolveUnicodeProperty("Uppercase").?);
    try std.testing.expectEqual(UnicodeProperty.Lowercase, resolveUnicodeProperty("Lowercase").?);
    try std.testing.expectEqual(UnicodeProperty.ASCII, resolveUnicodeProperty("ASCII").?);
    try std.testing.expectEqual(UnicodeProperty.Any, resolveUnicodeProperty("Any").?);
}

test "properties: isInCategory basic ASCII sanity" {
    try std.testing.expect(isInCategory('a', .L));
    try std.testing.expect(isInCategory('a', .Ll));
    try std.testing.expect(!isInCategory('a', .Lu));
    try std.testing.expect(isInCategory('A', .Lu));
    try std.testing.expect(isInCategory('5', .Nd));
    try std.testing.expect(isInCategory('5', .N));
    try std.testing.expect(!isInCategory('5', .L));
    try std.testing.expect(isInCategory(' ', .Zs));
    try std.testing.expect(isInCategory('.', .Po));
}

test "properties: isInCategory non-ASCII" {
    // é (U+00E9, LATIN SMALL LETTER E WITH ACUTE)
    try std.testing.expect(isInCategory(0xE9, .L));
    try std.testing.expect(isInCategory(0xE9, .Ll));
    // Greek capital alpha (U+0391)
    try std.testing.expect(isInCategory(0x391, .Lu));
    // CJK ideograph (from a First>/Last> expanded range)
    try std.testing.expect(isInCategory(0x4E2D, .Lo));
    // Emoji (U+1F600) is a Symbol, not a Letter
    try std.testing.expect(isInCategory(0x1F600, .So));
    try std.testing.expect(!isInCategory(0x1F600, .L));
}

test "properties: isInCategory binary properties" {
    try std.testing.expect(isInCategory(' ', .White_Space));
    try std.testing.expect(isInCategory('\t', .White_Space));
    try std.testing.expect(isInCategory(0x3000, .White_Space)); // IDEOGRAPHIC SPACE
    try std.testing.expect(!isInCategory('a', .White_Space));

    try std.testing.expect(isInCategory('a', .Alphabetic));
    try std.testing.expect(isInCategory(0xE9, .Alphabetic)); // é
    try std.testing.expect(!isInCategory('5', .Alphabetic));
    try std.testing.expect(!isInCategory(' ', .Alphabetic));

    try std.testing.expect(isInCategory('A', .Uppercase));
    try std.testing.expect(!isInCategory('a', .Uppercase));
    try std.testing.expect(isInCategory('a', .Lowercase));
    try std.testing.expect(!isInCategory('A', .Lowercase));
}

test "properties: isInCategory trivial ASCII/Any properties" {
    try std.testing.expect(isInCategory('a', .ASCII));
    try std.testing.expect(isInCategory(0x7F, .ASCII));
    try std.testing.expect(!isInCategory(0x80, .ASCII));
    try std.testing.expect(!isInCategory(0x1F600, .ASCII));

    try std.testing.expect(isInCategory('a', .Any));
    try std.testing.expect(isInCategory(0x1F600, .Any));
    try std.testing.expect(isInCategory(0x10FFFF, .Any));
}

test "properties: expanded binary property set resolves and matches correctly" {
    // A representative sample, not exhaustive of all 38 -- these confirm the
    // enum/rangesFor wiring for both source files (PropList.txt and
    // DerivedCoreProperties.txt) rather than re-verifying UCD data itself.
    try std.testing.expectEqual(UnicodeProperty.Hex_Digit, resolveUnicodeProperty("Hex_Digit").?);
    try std.testing.expect(isInCategory('A', .Hex_Digit));
    try std.testing.expect(isInCategory('9', .Hex_Digit));
    try std.testing.expect(!isInCategory('G', .Hex_Digit));

    try std.testing.expect(isInCategory('-', .Dash));
    try std.testing.expect(!isInCategory('a', .Dash));

    try std.testing.expect(isInCategory('+', .Math));
    try std.testing.expect(isInCategory('=', .Math));
    try std.testing.expect(!isInCategory('a', .Math));

    try std.testing.expect(isInCategory('"', .Quotation_Mark));
    try std.testing.expect(isInCategory('!', .Terminal_Punctuation));
    try std.testing.expect(isInCategory('a', .ID_Start));
    try std.testing.expect(!isInCategory('1', .ID_Start));
    try std.testing.expect(isInCategory('a', .Cased));
    try std.testing.expect(!isInCategory('1', .Cased));
}

test "properties: emoji binary properties" {
    try std.testing.expectEqual(UnicodeProperty.Emoji, resolveUnicodeProperty("Emoji").?);
    try std.testing.expect(isInCategory(0x1F600, .Emoji)); // GRINNING FACE
    try std.testing.expect(!isInCategory('a', .Emoji));

    // '#' and digits are Emoji_Component (used in keycap sequences like #️⃣)
    // but aren't full standalone emoji themselves.
    try std.testing.expect(isInCategory('#', .Emoji_Component));
    try std.testing.expect(!isInCategory('#', .Emoji_Presentation));

    // U+00A9 COPYRIGHT SIGN is Extended_Pictographic (via a line in
    // emoji-data.txt with no space before the trailing comment -- this
    // specifically exercises the RANGE_LINE_RE fix for that).
    try std.testing.expect(isInCategory(0xA9, .Extended_Pictographic));
}

test "properties: stripScriptPrefix" {
    try std.testing.expectEqualStrings("Greek", stripScriptPrefix("Script=Greek").?);
    try std.testing.expectEqualStrings("Greek", stripScriptPrefix("sc=Greek").?);
    try std.testing.expect(stripScriptPrefix("Greek") == null); // bare name: not valid JS syntax
    try std.testing.expect(stripScriptPrefix("Script_Extensions=Greek") == null); // not implemented
    try std.testing.expect(stripScriptPrefix("L") == null);
}

test "properties: resolveScript and isInScript" {
    const greek = resolveScript("Greek").?;
    try std.testing.expect(isInScript(0x391, greek)); // Greek capital alpha
    try std.testing.expect(!isInScript('a', greek));

    const latin = resolveScript("Latin").?;
    try std.testing.expect(isInScript('a', latin));
    try std.testing.expect(isInScript('Z', latin));
    try std.testing.expect(!isInScript(0x391, latin));

    const han = resolveScript("Han").?;
    try std.testing.expect(isInScript(0x4E2D, han)); // 中

    try std.testing.expect(resolveScript("Bogus") == null);
}

test "properties: resolveScript accepts short script aliases" {
    // Grek/Greek must resolve to the same index and match the same codepoints.
    const greek_short = resolveScript("Grek").?;
    const greek_long = resolveScript("Greek").?;
    try std.testing.expectEqual(greek_long, greek_short);
    try std.testing.expect(isInScript(0x391, greek_short)); // Greek capital alpha

    const latin_short = resolveScript("Latn").?;
    try std.testing.expectEqual(resolveScript("Latin").?, latin_short);
    try std.testing.expect(isInScript('a', latin_short));

    const han_short = resolveScript("Hani").?;
    try std.testing.expectEqual(resolveScript("Han").?, han_short);

    // Bogus short names, and long-name-only scripts with no listed short
    // alias (e.g. the pseudo-script `Katakana_Or_Hiragana`/`Hrkt`, which
    // PropertyValueAliases.txt defines but Scripts.txt never actually
    // assigns to any codepoint), must still fail to resolve.
    try std.testing.expect(resolveScript("Xyzw") == null);
}

test "properties: stripScriptExtensionsPrefix" {
    try std.testing.expectEqualStrings("Greek", stripScriptExtensionsPrefix("Script_Extensions=Greek").?);
    try std.testing.expectEqualStrings("Greek", stripScriptExtensionsPrefix("scx=Greek").?);
    try std.testing.expect(stripScriptExtensionsPrefix("Greek") == null);
    try std.testing.expect(stripScriptExtensionsPrefix("Script=Greek") == null); // that's Script, not scx
    try std.testing.expect(stripScriptExtensionsPrefix("sc=Greek") == null);
}

test "properties: isInScriptExtensions diverges from isInScript for combining marks" {
    // U+0301 (COMBINING ACUTE ACCENT)'s own Script is Inherited, but its
    // Script_Extensions includes Latin, Cyrillic, Greek, and others -- the
    // textbook example of why Script_Extensions exists at all (UAX24).
    const latin = resolveScript("Latin").?;
    const cyrillic = resolveScript("Cyrillic").?;
    const inherited = resolveScript("Inherited").?;

    try std.testing.expect(!isInScript(0x301, latin));
    try std.testing.expect(isInScriptExtensions(0x301, latin));
    try std.testing.expect(!isInScript(0x301, cyrillic));
    try std.testing.expect(isInScriptExtensions(0x301, cyrillic));

    try std.testing.expect(isInScript(0x301, inherited));
    try std.testing.expect(!isInScriptExtensions(0x301, inherited));

    // For the overwhelming majority of codepoints (anything
    // ScriptExtensions.txt doesn't explicitly override), Script_Extensions
    // is identical to the single-valued Script.
    try std.testing.expect(isInScript('a', latin));
    try std.testing.expect(isInScriptExtensions('a', latin));
    try std.testing.expect(isInScript(0x4E2D, resolveScript("Han").?)); // 中
    try std.testing.expect(isInScriptExtensions(0x4E2D, resolveScript("Han").?));
}

test "properties: Bidi_Mirrored and Assigned (sourced directly from UnicodeData.txt)" {
    try std.testing.expectEqual(UnicodeProperty.Bidi_Mirrored, resolveUnicodeProperty("Bidi_Mirrored").?);
    try std.testing.expect(isInCategory('(', .Bidi_Mirrored));
    try std.testing.expect(isInCategory(')', .Bidi_Mirrored));
    try std.testing.expect(!isInCategory('a', .Bidi_Mirrored));

    try std.testing.expectEqual(UnicodeProperty.Assigned, resolveUnicodeProperty("Assigned").?);
    try std.testing.expect(isInCategory('a', .Assigned));
    try std.testing.expect(isInCategory(0x1F600, .Assigned)); // GRINNING FACE
    try std.testing.expect(!isInCategory(0xFFFF, .Assigned)); // noncharacter, unassigned
}
