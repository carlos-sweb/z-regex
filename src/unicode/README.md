# Unicode Module

Unicode General_Category, binary properties, Script, and Script_Extensions for
`\p{...}`/`\P{...}`, and simple (1-to-1) Unicode case mapping.

## Status: partially implemented

What's real and tested (see `properties.zig`/`casefold.zig`'s own tests, and the
`\p{...}` regression tests in `src/regex.zig`):

- **`\p{Name}` / `\P{Name}` (General_Category)** — `properties.zig` resolves a
  property name (short abbreviation like `L`/`Lu`, the common long-form spelling like
  `Letter`/`Uppercase_Letter`, or an explicit `gc=`/`General_Category=` prefix) to a
  `UnicodeProperty` enum value, and `isInCategory` answers membership via binary search
  over a sorted, merged range table. Wired into the lexer/parser/codegen/matcher as the
  `UNICODE_PROPERTY`/`UNICODE_PROPERTY_INV` opcodes (`src/bytecode/opcodes.zig`).
- **`\p{Name}` / `\P{Name}` (binary properties)** — every ECMA-262 binary property
  available from `PropList.txt`/`DerivedCoreProperties.txt`/`emoji-data.txt`/
  `UnicodeData.txt` (same mechanism as General_Category above), 50 total:
  `ASCII_Hex_Digit`, `Bidi_Control`, `Dash`, `Deprecated`, `Diacritic`, `Extender`,
  `Hex_Digit`, `IDS_Binary_Operator`, `IDS_Trinary_Operator`, `Ideographic`,
  `Join_Control`, `Logical_Order_Exception`, `Noncharacter_Code_Point`,
  `Pattern_Syntax`, `Pattern_White_Space`, `Quotation_Mark`, `Radical`,
  `Regional_Indicator`, `Sentence_Terminal`, `Soft_Dotted`, `Terminal_Punctuation`,
  `Unified_Ideograph`, `Variation_Selector`, `White_Space`, `Alphabetic`, `Cased`,
  `Case_Ignorable`, `Changes_When_Casefolded`, `Changes_When_Casemapped`,
  `Changes_When_Lowercased`, `Changes_When_Titlecased`, `Changes_When_Uppercased`,
  `Default_Ignorable_Code_Point`, `Grapheme_Base`, `Grapheme_Extend`, `ID_Continue`,
  `ID_Start`, `Lowercase`, `Math`, `Uppercase`, `XID_Continue`, `XID_Start`, `Emoji`,
  `Emoji_Component`, `Emoji_Modifier`, `Emoji_Modifier_Base`, `Emoji_Presentation`,
  `Extended_Pictographic`, `Bidi_Mirrored`, `Assigned` — plus two trivial properties
  computed directly with no table: `ASCII` (codepoint ≤ U+007F) and `Any` (every
  codepoint). `Bidi_Mirrored`/`Assigned` are notable for needing no *extra* file at
  all: `Bidi_Mirrored` is a plain Y/N column already present in `UnicodeData.txt`
  (which the General_Category pass already reads in full), and `Assigned` is just "any
  codepoint `UnicodeData.txt` lists at all" — every assigned codepoint has exactly one
  General_Category, so this is data the generator already has in hand, just never
  emitted as its own table before.
- **`\p{Script=Name}` / `\p{sc=Name}` / `\P{Script=Name}`** — every one of the 174
  scripts in `Scripts.txt` (e.g. `\p{Script=Greek}`, `\p{Script=Han}`,
  `\p{sc=Latin}`). Unlike General_Category/binary properties, scripts are **not**
  variants of the `UnicodeProperty` enum -- there are too many (174, vs. ~85 for
  everything else combined) for a hand-maintained enum + switch to be practical.
  Instead `tables.zig` generates two parallel arrays, `SCRIPT_NAMES` (sorted, for binary
  search) and `SCRIPT_RANGES`, and `properties.zig::resolveScript`/`isInScript` look
  scripts up by name/index directly into those, bypassing `UnicodeProperty` entirely.
  Correspondingly, scripts get their own opcodes, `UNICODE_SCRIPT`/
  `UNICODE_SCRIPT_INV`, taking a script-table index instead of a `UnicodeProperty`
  value. A bare `\p{Greek}` (no `Script=`/`sc=` prefix) is correctly rejected, since
  that's not valid JS syntax for a script the way it is for General_Category.
- **Short script aliases** (`\p{Script=Grek}` as well as the long `\p{Script=Greek}`) —
  `resolveScript` also checks a third generated array pair, `SCRIPT_ALIAS_NAMES`/
  `SCRIPT_ALIAS_INDICES`, built from `PropertyValueAliases.txt`'s `sc ; <short> ;
  <long>` lines and resolved to a `SCRIPT_NAMES` index at *generation* time (so lookups
  stay two flat binary searches, never a two-step "resolve alias, then resolve name").
  174 of the 176 `sc` lines in that file map to a script `Scripts.txt` actually assigns
  to some codepoint; the two that don't (`Zzzz`→`Unknown`, the default value for
  unassigned codepoints, and `Hrkt`→`Katakana_Or_Hiragana`, a derived pseudo-script no
  codepoint is ever *directly* assigned) are silently skipped, matching real Script
  data rather than the full alias list.
- **`\p{Script_Extensions=Name}` / `\p{scx=Name}` / `\P{Script_Extensions=Name}`** — a
  broader, possibly multi-valued property than Script: a combining accent like U+0301
  has `Script=Inherited` (its own, single value) but `Script_Extensions` includes every
  script it's actually combined with in real text (Latin, Cyrillic, Greek, ...). Reuses
  `Script`'s index space exactly -- `resolveScript` resolves the name (long or short
  alias, same as `Script`) to the same script index, and a separate
  `isInScriptExtensions`/`tables.SCRIPT_EXTENSIONS_RANGES` (own opcodes,
  `UNICODE_SCRIPT_EXTENSIONS`/`_INV`) answers membership against the broader set instead
  of the narrower one. `SCRIPT_EXTENSIONS_RANGES[i]` is generated by taking
  `SCRIPT_RANGES[i]` and applying `ScriptExtensions.txt`'s overrides on top -- per UAX24
  that file only lists the few hundred codepoints (669, currently) where the two
  properties actually diverge, so `scx == sc` for everything else, and the generator
  doesn't recompute either table from scratch.
- **`\p{...}`/`\P{...}` as a character-class member** (e.g. `[\p{L}\d]`,
  `[\P{Alphabetic}a-z]`, `[^\p{L}\d]`) — up to `opcodes.MAX_CLASS_PROPERTIES` (4)
  property/script/script-extensions tests per class (`error.TooManyClassProperties`
  beyond that, same fixed-capacity policy as the plain-range case below), combined via
  a new `CHAR_CLASS_UNICODE`/`CHAR_CLASS_UNICODE_INV` opcode pair that ORs an inline
  range table (same `MAX_CLASS_RANGES`-slot layout `CHAR_CLASS_RANGES` uses, for the
  class's literal chars/ranges/spliced shorthand) with a small table of property tests.
  Each property test carries its *own* `negated` bit for `\P{...}` used as a class
  member -- e.g. `[\P{L}\d]` means "not-a-letter, or a digit" (a per-member complement
  contributing to the union), which is a different thing from the whole class's
  `[^...]` negation (`[^\p{L}\d]`, applied once via the opcode's `_INV` form, same
  single-XOR-at-the-end approach `CHAR_CLASS_RANGES_INV` already used correctly).
- **Simple case mapping** (`casefold.zig`) — `toUpper`/`toLower` binary-search a
  codepoint's 1-to-1 case pair, wired into `case_insensitive` matching for two shapes:
  a literal non-ASCII character (standalone, e.g. `é`, or as a single character-class
  member, e.g. `[é]`) also matches its case-fold pair (`É`), and quantifiers over a
  literal non-ASCII character still work (`é+` correctly repeats the whole atomic
  multi-byte character regardless of which case each repetition matched). The parser
  marks a `.sequence` node built for one atomic multi-byte literal character (see Phase
  1's notes on why multi-byte literals decompose into per-byte nodes at all) by setting
  its otherwise-unused `char_value` to the decoded code point, so
  `generator.zig::generateSequence` can tell "one atomic character" apart from an
  ordinary multi-atom sequence like `"ab"` (which never sets `char_value`) without any
  new AST node type. When a case pair exists, it emits the same SPLIT/GOTO alternation
  `generateChar` already uses for ASCII letters, just with a whole UTF-8 byte run on
  each branch instead of one byte. Codepoints with no case pair (`casefold.toUpper`/
  `toLower` both `null`, e.g. CJK ideographs) fall through to the plain byte sequence
  unchanged. **Not covered**: non-ASCII character *ranges* (`[À-Ö]` under
  `case_insensitive`) — unlike ASCII's uniform +32 shift, Unicode case mappings aren't a
  simple offset over an arbitrary range, so folding a whole range would need per-codepoint
  expansion rather than the single-pair-per-member trick above; see "Not yet implemented"
  below.

What's NOT implemented yet (see `docs/KNOWN_LIMITATIONS.md` for full detail):

- Unicode-aware `case_insensitive` for non-ASCII character *ranges*, e.g. `[À-Ö]` or
  `\p{...}`-in-a-class members (ASCII ranges/classes, and individual non-ASCII literal
  characters both standalone and as a single class member, already work — see above).
- `u`/`v` regex flags.

## Files

- `tables.zig` — **generated**, do not edit by hand. Regenerate via
  `scripts/gen_unicode_tables.py` (see `scripts/README.md`). Sorted, merged codepoint
  ranges per General_Category (both major categories and their two-letter
  subcategories) and every binary property listed above, the `SCRIPT_NAMES`/
  `SCRIPT_RANGES` script tables, the `SCRIPT_ALIAS_NAMES`/`SCRIPT_ALIAS_INDICES` alias
  tables, and `SCRIPT_EXTENSIONS_RANGES` (same index space as `SCRIPT_RANGES`), plus
  simple uppercase/lowercase case-mapping pairs. Built entirely from seven Unicode
  Character Database files (`UnicodeData.txt`, `PropList.txt`,
  `DerivedCoreProperties.txt`, `emoji-data.txt`, `Scripts.txt`,
  `PropertyValueAliases.txt`, `ScriptExtensions.txt`) — no separate file was needed for
  `Bidi_Mirrored`/`Assigned`, both come from data `UnicodeData.txt` parsing already
  produces.
- `properties.zig` — hand-written. `UnicodeProperty` enum (General_Category values plus
  the binary properties) with its property-name resolution and binary-search membership
  check; separately, `resolveScript`/`isInScript`/`isInScriptExtensions` for the
  generated script, script-alias, and script-extensions tables (index-based, not part of
  the `UnicodeProperty` enum -- see above).
- `casefold.zig` — hand-written. Simple case-mapping lookup (`toUpper`/`toLower`).
- `unicode_tests.zig` — test aggregator (see `src/main.zig`).

## Dependencies

None beyond `std`. No third-party Unicode library is used — the project's "zero
dependencies" property extends to this module: data is generated from the *official*
Unicode Character Database and checked into the repo, the same pattern already used for
the test262 conformance sample (see `scripts/README.md`).
