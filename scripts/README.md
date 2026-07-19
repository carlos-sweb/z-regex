# scripts/

## test262 conformance sample

`extract_test262.py` + `gen_test262_data.py` regenerate `tests/test262_data.zig`,
consumed by `tests/test262_conformance.zig` (run via `zig build test-conformance`).

test262 test files are full JS programs (imperative assertions), not declarative
data, so these scripts only *heuristically* extract the subset that matches a
few common simple shapes (`/pattern/flags.test("str")`, and the Sputnik-style
`var __executed = /pattern/flags.exec("str"); var __expected = [...];`).
Everything else — loops, shared-harness helpers, multi-step assertions — is
honestly skipped, not guessed at. This is a biased sample toward simple test
cases, not an official test262 conformance percentage. See
`docs/ECMASCRIPT_COMPATIBILITY_PLAN.md` Phase 6 for the full rationale.

To regenerate against a fresh test262 checkout:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/tc39/test262.git /tmp/test262
cd /tmp/test262
git sparse-checkout set test/built-ins/RegExp test/language/literals/regexp harness
python3 /path/to/zregex/scripts/extract_test262.py > /tmp/extracted.json
cd /path/to/zregex
python3 scripts/gen_test262_data.py /tmp/extracted.json > tests/test262_data.zig
zig build test-conformance
```

(`extract_test262.py` has no CLI flags; it expects to be *run* with `test/` as a
subdirectory of the current working directory — see `ROOT` at the top of the script.
That's why it's invoked from inside the `/tmp/test262` checkout above.)

## Unicode property tables (`\p{...}`/`\P{...}`, case folding)

`gen_unicode_tables.py` regenerates `src/unicode/tables.zig` (sorted, merged
codepoint ranges per Unicode General_Category, every ECMA-262 binary property
available from these files, every Script plus its short aliases and its
Script_Extensions, and simple case-mapping pairs) from seven Unicode Character
Database files: `UnicodeData.txt` (General_Category, case mappings, and -- see below --
two of the binary properties), `PropList.txt` and `DerivedCoreProperties.txt` (most
binary properties), `emoji-data.txt` (Emoji-related binary properties -- see
`PROP_LIST_BINARY_PROPERTIES`/`DERIVED_CORE_BINARY_PROPERTIES`/
`EMOJI_BINARY_PROPERTIES`/`UNICODE_DATA_BINARY_PROPERTIES` in the script for the full,
current list, 50 properties total), `Scripts.txt` (174 scripts, emitted as the
`SCRIPT_NAMES`/`SCRIPT_RANGES` parallel arrays rather than named `RANGES_<Name>`
constants -- see `src/unicode/README.md` for why), `PropertyValueAliases.txt`
(`sc ; <short> ; <long>` lines, e.g. `sc ; Grek ; Greek`, resolved at generation time
against `SCRIPT_NAMES` and emitted as `SCRIPT_ALIAS_NAMES`/`SCRIPT_ALIAS_INDICES` so
`\p{Script=Grek}` works the same as `\p{Script=Greek}`; two aliases are always skipped
and printed as `script_aliases_skipped=2` on stderr --
`Zzzz -> Unknown` and `Hrkt -> Katakana_Or_Hiragana`, neither of which `Scripts.txt`
actually assigns to any codepoint, so there's no `SCRIPT_NAMES` entry to point at), and
`ScriptExtensions.txt` (a few hundred codepoints, per UAX24, whose Script_Extensions
set differs from their single-valued Script -- e.g. combining accents that are
`Script=Inherited` but `scx` includes every script they're actually combined with;
`SCRIPT_EXTENSIONS_RANGES` reuses `SCRIPT_RANGES`'s index space and is built by
applying just those overrides on top of it, not recomputed from scratch).
`Bidi_Mirrored`/`Assigned` don't need a dedicated file: `Bidi_Mirrored` is a plain Y/N
column `parse_unicode_data` already reads (field 9), and `Assigned` is just every
codepoint that function yields at all (every assigned codepoint has exactly one
General_Category) -- both are computed straight from data the General_Category pass
already collects, no new parsing function needed. See `src/unicode/README.md` for what
is and isn't implemented on top of this data (currently: General_Category, that
binary-property set, Script, short script aliases, and Script_Extensions).

**Gotcha already hit once**: `emoji-data.txt` has lines with no space before the
trailing `#` comment (e.g. `Extended_Pictographic# E0.6 ...`). The property-name regex
must exclude `#` (`[^\s#]+`, not `\S+`) or it silently captures the `#` into the name,
never matching any `wanted_names` entry and losing that line's data with no error --
caught previously by the extracted range count looking implausibly small, not by a
crash. If you edit `RANGE_LINE_RE`, sanity-check the per-property range counts again.

To regenerate against the latest UCD release:

```bash
curl -o /tmp/UnicodeData.txt https://www.unicode.org/Public/UCD/latest/ucd/UnicodeData.txt
curl -o /tmp/PropList.txt https://www.unicode.org/Public/UCD/latest/ucd/PropList.txt
curl -o /tmp/DerivedCoreProperties.txt https://www.unicode.org/Public/UCD/latest/ucd/DerivedCoreProperties.txt
curl -o /tmp/emoji-data.txt https://unicode.org/Public/UCD/latest/ucd/emoji/emoji-data.txt
curl -o /tmp/Scripts.txt https://www.unicode.org/Public/UCD/latest/ucd/Scripts.txt
curl -o /tmp/PropertyValueAliases.txt https://www.unicode.org/Public/UCD/latest/ucd/PropertyValueAliases.txt
curl -o /tmp/ScriptExtensions.txt https://www.unicode.org/Public/UCD/latest/ucd/ScriptExtensions.txt
python3 scripts/gen_unicode_tables.py /tmp/UnicodeData.txt /tmp/PropList.txt /tmp/DerivedCoreProperties.txt /tmp/emoji-data.txt /tmp/Scripts.txt /tmp/PropertyValueAliases.txt /tmp/ScriptExtensions.txt > src/unicode/tables.zig
zig build test
```

To add another binary property, add its exact Unicode name to the relevant
`*_BINARY_PROPERTIES` list (or a new one, for a new source file) in
`gen_unicode_tables.py`, regenerate, then add the enum variant + `rangesFor` case in
`src/unicode/properties.zig::UnicodeProperty`. Scripts, their short aliases, and their
Script_Extensions need no such per-item wiring -- every script `Scripts.txt` defines,
every alias `PropertyValueAliases.txt` maps to one of them, and every override
`ScriptExtensions.txt` lists is already emitted and reachable via
`resolveScript`/`isInScript`/`isInScriptExtensions`.
