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
    // F5a, appended so the values above keep their numbers (the AST and the
    // backtracker's bytecode store them): General_Category `LC`
    // (Cased_Letter = Lu | Ll | Lt), and the binary property from
    // DerivedNormalizationProps.txt.
    LC,
    Changes_When_NFKC_Casefolded,
    // F5a(2): General_Category Cn (Unassigned), also part of C.
    Cn,
};

/// Resolve a `\p{Name}` property name to a `UnicodeProperty`. Accepts a
/// General_Category value by any of its names in PropertyValueAliases.txt
/// (`L`, `Letter`, `LC`, `Cased_Letter`, `cntrl`, `digit`, `punct`,
/// `Combining_Mark`, ...), bare or after `General_Category=`/`gc=`, and a
/// binary property by its name or any alias in PropertyAliases.txt
/// (`Alphabetic` or `Alpha`, `White_Space`, `WSpace` or `space`, ...), bare
/// only. Returns `null` for anything else (including Script names, which go
/// through `resolveScript`); callers surface that as a compile error.
pub fn resolveUnicodeProperty(raw_name: []const u8) ?UnicodeProperty {
    var name = raw_name;
    var prefixed = false;
    if (std.mem.startsWith(u8, name, "General_Category=")) {
        name = name["General_Category=".len..];
        prefixed = true;
    } else if (std.mem.startsWith(u8, name, "gc=")) {
        name = name["gc=".len..];
        prefixed = true;
    }

    if (std.meta.stringToEnum(UnicodeProperty, name)) |cat| {
        // After `gc=`/`General_Category=`, only a General_Category value
        // (`\p{gc=Alphabetic}` is a SyntaxError in ECMA-262).
        if (prefixed and !isGeneralCategory(cat)) return null;
        return cat;
    }
    if (binarySearchNames(tables.GC_ALIAS_NAMES, name)) |i| {
        return std.meta.stringToEnum(UnicodeProperty, tables.GC_ALIAS_SHORT[i]);
    }
    if (prefixed) return null;
    if (binarySearchNames(tables.BINARY_ALIAS_NAMES, name)) |i| {
        return std.meta.stringToEnum(UnicodeProperty, tables.BINARY_ALIAS_TARGETS[i]);
    }
    return null;
}

/// Whether `cat` is a General_Category value (major, minor, `LC`, `Cn`)
/// rather than a binary property.
pub fn isGeneralCategory(cat: UnicodeProperty) bool {
    return @intFromEnum(cat) <= @intFromEnum(UnicodeProperty.Cs) or cat == .LC or cat == .Cn;
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
        .LC => tables.RANGES_LC,
        .Changes_When_NFKC_Casefolded => tables.RANGES_Changes_When_NFKC_Casefolded,
        .Cn => tables.RANGES_Cn,
        // ASCII/Any are handled directly in isInCategory (no table needed).
        .ASCII, .Any => unreachable,
    };
}

const ASCII_RANGES: []const CodepointRange = &.{.{ .start = 0, .end = 0x7F }};
const ANY_RANGES: []const CodepointRange = &.{.{ .start = 0, .end = 0x10FFFF }};

/// The sorted, merged code point ranges of property `cat` -- what
/// `isInCategory` searches. The code generator materializes a class's
/// `\p{...}` members from these (F2b).
pub fn propertyRanges(cat: UnicodeProperty) []const CodepointRange {
    return switch (cat) {
        .ASCII => ASCII_RANGES,
        .Any => ANY_RANGES,
        else => rangesFor(cat),
    };
}

/// The properties of strings (ECMA-262, `v` only) that zregex implements,
/// by index (F5c). The other six of the table (`Basic_Emoji`, `RGI_Emoji`,
/// ...) are UnsupportedFeature.
pub const StringProperty = enum(u8) { Emoji_Keycap_Sequence };

pub fn resolveStringProperty(name: []const u8) ?StringProperty {
    return std.meta.stringToEnum(StringProperty, name);
}

/// The strings of a property of strings, each as its code points.
pub fn stringPropertySequences(prop: StringProperty) []const []const u32 {
    return switch (prop) {
        .Emoji_Keycap_Sequence => tables.SEQ_EMOJI_KEYCAP_SEQUENCE,
    };
}

/// The ranges `isInScript` searches for `script_index`.
pub fn scriptRanges(script_index: u8) []const CodepointRange {
    return tables.SCRIPT_RANGES[script_index];
}

/// The ranges `isInScriptExtensions` searches for `script_index`.
pub fn scriptExtensionsRanges(script_index: u8) []const CodepointRange {
    return tables.SCRIPT_EXTENSIONS_RANGES[script_index];
}

/// What the `u` case-folding closure adds to property `cat` (F5b): the
/// code points outside it that share a `u` class with one inside,
/// precomputed so folding `\p{L}` under `iu` doesn't walk its code points.
/// `Any` is closed. What the closure adds to the property's complement is
/// the rest of those classes (`casefold.class` of each).
pub fn propertyFoldDelta(cat: UnicodeProperty) []const CodepointRange {
    if (cat == .Any) return &.{};
    const i = binarySearchNames(tables.FOLD_DELTA_NAMES, @tagName(cat)) orelse unreachable;
    return tables.FOLD_DELTA[i];
}

/// `propertyFoldDelta` for the script at `script_index`.
pub fn scriptFoldDelta(script_index: u8) []const CodepointRange {
    return tables.SCRIPT_FOLD_DELTA[script_index];
}

/// `propertyFoldDelta` for the script extensions of `script_index`.
pub fn scriptExtensionsFoldDelta(script_index: u8) []const CodepointRange {
    return tables.SCRIPT_EXTENSIONS_FOLD_DELTA[script_index];
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

test "properties: gc= takes only General_Category values" {
    const valid = [_][]const u8{
        "Lu", "Ll", "Lt", "Lm", "Lo", "L",  "LC", "Mn", "Mc", "Me", "M",  "Nd", "Nl", "No", "N",
        "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "P",  "Sm", "Sc", "Sk", "So", "S",  "Zs", "Zl",
        "Zp", "Z",  "Cc", "Cf", "Cs", "Co", "Cn", "C",
    };
    for (valid) |v| {
        for ([_][]const u8{ "gc=", "General_Category=" }) |prefix| {
            var buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, v });
            const cat = resolveUnicodeProperty(name) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(resolveUnicodeProperty(v).?, cat);
            try std.testing.expect(isGeneralCategory(cat));
        }
    }
    // Long names and aliases of General_Category values.
    try std.testing.expectEqual(UnicodeProperty.L, resolveUnicodeProperty("gc=Letter").?);
    try std.testing.expectEqual(UnicodeProperty.LC, resolveUnicodeProperty("gc=Cased_Letter").?);
    try std.testing.expectEqual(UnicodeProperty.P, resolveUnicodeProperty("gc=punct").?);
    try std.testing.expectEqual(UnicodeProperty.Cn, resolveUnicodeProperty("gc=Unassigned").?);
    // Binary properties (by name or alias), `ASCII`, `Any` and `Assigned`
    // aren't General_Category values: bare they resolve, after `gc=` not.
    for ([_][]const u8{ "Alphabetic", "Alpha", "ASCII", "Any", "Assigned", "White_Space", "space" }) |b| {
        try std.testing.expect(resolveUnicodeProperty(b) != null);
        var buf: [64]u8 = undefined;
        try std.testing.expect(resolveUnicodeProperty(try std.fmt.bufPrint(&buf, "gc={s}", .{b})) == null);
        try std.testing.expect(resolveUnicodeProperty(try std.fmt.bufPrint(&buf, "General_Category={s}", .{b})) == null);
    }
    // Every enum value is either a General_Category value or resolves only bare.
    for (std.enums.values(UnicodeProperty)) |cat| {
        var buf: [64]u8 = undefined;
        const r = resolveUnicodeProperty(try std.fmt.bufPrint(&buf, "gc={s}", .{@tagName(cat)}));
        try std.testing.expectEqual(isGeneralCategory(cat), r != null);
    }
}

test "properties: resolveUnicodeProperty binary properties" {
    try std.testing.expectEqual(UnicodeProperty.White_Space, resolveUnicodeProperty("White_Space").?);
    try std.testing.expectEqual(UnicodeProperty.Alphabetic, resolveUnicodeProperty("Alphabetic").?);
    try std.testing.expectEqual(UnicodeProperty.Uppercase, resolveUnicodeProperty("Uppercase").?);
    try std.testing.expectEqual(UnicodeProperty.Lowercase, resolveUnicodeProperty("Lowercase").?);
    try std.testing.expectEqual(UnicodeProperty.ASCII, resolveUnicodeProperty("ASCII").?);
    try std.testing.expectEqual(UnicodeProperty.Any, resolveUnicodeProperty("Any").?);
}

test "properties: every UCD name resolves (F5a)" {
    const expect = std.testing.expectEqual;
    try expect(UnicodeProperty.Alphabetic, resolveUnicodeProperty("Alpha").?);
    try expect(UnicodeProperty.White_Space, resolveUnicodeProperty("space").?);
    try expect(UnicodeProperty.White_Space, resolveUnicodeProperty("WSpace").?);
    try expect(UnicodeProperty.Changes_When_NFKC_Casefolded, resolveUnicodeProperty("CWKCF").?);
    try expect(UnicodeProperty.LC, resolveUnicodeProperty("gc=Cased_Letter").?);
    try expect(UnicodeProperty.Cc, resolveUnicodeProperty("cntrl").?);
    try expect(UnicodeProperty.Nd, resolveUnicodeProperty("General_Category=digit").?);
    try expect(UnicodeProperty.M, resolveUnicodeProperty("Combining_Mark").?);
    try std.testing.expect(resolveUnicodeProperty("gc=Alpha") == null);
    try std.testing.expect(resolveUnicodeProperty("alpha") == null);
    try expect(resolveScript("Coptic").?, resolveScript("Qaac").?);
    try expect(resolveScript("Inherited").?, resolveScript("Qaai").?);
}

test "properties: Cn, C with Cn, Script=Unknown (F5a(2))" {
    // U+038B is unassigned; U+0378 too; 'a' and U+E000 (Co) are assigned.
    for ([_]u32{ 0x378, 0x38B, 0x10FFFF }) |cp| {
        try std.testing.expect(isInCategory(cp, .Cn));
        try std.testing.expect(isInCategory(cp, .C));
        try std.testing.expect(isInScript(cp, resolveScript("Unknown").?));
        try std.testing.expect(isInScriptExtensions(cp, resolveScript("Zzzz").?));
    }
    try std.testing.expect(!isInCategory('a', .Cn));
    try std.testing.expect(isInCategory(0xE000, .C) and !isInCategory(0xE000, .Cn));
    try std.testing.expect(!isInScript('a', resolveScript("Unknown").?));
    try std.testing.expectEqual(UnicodeProperty.Cn, resolveUnicodeProperty("Unassigned").?);
    // Katakana_Or_Hiragana (Hrkt) is a valid Script value with no code point.
    try std.testing.expectEqual(@as(usize, 0), scriptRanges(resolveScript("Hrkt").?).len);
}

test "properties: LC is Lu | Ll | Lt" {
    for ([_]u32{ 'A', 'a', 0x1C5, 0x10400, 0x2B0, '1' }) |cp| {
        const want = isInCategory(cp, .Lu) or isInCategory(cp, .Ll) or isInCategory(cp, .Lt);
        try std.testing.expectEqual(want, isInCategory(cp, .LC));
    }
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

test "properties: propertyRanges agrees with isInCategory at every range edge" {
    inline for (@typeInfo(UnicodeProperty).@"enum".fields) |f| {
        const cat: UnicodeProperty = @enumFromInt(f.value);
        const ranges = propertyRanges(cat);
        for (ranges, 0..) |r, i| {
            try std.testing.expect(r.start <= r.end);
            if (i > 0) try std.testing.expect(r.start > ranges[i - 1].end);
            try std.testing.expect(isInCategory(r.start, cat));
            try std.testing.expect(isInCategory(r.end, cat));
            if (r.start > 0 and (i == 0 or ranges[i - 1].end + 1 < r.start)) try std.testing.expect(!isInCategory(r.start - 1, cat));
            if (r.end < 0x10FFFF) try std.testing.expect(!isInCategory(r.end + 1, cat) or (i + 1 < ranges.len and ranges[i + 1].start == r.end + 1));
        }
    }
}

test "properties: every range table is sorted with no overlapping or adjacent ranges" {
    // The lowering views these tables as CharSets in place (F2c), which
    // requires the CharSet invariant.
    const Check = struct {
        fn run(ranges: []const CodepointRange) !void {
            for (ranges, 0..) |r, i| {
                try std.testing.expect(r.start <= r.end and r.end <= 0x10FFFF);
                if (i > 0) try std.testing.expect(r.start > ranges[i - 1].end + 1);
            }
        }
    };
    inline for (@typeInfo(UnicodeProperty).@"enum".fields) |f| try Check.run(propertyRanges(@enumFromInt(f.value)));
    for (tables.SCRIPT_RANGES) |t| try Check.run(t);
    for (tables.SCRIPT_EXTENSIONS_RANGES) |t| try Check.run(t);
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

test "properties: every property has a fold delta, and it is exactly the closure's" {
    const casefold = @import("casefold.zig");
    const gpa = std.testing.allocator;
    for (std.enums.values(UnicodeProperty)) |cat| {
        const delta = propertyFoldDelta(cat);
        // Recompute: the u closure of the property, minus the property.
        const ranges = propertyRanges(cat);
        const pairs = try gpa.alloc([2]u32, ranges.len);
        defer gpa.free(pairs);
        for (ranges, pairs) |r, *p| p.* = .{ r.start, r.end };
        var extra: std.ArrayListUnmanaged(u32) = .empty;
        defer extra.deinit(gpa);
        try casefold.closureExtra(pairs, .unicode, gpa, &extra);
        std.mem.sort(u32, extra.items, {}, std.sort.asc(u32));
        var n: usize = 0;
        for (delta) |r| n += r.end - r.start + 1;
        var uniq: usize = 0;
        for (extra.items, 0..) |cp, i| {
            if (i > 0 and extra.items[i - 1] == cp) continue;
            uniq += 1;
            try std.testing.expect(binarySearchRanges(delta, cp));
        }
        try std.testing.expectEqual(n, uniq);
    }
    // \p{Lu}'s delta holds the lowercase letters; \p{L}'s only a few marks.
    try std.testing.expect(binarySearchRanges(propertyFoldDelta(.Lu), 'a'));
    try std.testing.expect(binarySearchRanges(propertyFoldDelta(.L), 0x345));
    try std.testing.expect(!binarySearchRanges(propertyFoldDelta(.L), 'a'));
    // ASCII gains the long s and the Kelvin sign.
    try std.testing.expectEqualSlices(CodepointRange, &.{ .{ .start = 0x17F, .end = 0x17F }, .{ .start = 0x212A, .end = 0x212A } }, propertyFoldDelta(.ASCII));
}
