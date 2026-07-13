#!/usr/bin/env python3
"""Generate src/unicode/tables.zig from the Unicode Character Database's
UnicodeData.txt, PropList.txt, DerivedCoreProperties.txt, emoji-data.txt,
Scripts.txt, PropertyValueAliases.txt, and ScriptExtensions.txt.

Emits, per Unicode General_Category (both the single-letter major category
and its two-letter subcategories, e.g. both `L` and `Lu`/`Ll`/`Lt`/`Lm`/`Lo`)
plus every ECMA-262 `\\p{...}` binary property available from the first four
files (see BINARY_PROPERTIES below), a minimal sorted list of merged codepoint
ranges -- enough to answer "is this codepoint in \\p{L}?" with a binary
search, without embedding a full per-codepoint table. Also emits the simple
(1-to-1) uppercase/lowercase case mapping pairs from UnicodeData.txt, used
for Unicode-aware case-insensitive matching.

Scripts (`\\p{Script=Greek}` etc.) are emitted separately, as two parallel
arrays (`SCRIPT_NAMES`/`SCRIPT_RANGES`) rather than one `RANGES_<Name>` const
per script like General_Category/binary properties get: there are ~170 of
them (vs. ~85 categories+binary properties), so a hand-maintained Zig enum
variant + switch arm per script (properties.zig's approach for the smaller,
more stable set) isn't practical -- `properties.zig::resolveScript`/
`isInScript` look them up by name/index into these generated arrays instead
of going through the `UnicodeProperty` enum at all.

Short script aliases (`\\p{Script=Grek}` instead of the long
`\\p{Script=Greek}`) come from PropertyValueAliases.txt's `sc ; <short> ;
<long>` lines, emitted as a third pair of parallel arrays
(`SCRIPT_ALIAS_NAMES`/`SCRIPT_ALIAS_INDICES`, sorted by short name) mapping
directly to an index into `SCRIPT_NAMES` -- resolved at generation time, not
runtime, so `resolveScript` only ever binary-searches flat string/int
arrays, never re-derives a canonical name from an alias at lookup time.

`\\p{Script_Extensions=Name}`/`\\p{scx=Name}` reuses the same script index
space as `Script` (a script's identity doesn't change, only which
codepoints count as using it) -- it's emitted as one more parallel array,
`SCRIPT_EXTENSIONS_RANGES`, indexed exactly like `SCRIPT_RANGES`.
ScriptExtensions.txt (per UAX24) only lists the few hundred codepoints
where a codepoint's Script_Extensions set actually differs from its
single-valued Script (everything else defaults to `scx == {sc}`), so
`SCRIPT_EXTENSIONS_RANGES[i]` is built by taking `SCRIPT_RANGES[i]` and
applying just those overrides (add the codepoint to every script its
override line lists; remove it from its old default script if that
script isn't in the override's list) rather than recomputing from scratch.

Usage:
    curl -o UnicodeData.txt https://www.unicode.org/Public/UCD/latest/ucd/UnicodeData.txt
    curl -o PropList.txt https://www.unicode.org/Public/UCD/latest/ucd/PropList.txt
    curl -o DerivedCoreProperties.txt https://www.unicode.org/Public/UCD/latest/ucd/DerivedCoreProperties.txt
    curl -o emoji-data.txt https://unicode.org/Public/UCD/latest/ucd/emoji/emoji-data.txt
    curl -o Scripts.txt https://www.unicode.org/Public/UCD/latest/ucd/Scripts.txt
    curl -o PropertyValueAliases.txt https://www.unicode.org/Public/UCD/latest/ucd/PropertyValueAliases.txt
    curl -o ScriptExtensions.txt https://www.unicode.org/Public/UCD/latest/ucd/ScriptExtensions.txt
    python3 scripts/gen_unicode_tables.py UnicodeData.txt PropList.txt DerivedCoreProperties.txt emoji-data.txt Scripts.txt PropertyValueAliases.txt ScriptExtensions.txt > src/unicode/tables.zig
"""
import re
import sys

MAJOR_CATEGORIES = ["L", "M", "N", "P", "S", "Z", "C"]

# Binary properties to extract, split by which of the three simple
# range-list files (PropList.txt, DerivedCoreProperties.txt, or
# emoji-data.txt) each lives in -- all three share the same
# `HEX[..HEX]  ; Property_Name  # comment` format, unlike UnicodeData.txt's
# one-line-per-codepoint format. This is every ECMA-262 `\p{...}` binary
# property available from these three files (everything except
# `Bidi_Mirrored`/`Assigned`, which aren't in range-list format at all) --
# see src/unicode/README.md.
PROP_LIST_BINARY_PROPERTIES = [
    "ASCII_Hex_Digit",
    "Bidi_Control",
    "Dash",
    "Deprecated",
    "Diacritic",
    "Extender",
    "Hex_Digit",
    "IDS_Binary_Operator",
    "IDS_Trinary_Operator",
    "Ideographic",
    "Join_Control",
    "Logical_Order_Exception",
    "Noncharacter_Code_Point",
    "Pattern_Syntax",
    "Pattern_White_Space",
    "Quotation_Mark",
    "Radical",
    "Regional_Indicator",
    "Sentence_Terminal",
    "Soft_Dotted",
    "Terminal_Punctuation",
    "Unified_Ideograph",
    "Variation_Selector",
    "White_Space",
]
DERIVED_CORE_BINARY_PROPERTIES = [
    "Alphabetic",
    "Cased",
    "Case_Ignorable",
    "Changes_When_Casefolded",
    "Changes_When_Casemapped",
    "Changes_When_Lowercased",
    "Changes_When_Titlecased",
    "Changes_When_Uppercased",
    "Default_Ignorable_Code_Point",
    "Grapheme_Base",
    "Grapheme_Extend",
    "ID_Continue",
    "ID_Start",
    "Lowercase",
    "Math",
    "Uppercase",
    "XID_Continue",
    "XID_Start",
]
EMOJI_BINARY_PROPERTIES = [
    "Emoji",
    "Emoji_Component",
    "Emoji_Modifier",
    "Emoji_Modifier_Base",
    "Emoji_Presentation",
    "Extended_Pictographic",
]
# Unlike the property lists above, these two don't live in a separate
# range-list file at all: `Bidi_Mirrored` is a plain Y/N column already in
# UnicodeData.txt (see parse_unicode_data), and `Assigned` is just "any
# codepoint UnicodeData.txt lists" (every assigned codepoint has exactly one
# General_Category, so it's already implicit in `by_category`) -- no new
# file, no new parsing pass, just data we already have.
UNICODE_DATA_BINARY_PROPERTIES = [
    "Bidi_Mirrored",
    "Assigned",
]
BINARY_PROPERTIES = (
    PROP_LIST_BINARY_PROPERTIES
    + DERIVED_CORE_BINARY_PROPERTIES
    + EMOJI_BINARY_PROPERTIES
    + UNICODE_DATA_BINARY_PROPERTIES
)


# Property name is `[^\s#]+`, not `\S+`: some emoji-data.txt lines have no
# space before the trailing comment (e.g. `Extended_Pictographic# E0.6 ...`),
# so a plain `\S+` would silently capture `Extended_Pictographic#` (including
# the hash) as the property name, never matching any `wanted_names` entry.
RANGE_LINE_RE = re.compile(r"^([0-9A-Fa-f]{4,6})(?:\.\.([0-9A-Fa-f]{4,6}))?\s*;\s*([^\s#]+)")


def parse_range_property_file(path, wanted_names):
    """Parse a PropList.txt/DerivedCoreProperties.txt-format file. Returns
    {property_name: [(start, end), ...]} for each name in `wanted_names`
    found in the file (unsorted, not yet merged)."""
    result = {name: [] for name in wanted_names}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = RANGE_LINE_RE.match(line)
            if not m:
                continue
            name = m.group(3)
            if name not in wanted_names:
                continue
            start = int(m.group(1), 16)
            end = int(m.group(2), 16) if m.group(2) else start
            result[name].append((start, end))
    return result


def parse_all_scripts(path):
    """Parse Scripts.txt (same range-list format as PropList.txt etc., but
    unlike a binary property file, every line's third field is a distinct
    script name rather than a yes/no membership test against a fixed
    property). Returns {script_name: [(start, end), ...]} for every script
    found -- not filtered by a fixed wanted-names set, since we want all of
    them here."""
    result = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = RANGE_LINE_RE.match(line)
            if not m:
                continue
            name = m.group(3)
            start = int(m.group(1), 16)
            end = int(m.group(2), 16) if m.group(2) else start
            result.setdefault(name, []).append((start, end))
    return result


def parse_script_aliases(path):
    """Parse PropertyValueAliases.txt's `sc ; <short> ; <long> [; ...]` lines
    (the Script property's short/long name pairs; unrelated properties like
    `gc`/`ccc` share the same file but are ignored). Returns a list of
    (short, long) tuples. A handful of `sc` lines carry an extra fourth field
    (a legacy alternate name, e.g. `sc ; Zinh ; Inherited ; Qaai`) -- only the
    short/long pair is used, matching what JS's `\\p{Script=...}` accepts."""
    result = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            fields = [field.strip() for field in line.split(";")]
            if len(fields) < 3 or fields[0] != "sc":
                continue
            result.append((fields[1], fields[2]))
    return result


def parse_unicode_data(path):
    """Yield (codepoint, general_category, upper, lower, bidi_mirrored) for
    every assigned codepoint, expanding `<..., First>`/`<..., Last>` range
    pairs. `bidi_mirrored` is field 9 ("Y"/"N"), used for `\\p{Bidi_Mirrored}`
    -- unlike the other binary properties, this one isn't in a separate
    range-list file, it's a plain column in UnicodeData.txt we're already
    reading."""
    with open(path, "r", encoding="utf-8") as f:
        lines = [line.rstrip("\n") for line in f if line.strip()]

    i = 0
    while i < len(lines):
        fields = lines[i].split(";")
        cp = int(fields[0], 16)
        name = fields[1]
        gc = fields[2]
        upper = int(fields[12], 16) if fields[12] else None
        lower = int(fields[13], 16) if fields[13] else None
        bidi_mirrored = fields[9] == "Y"

        if name.endswith(", First>"):
            next_fields = lines[i + 1].split(";")
            assert next_fields[1].endswith(", Last>"), (
                f"expected matching Last> entry after {lines[i]!r}, got {lines[i + 1]!r}"
            )
            end_cp = int(next_fields[0], 16)
            for c in range(cp, end_cp + 1):
                yield (c, gc, None, None, bidi_mirrored)
            i += 2
            continue

        yield (cp, gc, upper, lower, bidi_mirrored)
        i += 1


def merge_ranges(codepoints):
    """codepoints: sorted list of ints. Returns list of (start, end) inclusive
    ranges, merging consecutive codepoints."""
    if not codepoints:
        return []
    ranges = []
    start = prev = codepoints[0]
    for cp in codepoints[1:]:
        if cp == prev + 1:
            prev = cp
            continue
        ranges.append((start, prev))
        start = prev = cp
    ranges.append((start, prev))
    return ranges


def merge_range_tuples(ranges):
    """ranges: list of (start, end) inclusive tuples, possibly unsorted,
    overlapping, or adjacent. Returns a minimal sorted, merged list."""
    if not ranges:
        return []
    ranges = sorted(ranges)
    merged = [ranges[0]]
    for start, end in ranges[1:]:
        last_start, last_end = merged[-1]
        if start <= last_end + 1:
            merged[-1] = (last_start, max(last_end, end))
        else:
            merged.append((start, end))
    return merged


def subtract_codepoint(ranges, cp):
    """ranges: minimal sorted, merged (start, end) tuples. Returns a new list
    with a single codepoint `cp` removed, splitting a range in two if `cp`
    falls strictly inside it."""
    result = []
    for start, end in ranges:
        if cp < start or cp > end:
            result.append((start, end))
            continue
        if start < cp:
            result.append((start, cp - 1))
        if end > cp:
            result.append((cp + 1, end))
    return result


SCRIPT_EXT_LINE_RE = re.compile(r"^([0-9A-Fa-f]{4,6})(?:\.\.([0-9A-Fa-f]{4,6}))?\s*;\s*([^#]+)")


def parse_script_extensions(path):
    """Parse ScriptExtensions.txt. Each line is `HEX[..HEX] ; <short> <short>
    ...  # comment`, listing every *short* script code a codepoint belongs to
    when that set differs from its single Script value (Script_Extensions is
    only ever listed for the codepoints where it diverges from Script --
    UAX24 -- so this file is small, a few hundred codepoints total, not one
    line per assigned codepoint like Scripts.txt). Returns a list of
    (start, end, [short_code, ...]) tuples, short codes unresolved (the
    caller maps them through the alias table, since this file never spells
    out long names)."""
    result = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = SCRIPT_EXT_LINE_RE.match(line)
            if not m:
                continue
            start = int(m.group(1), 16)
            end = int(m.group(2), 16) if m.group(2) else start
            short_codes = m.group(3).split()
            result.append((start, end, short_codes))
    return result


def main():
    if len(sys.argv) != 8:
        print(
            f"usage: {sys.argv[0]} UnicodeData.txt PropList.txt DerivedCoreProperties.txt "
            "emoji-data.txt Scripts.txt PropertyValueAliases.txt ScriptExtensions.txt",
            file=sys.stderr,
        )
        sys.exit(1)
    (
        unicode_data_path,
        prop_list_path,
        derived_core_path,
        emoji_data_path,
        scripts_path,
        property_value_aliases_path,
        script_extensions_path,
    ) = sys.argv[1:8]

    by_category = {}  # category (major or minor) -> list of codepoints
    upper_to_lower = []  # (upper_cp, lower_cp)
    lower_to_upper = []  # (lower_cp, upper_cp)
    bidi_mirrored_codepoints = []
    assigned_codepoints = []  # every codepoint UnicodeData.txt lists at all

    for cp, gc, upper, lower, bidi_mirrored in parse_unicode_data(unicode_data_path):
        by_category.setdefault(gc, []).append(cp)
        major = gc[0]
        by_category.setdefault(major, []).append(cp)
        assigned_codepoints.append(cp)

        if lower is not None and lower != cp:
            upper_to_lower.append((cp, lower))
        if upper is not None and upper != cp:
            lower_to_upper.append((cp, upper))
        if bidi_mirrored:
            bidi_mirrored_codepoints.append(cp)

    upper_to_lower.sort()
    lower_to_upper.sort()

    minor_categories = sorted(c for c in by_category if len(c) == 2)

    print("//! Generated by scripts/gen_unicode_tables.py from the Unicode Character")
    print("//! Database's UnicodeData.txt -- do not edit by hand, regenerate instead.")
    print("//! See scripts/README.md for regeneration instructions.")
    print()
    print("/// An inclusive codepoint range.")
    print("pub const CodepointRange = struct { start: u32, end: u32 };")
    print()
    print("/// A (from, to) codepoint case-mapping pair.")
    print("pub const CaseMapping = struct { from: u32, to: u32 };")
    print()

    def emit_range_table(zig_name, ranges):
        print(f"pub const RANGES_{zig_name}: []const CodepointRange = &.{{")
        for start, end in ranges:
            print(f"    .{{ .start = 0x{start:X}, .end = 0x{end:X} }},")
        print("};")
        print()

    all_categories = MAJOR_CATEGORIES + minor_categories
    for cat in all_categories:
        codepoints = sorted(set(by_category.get(cat, [])))
        emit_range_table(cat, merge_ranges(codepoints))

    prop_list = parse_range_property_file(prop_list_path, set(PROP_LIST_BINARY_PROPERTIES))
    derived_core = parse_range_property_file(
        derived_core_path, set(DERIVED_CORE_BINARY_PROPERTIES)
    )
    emoji_data = parse_range_property_file(emoji_data_path, set(EMOJI_BINARY_PROPERTIES))
    binary_property_ranges = {
        name: merge_range_tuples(prop_list[name]) for name in PROP_LIST_BINARY_PROPERTIES
    }
    binary_property_ranges.update(
        {name: merge_range_tuples(derived_core[name]) for name in DERIVED_CORE_BINARY_PROPERTIES}
    )
    binary_property_ranges.update(
        {name: merge_range_tuples(emoji_data[name]) for name in EMOJI_BINARY_PROPERTIES}
    )
    binary_property_ranges["Bidi_Mirrored"] = merge_ranges(sorted(set(bidi_mirrored_codepoints)))
    binary_property_ranges["Assigned"] = merge_ranges(sorted(set(assigned_codepoints)))
    for name in BINARY_PROPERTIES:
        emit_range_table(name, binary_property_ranges[name])

    scripts = parse_all_scripts(scripts_path)
    script_names = sorted(scripts.keys())
    script_merged_ranges = {name: merge_range_tuples(scripts[name]) for name in script_names}
    print("pub const SCRIPT_NAMES: []const []const u8 = &.{")
    for name in script_names:
        print(f'    "{name}",')
    print("};")
    print()
    print("pub const SCRIPT_RANGES: []const []const CodepointRange = &.{")
    for name in script_names:
        ranges = script_merged_ranges[name]
        range_literals = ", ".join(
            f".{{ .start = 0x{start:X}, .end = 0x{end:X} }}" for start, end in ranges
        )
        print(f"    &.{{ {range_literals} }},")
    print("};")
    print()

    script_name_to_index = {name: i for i, name in enumerate(script_names)}
    aliases = {}  # short name -> script index, deduplicated
    skipped_aliases = 0
    for short, long in parse_script_aliases(property_value_aliases_path):
        index = script_name_to_index.get(long)
        if index is None:
            skipped_aliases += 1
            continue
        aliases[short] = index
    alias_names = sorted(aliases.keys())

    print("pub const SCRIPT_ALIAS_NAMES: []const []const u8 = &.{")
    for name in alias_names:
        print(f'    "{name}",')
    print("};")
    print()
    print("pub const SCRIPT_ALIAS_INDICES: []const u8 = &.{")
    for name in alias_names:
        print(f"    {aliases[name]},")
    print("};")
    print()

    # Script_Extensions: for the vast majority of codepoints, identical to
    # Script (a single-valued property) -- ScriptExtensions.txt only lists
    # the few hundred codepoints where the set of scripts they're used in
    # actually differs from their single default Script (UAX24), so we start
    # from each script's own SCRIPT_RANGES and apply just those overrides,
    # rather than recomputing anything from scratch.
    script_extensions_raw = parse_script_extensions(script_extensions_path)

    # Flat (start, end, name) list for looking up one codepoint's default
    # Script. Only ever queried for the handful of codepoints an override
    # line touches (a few hundred total across the whole file), so a linear
    # scan per lookup is fine -- no need for a full per-codepoint table.
    default_script_flat = [
        (start, end, name) for name in script_names for start, end in script_merged_ranges[name]
    ]

    def default_script_for(cp):
        for start, end, name in default_script_flat:
            if start <= cp <= end:
                return name
        return None

    add_ranges = {name: [] for name in script_names}
    subtract_points = {name: [] for name in script_names}
    skipped_scx_codes = 0
    for start, end, short_codes in script_extensions_raw:
        names_for_line = set()
        for code in short_codes:
            index = aliases.get(code)
            if index is None:
                skipped_scx_codes += 1
                continue
            names_for_line.add(script_names[index])
        for name in names_for_line:
            add_ranges[name].append((start, end))
        # A single override range can, in principle, span codepoints with
        # different default Scripts, so the "does this codepoint keep its
        # default script in scx?" check has to be per-codepoint, not
        # per-range -- these ranges are short (tens of codepoints at most).
        for cp in range(start, end + 1):
            default = default_script_for(cp)
            if default is not None and default not in names_for_line:
                subtract_points[default].append(cp)

    script_extensions_ranges = {}
    for name in script_names:
        ranges = script_merged_ranges[name]
        for cp in subtract_points[name]:
            ranges = subtract_codepoint(ranges, cp)
        script_extensions_ranges[name] = merge_range_tuples(ranges + add_ranges[name])

    print("pub const SCRIPT_EXTENSIONS_RANGES: []const []const CodepointRange = &.{")
    for name in script_names:
        ranges = script_extensions_ranges[name]
        range_literals = ", ".join(
            f".{{ .start = 0x{start:X}, .end = 0x{end:X} }}" for start, end in ranges
        )
        print(f"    &.{{ {range_literals} }},")
    print("};")
    print()

    print("pub const UPPER_TO_LOWER: []const CaseMapping = &.{")
    for cp, lower in upper_to_lower:
        print(f"    .{{ .from = 0x{cp:X}, .to = 0x{lower:X} }},")
    print("};")
    print()

    print("pub const LOWER_TO_UPPER: []const CaseMapping = &.{")
    for cp, upper in lower_to_upper:
        print(f"    .{{ .from = 0x{cp:X}, .to = 0x{upper:X} }},")
    print("};")

    total_ranges = sum(
        len(merge_ranges(sorted(set(by_category.get(cat, []))))) for cat in all_categories
    ) + sum(len(r) for r in binary_property_ranges.values())
    script_ranges = sum(len(merge_range_tuples(scripts[name])) for name in script_names)
    script_extensions_ranges_count = sum(len(r) for r in script_extensions_ranges.values())
    print(
        f"# categories={len(all_categories)} binary_properties={len(BINARY_PROPERTIES)} "
        f"total_ranges={total_ranges} scripts={len(script_names)} script_ranges={script_ranges} "
        f"script_aliases={len(alias_names)} script_aliases_skipped={skipped_aliases} "
        f"script_extensions_lines={len(script_extensions_raw)} "
        f"script_extensions_ranges={script_extensions_ranges_count} "
        f"script_extensions_codes_skipped={skipped_scx_codes} "
        f"upper_to_lower={len(upper_to_lower)} lower_to_upper={len(lower_to_upper)}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
