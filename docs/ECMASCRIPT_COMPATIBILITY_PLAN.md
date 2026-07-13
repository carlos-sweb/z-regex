# Path to 100% ECMAScript RegExp Compatibility

This is an engineering plan, not a schedule. Every gap it addresses was confirmed by
direct testing against the current source tree (see
[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) for the evidence); nothing here is inferred
from old design docs. Sizes (S/M/L/XL) are relative-effort estimates, not calendar time —
this repo has no velocity history to calibrate against.

## What "100%" actually means

There is no single canonical "100% JS regex compatible" checkbox. Two honest ways to
define the target, both used here:

1. **Syntax completeness**: every construct the ECMAScript spec's `Pattern` grammar
   accepts, this engine also accepts with the same meaning (including both Unicode-mode
   and Annex B legacy-mode grammars).
2. **Behavioral parity**: for any pattern + flags + input, `zregexp` produces the same
   match (or same `SyntaxError`) as V8/SpiderMonkey/JavaScriptCore.

(2) is strictly harder than (1) and is, in the strictest sense, unbounded — full parity
requires matching backtracking order, exact error messages' *conditions* (not text), and
every Annex B web-compat quirk. Treat "100%" as **"passes the RegExp-relevant subset of
test262"** (see Phase 6) — that's the industry's own operational definition of ECMAScript
conformance, and it's a finite, automatable target instead of an open-ended aspiration.

## Current baseline (2026-07-04)

Working: literals, `\d \D \w \W \s \S`, `[abc] [^abc] [a-z]`, quantifiers (greedy/lazy/
possessive/counted), groups, alternation, backreferences `\1`-`\9`, lookahead/lookbehind,
anchors, ASCII case-insensitivity, ReDoS protection. 275/275 existing tests pass.

Broken (compiles, produces a *wrong* result silently): `multiline` flag, `dot_all` flag +
default dot-vs-newline, `\xHH`/`\uHHHH`/`\u{H+}`/`\0`/`\cX` escapes, invalid quantifier
ranges (`{2,1}`).

Missing (rejected at parse time or absent from the API): named groups `(?<name>...)` +
`\k<name>`, Unicode property escapes `\p{...}`/`\P{...}`, Unicode case folding, `u`/`v`/
`y`/`d` flags, the entire `src/unicode/` module (currently a README with no code), a
stateful `exec`/`lastIndex`-equivalent for the `g`/`y` flags, `replace()` in the Zig API.

Full detail: [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).

---

## Phase 0 — Fix silent-wrong-result bugs (no new features) — ✅ DONE (2026-07-04)

**Why first**: a feature that's *missing* fails loudly (compile error) and is safe to work
around. A feature that's *broken* fails silently and corrupts every pattern that touches
it. These are the most dangerous bugs in the engine today and require no architecture
change — fix them before building anything on top of the current codegen/executor.

All eight rows below are implemented and covered by new tests in `src/regex.zig`
(plus updated tests in `codegen/generator.zig`, `executor/vm.zig`), 280/280 passing.
Notes on implementation choices: `multiline` reuses the previously-defined-but-dead
`STRING_START`/`STRING_END` opcodes for the non-multiline case and gives `LINE_START`/
`LINE_END` real line-boundary semantics for the multiline case (both `executor/
recursive_matcher.zig` and the legacy `executor/vm.zig`, which shares the same opcode set
and needed the identical fix to stay consistent). `dot_all=false` reuses the existing
`CHAR_RANGE_INV` opcode over `\n`-`\n` rather than introducing a new opcode. `\u{H+}`
escapes above `0x7F` are UTF-8-encoded and expanded into a `sequence` AST node of raw byte
children so the whole code point quantifies as one atomic unit (e.g. `\u{1F600}+`) — this
was more complete than the original "at minimum, stop misparsing it" bar, made possible
because the existing AST already supports quantifying arbitrary sequences (the same
mechanism groups use). `\xHH`/`\u{H+}` fall back to their literal character (Annex-B-style
leniency) when malformed rather than erroring, to avoid breaking any pattern that used a
bare `\x` or `\u` as those literal letters before this fix.

| Task | File(s) | Acceptance test |
|---|---|---|
| `multiline`: `^`/`$` match at line boundaries when set | `codegen/generator.zig`, `executor/recursive_matcher.zig` | `^b` with `multiline=true` finds `"b"` in `"a\nb"` |
| `dot_all` + correct default: `.` excludes `\n` unless `dot_all=true` | same | `a.b` vs `"a\nb"` is `false` by default, `true` with `dot_all=true` |
| `\xHH` decodes to the actual byte | `parser/lexer.zig::parseEscape` | `\x41` matches `"A"`, not `"x41"` |
| `\uHHHH` decodes to the actual code point | same | `A` matches `"A"` |
| `\u{H+}` (code point escape) parses under `u`/`v` mode | same, `parser/parser.zig` | `\u{1F600}` matches 😀 once `u` flag exists (stub until Phase 2's flag work lands; at minimum, stop misparsing it) |
| `\0` matches NUL only when not followed by a digit | same | `\0` matches `"\x00"`; `\01` is legacy-mode octal (Annex B, can be deferred to Phase 5) |
| `\cX` decodes control character | same | `\cA` matches `"\x01"` |
| Reject `{n,m}` when `n > m` | `parser/parser.zig` | `a{2,1}` is a compile error |

**Size**: M. **Blocks**: nothing downstream depends on this, but shipping any later phase
on top of silently-wrong escapes means every subsequent feature inherits the bug.

---

## Phase 1 — Unicode-aware core (architecture prerequisite) — ✅ DONE (2026-07-04, partial scope)

**Why this order**: named groups and flags are additive and don't require touching the
matching core. Code-point-aware matching does — it changes what a single "character" is
throughout the parser, codegen, and executor. Doing this once, early, avoids reworking
every subsequent phase's character-class/dot logic twice.

**What shipped** (268/268 tests passing, new tests in `src/regex.zig`):

- **Internal unit decided**: byte-level by default, decoding a full UTF-8 sequence
  on-the-fly wherever a single "any character" concept is needed (`.`, negated classes,
  literal pattern characters). There's no `u`/`v` flag yet (Phase 5), so this is
  unconditional rather than flag-gated — matches the plan's own observation that
  byte-mode isn't inherently non-conformant, and unconditional code-point-awareness for
  these specific constructs is strictly more correct than the previous byte-blind
  behavior regardless of flags.
- **`.` decodes UTF-8**: new `CHAR_ANY` opcode (dot with `dot_all`) plus the existing
  `CHAR` opcode redefined to decode-and-exclude-newline (dot without `dot_all`), instead
  of consuming exactly one byte. `^.$` now matches a single `é` (2 bytes) or 😀 (4 bytes).
  Falls back to matching exactly 1 byte when the input isn't valid UTF-8 at that position
  (binary-safe).
- **Negated character classes decode UTF-8**: `CHAR_RANGE_INV` and `CHAR_CLASS_INV`
  (`[^...]`, `\W`, `\S`) got the identical fix, for the identical reason — they're the
  same "match anything not in this small set" shape as `.`.
- **Literal multi-byte pattern characters are one atomic unit**: the lexer now decodes a
  full UTF-8 sequence when it hits a non-ASCII lead byte and emits it as a `sequence` of
  raw-byte AST nodes (reusing the exact mechanism Phase 0 built for `\u{H+}` escapes), so
  `é+` correctly repeats the whole 2-byte character instead of only its last byte.
- **`MatchResult` offsets**: left as byte offsets — no code change was needed since this
  was already the case; now documented explicitly (here and in `KNOWN_LIMITATIONS.md`) so
  it's a stated decision rather than an implicit one.

**Explicitly deferred to Phase 3** (not done here): a literal multi-byte character used
*inside* `[...]` (e.g. `[é]`) is now a clear compile error (`error.UnexpectedToken`)
instead of silently splitting into two meaningless raw-byte class members — an
improvement, but not full support. Positive character-class *ranges* over non-ASCII code
points, and the sparse interval-list representation `bytecode/writer.zig::emitCharClass`'s
32-byte bitmap would need to support them, are still unimplemented: that data structure is
tied closely enough to `\p{...}`'s needs that building it now, before Phase 3's actual
property tables exist to validate the design against, risked getting the shape wrong and
redoing it. `\d`/`\w`/`\s` were left ASCII-only, matching JS's own spec (these stay
ASCII-only even under the `u` flag).

**Size**: M (delivered; the full L-XL estimate accounted for the interval-list work now
deferred to Phase 3).

---

## Phase 2 — Named capture groups — ✅ DONE (2026-07-05)

**What shipped** (276/276 tests passing, new tests in `src/regex.zig`):

- **Parser accepts `(?<name>...)`**: the lexer recognizes `(?<name>` (distinct from
  lookbehind `(?<=`/`(?<!`, which it still checks first) and emits a `named_group_start`
  token carrying the name's byte range in the pattern. Named groups still consume a
  regular numeric group index (`group_counter`), so `getCapture(1, ...)` and
  `getNamedCapture("name", ...)` both work for the same group.
- **Duplicate names**: rejected unconditionally (`error.DuplicateGroupName`) — this is
  *stricter* than the plan originally called for (JS allows duplicates across
  mutually-exclusive alternation branches, e.g. `(?<x>a)|(?<x>b)`). Tracking alternation
  exclusivity to allow that case is real added complexity for a rare pattern shape;
  rejecting more than spec requires can't produce an incorrect capture, so it was deferred
  rather than built speculatively. See `KNOWN_LIMITATIONS.md`.
- **No AST/bytecode changes needed**: the plan guessed named groups would need a new
  `NodeType` and bytecode metadata, but since the runtime only ever needs the numeric
  index (names are purely a compile-time lookup concern), the simpler design was: the
  `Parser` itself accumulates a `(name, index)` list (`Parser.group_names`) as it parses,
  `codegen/compiler.zig::compile()` copies it (allocator-owned, so it outlives the
  pattern/parser) into a new `CompileResult.named_groups: []const NamedGroup` field
  (`NamedGroup` defined in `bytecode/format.zig` — the natural shared home, since both
  `codegen` and `executor` already depend on `bytecode` without depending on each other).
  No new opcodes were needed; `SAVE_START_NAMED`/`SAVE_END_NAMED` (pre-existing but never
  emitted) remain unused.
- **Runtime API**: `MatchResult.getNamedCapture(name, input) ?[]const u8`, exactly as
  planned. `MatchResult`/`Matcher` carry a borrowed `named_groups` slice (threaded through
  from `Regex.find`/`findAll` via a new `Matcher.initWithNamedGroups`, keeping the
  existing 2-arg `Matcher.init` unchanged for backward compatibility).
- **`\k<name>` backreferences**: lexer emits a `named_back_ref` token (falling back to a
  literal `k` if not followed by a valid `<name>`, matching the Annex-B-style leniency
  used for `\x`/`\u`/`\c` in Phase 0); the parser resolves the name against
  `group_names` (only names defined *earlier* in the pattern — a forward reference is
  `error.UnknownGroupName`, not silently wrong) and emits the same `back_ref` AST node
  already used for `\1`-`\9`.

**Bug found and fixed along the way**: verifying this phase surfaced a preexisting,
unrelated bug — a literal `-` *outside* a character class always failed to compile
(`error.UnexpectedToken`), because the lexer tokenizes every `-` as `.hyphen`
unconditionally and the parser only ever handled `.hyphen` inside `parseCharClass`. Fixed
by treating `.hyphen` as a literal `-` character in `parseAtom`. See
`KNOWN_LIMITATIONS.md` for detail — this wasn't part of Phase 2's scope, but blocked
verifying it (test patterns naturally used `-` as a separator).

**Size**: M (matched estimate).

**Follow-up, much later same session: duplicate names across mutually exclusive
alternation branches** — the deferred "stricter than spec" gap this section originally
called out got built after all. The core mechanism: every `parseAlternation` call
reserves a fresh `alt_id` and pushes `(alt_id, branch_index)` onto a live stack
(`Parser.branch_stack`) while parsing each branch — deliberately *whether or not* a real
`|` follows, since a named group's branch path needs a globally unique id reserved even
for a single-branch "alternation" for the comparison below to be correct: two groups
that share no genuine alternation ancestor must disagree on `alt_id` the first time
their paths diverge, and that's only guaranteed if literally every `parseAlternation`
call (not just ones that turn out to contain `|`) hands out a fresh one. A named group
snapshots the live stack into its `GroupNameEntry.branch_path` at creation time (nothing
retroactive needed — the push happens *before* parsing each branch, so the stack is
already correct by the time a group inside that branch is created). Two same-named
groups are then compared outermost-first: the first point where their paths name the
*same* `alt_id` but a *different* `branch_index` proves they're in different arms of a
shared disjunction — sufficient on its own, since that ancestor split guarantees only
one side ever executes, regardless of what either path does afterward. If the paths
never diverge that way (identical, one a prefix of the other, or diverging at
*different* `alt_id`s, meaning no shared alternation ancestor exists at all), it's a
conflict, same as before.

Two real, independent bugs surfaced while building this:

1. **`MatchResult.getNamedCapture`/`getNamedCaptureIndices` and `Regex.replace`'s
   `$<name>` substitution all stopped at the first `named_groups` entry with a matching
   name**, regardless of whether that specific group actually participated in the
   match. Never exercised before — duplicate names were always a compile error, so no
   two `named_groups` entries ever shared a name — but with `(?<x>a)|(?<x>b)` now legal,
   looking up `"x"` after matching `"b"` needs to find the *second* declaration's
   capture (the first, from the branch that didn't match, is correctly unset). Fixed by
   checking every same-named entry and using whichever one actually captured, in both
   `src/executor/matcher.zig` and `src/regex.zig`'s replacement-expansion helper.
2. **The first working version leaked memory in nearly every existing parser unit
   test.** The initial design stored each group's branch-path snapshot as a
   heap-allocated `dupe`, freed in `Parser.deinit()` — correct in isolation, but it also
   meant the *stack itself* (`Parser.branch_stack`, an `ArrayListUnmanaged`) allocated on
   first push, which happens in *every* `parseAlternation` call, i.e. for every pattern,
   not just ones with named groups. Dozens of existing unit tests across
   `parser.zig`/`generator.zig` construct a `Parser` directly and never call
   `parser.deinit()` — previously harmless, since `Parser.group_names` (the only
   previously-allocating field) starts empty and only ever allocates for patterns that
   actually have named groups, which those particular tests didn't. Rather than audit
   and fix every such call site, switched `branch_stack` (and each
   `GroupNameEntry.branch_path` snapshot) to a fixed-size array,
   `MAX_ALTERNATION_DEPTH = 32` deep (`error.AlternationTooDeep` beyond that) — the same
   fixed-capacity-with-explicit-overflow-error policy `MAX_CLASS_RANGES`/
   `MAX_CLASS_PROPERTIES` already use elsewhere in this codebase — making the whole
   feature allocation-free and the leak impossible by construction, rather than merely
   patched over.

**Size**: M (larger than a typical single-feature follow-up in this session, but still
well short of "genuinely hard" — the branch-path-comparison algorithm itself is small;
most of the size came from the two bugs above, one of which needed a design change
mid-implementation rather than a local fix).

---

## Phase 3 — Unicode property escapes (`\p{...}`, `\P{...}`) and Unicode-range character classes

**Carries over from Phase 1**: positive character-class ranges over non-ASCII code points
(e.g. `[é]`, `[a-\u{2FF}]`) and an interval-list representation to back them — Phase 1
shipped `.`/negated-class code-point-awareness but deliberately deferred this part (see
Phase 1's notes above) so the data structure could be designed once, against this phase's
actual requirements, instead of guessed at early and reworked.

### Character-class ranges — ✅ DONE (2026-07-05)

- **New opcodes** `CHAR_CLASS_RANGES` / `CHAR_CLASS_RANGES_INV`
  (`src/bytecode/opcodes.zig`): a *fixed-size* inline table of up to
  `opcodes.MAX_CLASS_RANGES` (8) `(start, end)` code point ranges, checked by decoding a
  full UTF-8 sequence at the match position (reusing Phase 1's `utf8SeqLenAt`) and
  linear-scanning the (tiny) range list. A fixed cap was chosen over a genuinely
  variable-length instruction because the existing `decodeInstruction` architecture
  assumes every opcode has a size computable from the opcode alone
  (`Opcode.size() -> u8`) — matching how `CHAR_CLASS`'s existing 256-bit bitmap already
  works the same way. A class needing more than 8 ranges is `error.TooManyRanges`, not a
  silent truncation.
- **Codegen** (`generator.zig::generateCharClass`): if any class member/range exceeds
  U+007F (can't fit the 256-entry byte bitmap), builds the range table and emits
  `CHAR_CLASS_RANGES(_INV)` instead of the bitmap opcodes; ASCII-only classes are
  unaffected (still use the original bitmap, unchanged).
- **Parser** (`parser.zig::parseCharClass`): now accepts `multibyte_char` tokens (from
  Phase 1) as class members and range endpoints, decoding the code point via
  `std.unicode.utf8Decode`.
- **`src/unicode/charrange.zig` was not built** — the plan called for a general-purpose
  sparse interval-list *type*; what actually got built is narrower and simpler (a
  fixed 8-slot table baked directly into the opcode), sufficient for hand-written
  character classes. `\p{...}` below needs something different in kind (hundreds of
  ranges per category), not a bigger version of this table — see its note.

### `\p{...}` / `\P{...}` property escapes (General_Category) — ✅ DONE (2026-07-06)

**What changed since this was blocked**: this sandboxed environment turned out to have
real network access to `unicode.org` after all (confirmed by fetching a fresh
`UnicodeData.txt`, ~1.9MB, `curl -o - https://www.unicode.org/Public/UCD/latest/ucd/UnicodeData.txt`)
— the earlier "no path to fetch or verify real UCD files" assessment was wrong, not
re-verified before being written down. Once confirmed, hand-writing category boundaries
from memory was never on the table (that risk assessment stands); the fix was just to
actually try the fetch instead of assuming it would fail.

**What shipped**:

- `scripts/gen_unicode_tables.py`: parses `UnicodeData.txt` (expanding
  `<..., First>`/`<..., Last>` pseudo-range pairs, e.g. CJK/Hangul blocks), merges each
  General_Category's codepoints into minimal sorted ranges, and emits
  `src/unicode/tables.zig` — 36 categories (7 major + their two-letter subcategories),
  ~5000 ranges total, plus ~3000 simple uppercase/lowercase case-mapping pairs. ~320KB,
  checked in (same "generate once from official data, vendor the result, zero runtime
  dependency" pattern as the test262 conformance sample).
- `src/unicode/properties.zig`: `UnicodeProperty` enum, `resolveUnicodeProperty` (accepts
  short abbreviations like `L`/`Lu`, long-form aliases like `Letter`/`Uppercase_Letter`,
  and an optional `gc=`/`General_Category=` prefix), and `isInCategory` (binary search).
  (Originally named `GeneralCategory`/`resolveGeneralCategory` when this only covered
  General_Category; renamed when binary-property support was added right after, see below
  — the mechanism didn't need to change, just the name, since a binary property's data is
  structurally identical to a category's: a set of codepoint ranges.)
- `src/unicode/casefold.zig`: `toUpper`/`toLower` simple case-mapping lookup, built but
  **not yet wired into `case_insensitive` matching** — see Phase 4 below.
- New opcodes `UNICODE_PROPERTY`/`UNICODE_PROPERTY_INV` (`src/bytecode/opcodes.zig`):
  decode a full UTF-8 codepoint at the match position (reusing the existing
  `decodeCodepointAt` helper from the Phase 3 character-class-range work) and check it
  against the category via `properties.isInCategory`. Quantifiable like any other
  character-matching opcode (`a\p{L}+` etc. work).
- Lexer (`src/parser/lexer.zig`): `\p{Name}`/`\P{Name}` tokenize to `.unicode_prop`/
  `.not_unicode_prop`, carrying the name's byte range (same mechanism as named groups).
  Malformed syntax (no braces, empty name) falls back to a literal `p`/`P`
  (Annex-B-style leniency, matching `\x`/`\u`/`\c`/`\k` elsewhere in this lexer). At this
  point in the session `\p`/`\P` used as a *class member* (`[\p{L}]`) was a hard
  `error.UnicodePropertyInCharClassNotSupported` rather than silently misread as literal
  `p`/`{`/`L`/`}` characters (see the dedicated follow-up entry near the end of this
  phase for when and how that restriction was lifted).
- Parser (`src/parser/parser.zig`): resolves the name via `properties.resolveUnicodeProperty`;
  an unrecognized property name is `error.UnknownUnicodeProperty` — a hard compile error,
  not a silent no-op, since guessing at an unimplemented Unicode property would be
  actively wrong.

**Follow-up, same session: binary properties, expanded three times** — once the
General_Category pipeline existed, adding binary properties turned out to be almost
entirely reuse: a binary property's data *is* a set of codepoint ranges, structurally
identical to a General_Category's, so the exact same `UNICODE_PROPERTY` opcode /
binary-search / range-table mechanism handles all of them with zero changes — only
`properties.zig`'s enum needed new variants (hence the `GeneralCategory` →
`UnicodeProperty` rename) and the generator script needed to also parse the relevant
files (`DerivedCoreProperties.txt`'s properties, like `Alphabetic`, are *derived* —
computed from several other properties — so the pre-computed file was used directly
rather than re-deriving the computation).

1. First pass: 4 properties (`White_Space`, `Alphabetic`, `Uppercase`, `Lowercase`) from
   `PropList.txt`/`DerivedCoreProperties.txt`, as a quick proof the mechanism
   generalized from General_Category.
2. Once confirmed, immediately expanded to *every* ECMA-262 `\p{...}` binary property
   available from those same two files (42 total) rather than stopping at an
   arbitrarily-curated subset, since the marginal cost per property is just a range
   table + one `rangesFor` switch arm.
3. A third pass added the 6 Emoji-related properties (`Emoji`, `Emoji_Component`,
   `Emoji_Modifier`, `Emoji_Modifier_Base`, `Emoji_Presentation`,
   `Extended_Pictographic`) from a newly-fetched `emoji-data.txt` (48 total — see
   `src/unicode/README.md` for the full list), plus the two trivial properties
   `\p{ASCII}` (codepoint ≤ U+007F) and `\p{Any}` (matches everything), computed
   directly with no table at all. **Found a real bug while validating this pass**:
   some `emoji-data.txt` lines have no space before the trailing `#` comment (e.g.
   `Extended_Pictographic# E0.6 ...`), so the existing `\S+` property-name regex would
   have silently folded the `#` into the captured name, never matching the intended
   property and losing every such line's data — caught by noticing the extracted range
   count looked implausibly small before shipping, not by a test failure (there wasn't
   one yet to catch it). Fixed the regex to `[^\s#]+` and re-verified the range count
   looked right before adding tests.

**Follow-up, same session: `\p{Script=Name}`/`\p{sc=Name}` for all 174 scripts** —
`Scripts.txt` turned out to need a *different* plumbing choice than binary properties,
not just more of the same: 174 scripts is far too many for a hand-maintained
`UnicodeProperty` enum variant + `rangesFor` switch arm each (that approach tops out
around the ~85 General_Category + binary property values, which are individually
well-known and stable; scripts are numerous and it'd be pure boilerplate). Instead:

- `gen_unicode_tables.py` gained `parse_all_scripts` (collects *every* script name found
  in `Scripts.txt`, unlike `parse_range_property_file`'s fixed `wanted_names` set for
  binary properties) and emits two parallel generated arrays instead of named
  `RANGES_<Name>` constants: `SCRIPT_NAMES: []const []const u8` (sorted, for binary
  search) and `SCRIPT_RANGES: []const []const CodepointRange`.
- `properties.zig` gained `resolveScript`/`isInScript`, which binary-search those two
  arrays directly by name/index — bypassing the `UnicodeProperty` enum entirely, since
  script identity is "an index into a generated table," not "a hand-written enum tag."
- New opcodes `UNICODE_SCRIPT`/`UNICODE_SCRIPT_INV` (parallel to `UNICODE_PROPERTY`/
  `_INV`, same decode-codepoint-and-binary-search-a-range-table mechanism, just against
  the script tables instead of a `UnicodeProperty` value) and a new AST node type
  `.unicode_script` (parallel to `.unicode_property`) round out the plumbing —
  `ast.zig`/`generator.zig`/`recursive_matcher.zig` all needed the same "make a Script
  variant of the existing Property machinery" treatment.
- Parser-side: `properties.zig::stripScriptPrefix` recognizes the `Script=`/`sc=`
  prefix (mirroring `resolveUnicodeProperty`'s existing `gc=`/`General_Category=`
  handling) and is checked *before* falling back to `resolveUnicodeProperty`, since a
  bare `\p{Greek}` (no prefix) is correctly invalid JS syntax for a script — unlike
  General_Category, which *can* be used bare.

**Follow-up, same session: `\p{Bidi_Mirrored}`/`\p{Assigned}`** — the last two ECMA-262
binary properties, and notable for needing *zero* new UCD file: `Bidi_Mirrored` is a
plain Y/N column (field 9) already present in every line of `UnicodeData.txt`, which
`parse_unicode_data` was already reading in full for General_Category — it just wasn't
extracting that field. `Assigned` needs no dedicated data at all: it's simply "every
codepoint `UnicodeData.txt` lists a line for," which is exactly the set of codepoints
`parse_unicode_data` already yields once per call. Both ranges are computed from data
the existing parsing loop already produces, added to `UNICODE_DATA_BINARY_PROPERTIES` in
`gen_unicode_tables.py` and wired into `UnicodeProperty`/`rangesFor` the same way as any
other binary property (50 total now). No opcode, parser, or codegen changes were needed
— they slot into the existing `UNICODE_PROPERTY`/`UNICODE_PROPERTY_INV` machinery.

**Follow-up, same session: short script aliases (`\p{Script=Grek}`)** — the last item
that turned out to be blocked on a missing file, not a missing mechanism. Fetched
`PropertyValueAliases.txt` and added `parse_script_aliases` (parses its `sc ; <short> ;
<long>` lines, e.g. `sc ; Grek ; Greek`). Resolved each alias to a `SCRIPT_NAMES` index
at *generation* time (in Python, once) rather than at match time, so the generated
output is a third pair of parallel arrays — `SCRIPT_ALIAS_NAMES`/`SCRIPT_ALIAS_INDICES`
— and `properties.zig::resolveScript` just tries a second flat binary search (aliases
first, then canonical names) instead of doing any alias-to-canonical string rewriting
at runtime. Because `resolveScript`'s signature and every caller were unchanged, this
needed **no** opcode, parser, or codegen work at all — smaller than any other Phase 3
follow-up, including `Bidi_Mirrored`/`Assigned` above (which at least touched the
generator's binary-property list). 174 of `PropertyValueAliases.txt`'s 176 `sc` lines
map to a script `Scripts.txt` assigns to some codepoint; the two that don't
(`Zzzz`→`Unknown`, `Hrkt`→`Katakana_Or_Hiragana`) are skipped rather than emitted as a
dangling index, with the skip count printed to stderr during generation as a sanity
check (`script_aliases_skipped=2`, matching the file's actual content, not a bug).

**Follow-up, same session: `\p{Script_Extensions=Name}`/`\p{scx=Name}`** — the last
Script-family item, and the closest of the whole Phase 3 chain to the original Script
support pass in shape (own opcodes, own AST node, own codegen/matcher wiring — the
"generalizes directly" prediction in the earlier "not supported yet" note held up).
Reuses `Script`'s index space exactly rather than introducing a second name→index
mapping: `resolveScript` already resolves both long names and short aliases, and a
script's *identity* doesn't change between `Script` and `Script_Extensions` — only
which codepoints count as using it does. So the new pieces are: a fourth generated
table, `SCRIPT_EXTENSIONS_RANGES` (indexed exactly like `SCRIPT_RANGES`); a new
`isInScriptExtensions` alongside `isInScript` in `properties.zig`; a new
`stripScriptExtensionsPrefix` (checked before `stripScriptPrefix` in the parser, though
order turns out not to matter — `"Script_Extensions="`/`"scx="` never collide with
`"Script="`/`"sc="` as prefixes); a new AST node `unicode_script_extensions`
(`Node.createUnicodeScriptExtensions`, otherwise identical to `createUnicodeScript`);
and a new opcode pair, `UNICODE_SCRIPT_EXTENSIONS`/`_INV`, needed because a single
opcode can't parameterize "which range table," and `UNICODE_SCRIPT`'s operand is
already a script index, not a table selector.

The data side needed more care than the plumbing: `ScriptExtensions.txt` (per UAX24)
only lists the codepoints where a codepoint's Script_Extensions set *diverges* from its
single-valued Script — 206 lines, 669 codepoints total in the current UCD release, not
one line per assigned codepoint. So `gen_unicode_tables.py` doesn't parse this file into
a fresh set of ranges from scratch; it starts from each script's already-computed
`SCRIPT_RANGES` and applies just the overrides on top: for every override line (a
codepoint range plus a list of short script codes, resolved through the same alias
table short-script-aliases built), add that range to every listed script's
Script_Extensions, and — since the override might not include a codepoint's own default
script — walk the (small, ≤45-codepoint) override range point by point, looking up each
codepoint's default Script and subtracting it from that script's set if the override
doesn't also list it. A single codepoint's default script never needs a full
per-codepoint table for this — only the ~669 override-touched codepoints are ever
looked up this way, via a linear scan of the already-built script range list, since a
full expansion of every assigned codepoint would cost far more than the lookups it
enables.

**Follow-up, same session: `\p{...}`/`\P{...}` as a character-class member
(`[\p{L}\d]`)** — the one remaining Phase 3 item that genuinely needed new opcode and
matcher work, not just reused an existing mechanism. Rather than the originally
envisioned "reference an external table from inside the existing bitmap/range class
representation," the actual design keeps `generateCharClass`'s existing paths untouched
and adds a fourth, parallel one: a new opcode pair, `CHAR_CLASS_UNICODE`/
`CHAR_CLASS_UNICODE_INV`, that ORs together an inline code-point-range table (the same
`opcodes.MAX_CLASS_RANGES`-slot layout `CHAR_CLASS_RANGES` already used, for the class's
literal chars/ranges/spliced shorthand) with a small `opcodes.MAX_CLASS_PROPERTIES`-slot
table of property/script/script-extensions tests (`error.TooManyClassProperties` beyond
that cap, same fixed-capacity policy `MAX_CLASS_RANGES`/`error.TooManyRanges` already
established). `generateCharClass` routes to this new path whenever any child is a
`.unicode_property`/`.unicode_script`/`.unicode_script_extensions` node, regardless of
whether the class would otherwise have fit the plain bitmap or range representation.

The one real design question was per-member vs. whole-class negation, since those are
different things: `\P{...}` used as a class member (`[\P{L}\d]`) contributes its own
*complement* to the union ("not-a-letter, or a digit"), while `[^...]` negates the whole
class's match result once, after the union is computed. The existing `.inverted` flag on
`unicode_property`/`unicode_script`/`unicode_script_extensions` nodes already tracked
per-member `\P{...}`-ness (from the standalone-atom case, unchanged) — no new AST field
was needed, just a new `ClassPropertyTest.negated` bit at codegen/match time that reads
directly from it, applied to each property test independently. Whole-class negation
still needs *no* special per-member logic at all: it's the same
single-XOR-at-the-end trick `CHAR_CLASS_RANGES_INV` already used correctly, applied to
the OR of ranges-match-and-properties-match instead of just ranges-match — De Morgan's
law (`not(A or B) = not A and not B`) falls out of that for free. A dedicated regression
test (`[\P{L}\d]` vs. `[^\p{L}\d]`) confirms the two stay distinct.

**Deliberately not supported yet** (see `src/unicode/README.md` for the authoritative
list): Unicode-aware `case_insensitive` for anything beyond plain ASCII (the case-mapping
*data* now exists in `casefold.zig`, it just isn't wired into
`generateChar`/`generateCharRange`/`generateCharClass` yet).

**Size**: Character-class ranges: M (delivered earlier). `\p{...}`/`\P{...}`
(General_Category): M (delivered) — smaller than the original L estimate once the
data-access blocker turned out to be false. Binary properties (50 total, across 4
incremental passes): S (delivered, same session, almost entirely reuse of the
General_Category mechanism — the "curated 4" mid-point never shipped as a permanent
scope decision, just a quick validation step before expanding each time, and the final
`Bidi_Mirrored`/`Assigned` pass needed no new file at all). Script support (174 scripts,
delivered, same session): M — larger than a typical "add more properties" pass since it
needed its own generated-array lookup mechanism rather than reusing the enum/switch
approach, but still far short of the original L estimate. Short script aliases
(delivered, same session): XS — smallest of the whole Phase 3 follow-up chain, pure
generation-time data resolution reusing the Script lookup mechanism as-is.
Script_Extensions (delivered, same session): S — the generator-side subtract/add
algorithm needed real thought, but the plumbing (opcodes/AST/codegen/matcher) was a
near-exact copy of the original Script pass, and the file itself is small (669
codepoints, not one line per assigned codepoint). Class-member support (delivered, same
session): M — matched the original estimate, the only Phase 3 follow-up in this whole
chain that needed a genuinely new opcode pair and matcher function rather than reusing
one, though the per-member-vs-whole-class negation design fell out cleanly from
mechanisms (the `.inverted` AST flag, the single-XOR `_INV` trick) that already existed.

---

## Phase 4 — Unicode case folding — ✅ literal characters DONE; ranges/`\p{}`-in-class not

- ✅ `src/unicode/casefold.zig` built: `toUpper`/`toLower` simple (1-to-1) case-mapping
  lookup, generated from `UnicodeData.txt`'s Simple_Uppercase/Simple_Lowercase_Mapping
  fields (reusing Phase 3's UCD tooling, as planned). **Note on scope**: JS regex
  case-insensitive matching itself only ever does simple, per-codepoint folding (`/ß/i`
  does not match `"ss"` in JS either — full multi-codepoint `CaseFolding.txt` semantics
  are a Unicode *string comparison* concept, not something JS regex matching uses), so
  simple mapping is the spec-correct primitive here, not a shortcut version of something
  bigger that's still needed. Its tables cover ASCII too (`toLower('A') == 'a'`), not
  just non-ASCII, which turned out to matter for the class-member case below.

**Follow-up, later same session: wiring `casefold.zig` into literal-character
matching** — the AST-shape blocker this section originally called out (a literal
multi-byte character parses as a `.sequence` of individual raw-byte `.char` nodes, not
one atomic codepoint node, so there was nothing to look up a case pair *for*) turned out
to need only a small, additive fix rather than a representation overhaul: the parser
already builds that exact `.sequence` at exactly one call site
(`parser.zig`'s `.multibyte_char` case), so it now also decodes the original bytes back
to a codepoint and stores it in the sequence node's otherwise-unused `char_value` field.
An ordinary multi-atom sequence (`"ab"`, built by the *different* `parseSequence`/
top-level-concatenation call site) never sets `char_value`, so it stays the zero
default — meaning `char_value != 0` is an unambiguous "this is one atomic multi-byte
character" marker with no new `NodeType` variant needed, following the same
field-reuse convention `unicode_script`/`unicode_script_extensions` already established
for `char_value`/`inverted`.

`generator.zig::generateSequence` checks that marker: under `case_insensitive`, if
`casefold.toUpper`/`toLower` finds a case pair, it emits the exact same SPLIT/GOTO
alternation `generateChar` already used for ASCII letters — just with a whole UTF-8 byte
run (from `std.unicode.utf8Encode`, the encode-side of the decode already used
elsewhere for multi-byte escapes) on each branch instead of a single `CHAR32`. No case
pair (CJK ideographs, etc.) falls through to the original byte sequence unchanged.
Quantifiers over the result work correctly with no extra effort, since the whole
alternation block sits where a single atom used to and the quantifier machinery already
treats a `SPLIT`/`GOTO` pair opaquely.

The **character-class member** case (`[é]` also matching `É`) turned out to be
*simpler* than the literal-character case, not harder as originally guessed: both
`generateCharClassRanges` and `generateCharClassUnicode` already build a `[2]u32` range
table one `.char`/`.char_range` child at a time, so a shared helper,
`appendCaseFoldPair`, just appends the member's case pair (if any) as one more
single-codepoint range right next to it — no "doubling the fixed 8-slot table" scheme
was needed, each folded member simply costs one more of the existing 8 slots (still
`error.TooManyRanges` if that runs out, same policy as everything else in that table).
Because `casefold.zig`'s tables cover ASCII too, this same helper transparently fixes a
latent gap in mixed classes like `[aé]` (where `'é'` forces the whole class into
ranges/CHAR_CLASS_UNICODE mode, which previously left `'a'` un-folded even though a
pure-ASCII class like `[a]` would have folded it via the bitmap path) — not something
this pass set out to fix, just a side effect of using one code path for every member's
case pair regardless of whether it's ASCII.

- ⬜ Still not folded: non-ASCII character *ranges* (`[À-Ö]`) — unlike ASCII's uniform
  +32 shift, Unicode case mappings aren't a simple offset over an arbitrary range of
  codepoints, so folding one correctly would mean expanding it to individual codepoints
  (each looked up via `casefold.zig`) rather than the single-pair-per-member trick above,
  and a real range could easily need far more slots than the fixed 8-slot range table
  has room for. `\p{...}`-in-a-class members are also still unfolded, for a related
  reason: a property is a whole *set* of codepoints, not a single codepoint with one
  case pair to add — there's no natural place to attach that here at all.

**Size**: Data (`casefold.zig`): M (delivered earlier, unchanged this pass). Wiring:
originally estimated M for "the wiring that's left"; delivered as S for the
literal-character case (the AST blocker resolved to a one-field, one-call-site fix, not
a representation overhaul) plus XS for the class-member case (reused the exact `[2]u32`
range-table shape already being built one child at a time — genuinely simpler than
`\p{...}`-in-a-class's opcode work, not harder as the original per-property-doubling
guess assumed). Character-class *ranges* and `\p{...}`-in-a-class-member folding remain,
each for a different, genuine reason (see above), roughly at the original estimated
size, as a follow-up.

---

## Phase 5a — `y` (sticky) and `d` (hasIndices) — ✅ DONE (2026-07-05)

**What shipped** (285/285 tests passing, new tests in `src/regex.zig`):

- **`y` (sticky)**: `CompileOptions.sticky: bool`, read by `Regex` (not by codegen — it's
  a search-strategy flag, not something that changes the compiled bytecode). `Regex.find`
  under `sticky` only tries position 0 instead of scanning forward; `Regex.findAll` stops
  at the first non-matching position instead of skipping past it. The underlying
  primitive, `Matcher.findAt(input, pos)` / `Regex.findAt(input, pos)` (try to match at
  exactly one position, no scanning), is exposed publicly on its own — it's the direct
  answer to the plan's "requires exposing a position parameter through find" note, and
  doubles as the Zig equivalent of manually tracking `lastIndex` for iterative matching.
- **`d` (hasIndices)**: `MatchResult.getCaptureIndices(index)` /
  `getNamedCaptureIndices(name)` return a `CaptureIndices{ start, end }`. No
  `has_indices` `CompileOptions` field was added — captures already track positions
  internally unconditionally in this engine, so there's no cost a flag would avoid by
  gating the accessor; JS's flag exists for its own (JIT/memory) reasons this design
  doesn't share.
- **`g` (global)**: no new API added — as the original plan noted, `findAll` already
  covers the "get every match" use case, and that's the deliberate answer here rather
  than a stateful `lastIndex`-bearing object.

## Phase 5b — `u` (Unicode mode) — 🚧 strict unrecognized-escape rejection done; malformed-escape/backref strictness not

No longer blocked on `\p{}` not existing at all (Phase 3 shipped General_Category,
binary properties, Script, Script_Extensions, and — as of a same-session follow-up —
`\p{...}` inside a character class, e.g. `[\p{L}\p{N}_]`, the specific gap this section
originally called out as the main thing left for `u`). `u` mode's main spec-visible
effects are enabling `\p{}` (now fully real, including inside a class) and
code-point-vs-code-unit semantics, already unconditionally true in this engine
regardless of any flag (see Phase 1) — so, flag or not, this engine's *default*
behavior was already most of what real `u` mode changes.

**What shipped**: `CompileOptions.unicode: bool = false`, plumbed to a new
`Lexer.unicode_mode` field (`compiler.zig::compile()` sets it before parsing, the same
"public field the owner toggles externally" pattern `in_char_class` already
established, rather than changing `Lexer.init`'s signature). The one concrete rule
implemented: an escaped character that isn't part of a recognized escape sequence
(`d`/`w`/`s`/`p`/`x`/`u`/`c`/`k`/digit/...) or a `SyntaxCharacter` (`^ $ \ . * + ? ( )
[ ] { } |`, plus `/`, plus `-` inside a class) is `error.InvalidEscape` under
`unicode = true`, instead of the Annex-B-style literal-character fallback this engine
uses everywhere by default. This was picked as the first slice specifically because
it's the one rule that's both *unambiguous* (no pattern-level context needed, unlike
e.g. backreference validity, which depends on how many capturing groups the rest of the
pattern has) and *exactly* the example this section already used to describe what "left
for `u`" meant.

Two bugs found and fixed along the way, both in `src/parser/lexer.zig`:
- **`\v`/`\f` were never recognized as standalone escapes at all** — they silently fell
  through to a literal `'v'`/`'f'`, unlike `\n`/`\r`/`\t` right next to them in the same
  `switch`. This is unrelated to the earlier Phase 6 fix for `\s`/`\S` including form
  feed/vertical tab as shorthand-*class-member* ranges — that's a different code path
  (`DIGIT_RANGES`/`WORD_RANGES`/`WHITESPACE_RANGES`) from the standalone-escape-token
  `switch` this bug lived in. Fixed unconditionally, not gated behind `unicode`, since
  it was simply wrong before — and it had to be fixed regardless, or `\v`/`\f` would
  have become spuriously "unrecognized" (and thus rejected) the moment the new strict
  check shipped, a regression relative to real JS where they're always valid.
- **`parseCharClass`'s existing lookahead trick broke under the new strict check**:
  the parser always fetches the token right after `[` while still in *normal*
  (non-class) mode first, purely to check whether it's `^` for negation — if it isn't,
  that token is discarded and re-fetched in class mode (a pre-existing design, needed
  because the lexer has no notion of "inside a class" of its own; see the doc comment
  on `parseCharClass`). `-` is a valid class-mode identity escape but not a valid
  normal-mode one, so `[\-a]` under `unicode = true` would hit the new strict check
  during that first, throwaway, wrong-mode fetch and error out *before* the
  rewind-and-retry-in-the-right-mode ever ran — never a bug before because Annex-B
  leniency meant that speculative fetch could never itself fail, only produce a
  (discarded) token with irrelevant semantics. Fixed by disabling `unicode_mode` for
  just that one speculative lookahead, restoring it before the real, authoritative
  class-mode tokenization runs (which still validates strictly, so a genuinely invalid
  class escape like `[\q]` still correctly errors).

**Deliberately not covered by this pass** (see `docs/KNOWN_LIMITATIONS.md` for the
authoritative list): malformed `\x`/`\u`/`\c`/`\k`/`\p` (e.g. `\x` not followed by
exactly two hex digits) still fall back to the literal-character leniency rather than
erroring — real `u` mode requires each to be well-formed, but doing that correctly for
`\k` specifically depends on whether the pattern has *any* named groups at all
(context outside the escape itself), which is a meaningfully different, riskier kind of
check than the pattern-context-free rule this pass implemented, and was left out rather
than risk getting that context-dependent case wrong. A backreference to a group number
that doesn't exist in the pattern also isn't rejected under `u` yet, for the same
"needs whole-pattern context, not just local lexing" reason.

## Phase 5c — `v` (Unicode Sets mode) — 🚧 class set operations done (one per class, no chaining); everything else not started

This section originally said "genuinely hard, do last," and that assessment held up
enough that the user was explicitly asked to confirm the scope before work started here
(see the session's "AskUserQuestion" checkpoint) — real `v` mode needs `u`'s full
strictness (not just Phase 5b's unrecognized-escape slice), character-class set
operations, multi-code-point string literals (`\q{...}`), nested classes, and `v`'s own
additional reserved-punctuator rules. Rather than attempt all of that in one pass, the
user picked the smallest option offered: `CompileOptions.v` plus set operations, capped
to exactly one operation per class (no chaining, no deep nesting) — not full `v` mode,
one well-defined slice of it, the same "pick the smallest concrete rule" strategy Phase
5b used for `u`.

**What shipped**: `--` (difference, matches the left operand but not the right) and
`&&` (intersection, matches both), e.g. `[\p{L}--[aeiou]]`, `[[a-z]&&[^x]]`. Each
operand is an ordinary class body (`\p{L}`, `a-z\d`, ...), a bare `\p{...}`/`\P{...}`
atom, or a nested `[...]` class (which may itself be `[^...]`-negated). `--`/`&&`/`[`
(for a nested operand) are new lexer tokens (`.class_minus_minus`/`.class_and_and`,
plus reusing `.lbracket` inside a class), but only recognized as such when a new
`Lexer.v_mode` field (set from `CompileOptions.v`, same "public field the owner toggles
externally" pattern `unicode_mode`/`in_char_class` already use) is on — off by default,
so existing patterns using literal `-`/`&`/`[` inside a class are completely unaffected.

**Design decision: match-time evaluation, not compile-time range-set arithmetic.** The
original plan (and an earlier draft of this implementation) assumed set operations
would compute a concrete result range list at compile time — reusing the "expand
`\p{...}` into its actual ranges" idea `\p{...}`-in-a-class already needed. That breaks
down immediately for a realistic pattern like `[\p{L}--[a]]`: `\p{L}` alone is ~700
ranges, and every other class opcode in this engine (`CHAR_CLASS_RANGES`,
`CHAR_CLASS_UNICODE`) caps out at a fixed 8-slot range table specifically to keep
instruction size static — no existing opcode format could hold a result anywhere near
that size, and inventing a genuinely variable-length instruction format was out of
scope for this pass. The actual design sidesteps the problem: a new opcode,
`CHAR_CLASS_SET_OP`, holds *two* independent `CHAR_CLASS_UNICODE`-shaped operand specs
(same 8-range/4-property fixed layout, reused as-is) and evaluates *both* against one
decoded code point at match time, combining with AND (intersection) or AND-NOT
(difference) — `\p{L}`'s ~700 ranges never need to be materialized as a list at all,
just binary-searched twice (once per operand, exactly like `\p{...}` already does
standalone). This also cleanly handles negated operands (`[^x]` as `B` in `[A--B]`):
each operand block carries its own `negated` byte, independent of the whole
operation's own `[^...]` (a third, separate negation layer, from the outermost
bracket) — `collectClassSetOperand` (`generator.zig`) builds each spec by reusing the
exact same range/property-collection logic `generateCharClassUnicode` already has,
just twice, and a shared `evalClassSetOperand` (`recursive_matcher.zig`) evaluates
each one identically to `checkCharClassUnicode`'s union-of-ranges-or-properties check.

**Four real bugs found and fixed while building this, all in `src/parser/parser.zig`**
(the matcher and codegen worked correctly on the first pass once the AST was right —
every bug here was in getting the *parser* to build a correct tree for nested/negated
operands, not in evaluating one):

1. **Double-free from duplicate `errdefer` ownership.** `parseCharClass` (for a nested
   operand1) and `finishClassSetOp` (which takes `left` as a parameter and is
   documented as taking ownership of it) each registered their own `errdefer
   left.deinit()` for the *same* node. If `finishClassSetOp` failed after its own
   errdefer already freed the node, the caller's still-armed errdefer fired again on
   the dangling pointer. The general fix, applied everywhere this pattern recurred
   (operand1's early `errdefer`, and `finishClassSetOp`'s own `left`/`right`): a
   `_owned` boolean flag gates the errdefer off at the exact moment ownership actually
   transfers — for an unconditional hand-off (passing a node into a function that
   documents taking ownership), that's right before the call; for a *fallible* transfer
   like `Node.appendChild` (which can itself fail, e.g. on OOM, without having added
   the item), only *after* it succeeds — flipping the flag before an `appendChild` that
   then fails would leak the node instead of double-freeing it, since neither the
   (empty-of-that-child) parent's errdefer nor the child's own would catch it.
2. **Lexer-mode timing bug, entering a nested operand.** `parseCharClass`'s own
   `^`-negation detection (used for the outermost `[^...]` at the top of every call)
   works by fetching the token right after `[` while still in *normal* (non-class)
   mode, specifically so `^` tokenizes as `.line_start` rather than a literal character
   (documented on the function already, for the top-level case). Recursing into
   `parseCharClass` for a nested operand (e.g. the `[^x]` in `[[a-z]&&[^x]]`) happened
   while the lexer was *still in class mode* from the outer class — so that same
   lookahead instead fetched via `nextInClass`, which has no `^` special case at all,
   silently losing the nested operand's negation (`[^x]` parsed as if it were `[x]`).
   Fixed by explicitly resetting `in_char_class = false` immediately before every such
   recursive call, restoring the precondition the function's own negation logic
   already assumed.
3. **The same mode bug, on the way back out.** After a nested operand's recursive
   `parseCharClass` call returns, its own cleanup fetches whatever follows its `]` (an
   operator for chaining, correctly rejected; or the outer class's own closing `]`) —
   but that fetch happens *inside* the nested call's cleanup, using whatever
   `in_char_class` state is active *then*, which by that point has already been reset
   to `false` by that same cleanup. Fixed with the identical
   rewind-to-token-start-and-re-fetch-in-class-mode trick the top-level `^` lookahead
   already uses for exactly this "wrong-mode speculative fetch" situation.
4. **Double-counted outer negation.** A *flat* (non-bracketed) operand1's
   `char_class` AST node reuses `.inverted` to record the outer class's own `[^...]`
   (correct for an ordinary, non-set-op class — that's literally the only negation a
   flat class has). For a set operation, though, that outer `^` belongs solely to the
   whole operation's *result*, not to operand1 individually — `[^\p{L}--[aeiou]]`'s `^`
   means "NOT(letters that aren't vowels)", not "(NOT letters) that aren't vowels".
   Left uncorrected, `collectClassSetOperand` read operand1's `.inverted` as its own
   negation *in addition to* the separately-passed `outer_negated`, double-applying the
   same `^`. Fixed by explicitly clearing `class.inverted` back to `false` immediately
   before handing a flat operand1 to `finishClassSetOp` (nested operands were
   unaffected — their `.inverted` correctly reflects only *their own* internal `^`, if
   any, once bug 2 was fixed).

**Deliberately not covered by this pass**: operator chaining (`[A--B--C]`, a compile
error, `error.ChainedClassSetOperatorNotSupported`, rather than silently misparsed or
silently accepted with wrong semantics) and nesting beyond one bracket level;
`\q{...}` multi-string literals; `v`'s own additional reserved-punctuator restrictions
inside a class (distinct from, and stricter than, `u`-mode's); and full `u`-mode
strictness under `v` (since `v` implies all of `u`'s rules, and Phase 5b's own
strictness is itself only the unrecognized-escape slice).

**Size**: The scoped-down slice actually shipped: M — smaller than "genuinely hard,"
comparable to the character-class-member `\p{...}` pass (Phase 3's last follow-up),
which also needed a new opcode plus new matcher/codegen logic; most of the actual
effort went into the four parser bugs above (all subtle interactions between
recursion, lexer mode state, and manual memory ownership) rather than the set-operation
concept itself, which is a small, mechanical extension of `CHAR_CLASS_UNICODE`'s
existing per-operand evaluation logic. Full `v` mode (chaining, `\q{...}`, `v`-specific
punctuator rules, full `u` strictness) remains unstarted and, per the original
assessment, is likely to stay the largest remaining item in this plan.

---

## Phase 6 — Conformance validation loop — ✅ STOOD UP (2026-07-05); ✅ 168/168 (100%) (2026-07-06)

This phase was meant to run *continuously* alongside 0-5, not strictly after them; it
ended up done after 0-5 instead of alongside, which is a real process gap worth naming
(see "What we'd do differently" below) — but the harness now exists and runs.

**Reality check vs. the original plan**: "test262 tests are structured enough to script
this without a full JS interpreter" turned out to be wrong. test262 tests are full JS
*programs* with imperative assertions (`var arr = /pattern/.exec(str); if (arr[0] !== "x")
throw ...`), not declarative pattern/input/expected data. Verified by fetching and reading
real files from `tc39/test262` before writing any harness code, rather than assuming.

**What shipped**:

- `scripts/extract_test262.py`: a **heuristic extractor**, not a JS interpreter. Recognizes
  a handful of common simple shapes via source-text pattern matching (bare
  `.test()`/`.exec()` calls checked against a boolean/`null`, and the common Sputnik-style
  `var __executed = /pat/.exec(str); var __expected = [...];` capture-array convention,
  including resolving the input through an intermediate `var __string = "...";` when
  needed). Everything else — loops, `String.fromCharCode` iteration, shared harness
  helpers (`compareArray.js`, `propertyHelper.js`), multi-step logic — is honestly counted
  as skipped, not guessed at or silently ignored. `\p{...}`/`Symbol.*`-related and
  syntax-error-expecting (`negative:`) tests are excluded as separately out of scope.
- Of ~2117 files under test262's `test/built-ins/RegExp` + `test/language/literals/regexp`,
  **168 cases extracted from 167 files** (a small, simple-case-biased sample — seeing this
  ratio in the output is itself useful information about how much of test262 requires
  real JS execution to check, which is most of it).
- `scripts/gen_test262_data.py`: turns the extracted cases into `tests/test262_data.zig`
  (a plain Zig data array, vendored/checked in — no network access needed at test time).
- `tests/test262_conformance.zig`: runs each case, correctly mapping JS's *unanchored
  substring-search* `.test()`/`.exec()` semantics to `Regex.find()` (not `test_()`, which
  is a full-string match — see the `test_()` vs `find()` note in `KNOWN_LIMITATIONS.md`),
  and reports a pass rate without hard-failing the build (per the original plan: this is a
  measurement, not a 100%-or-bust gate).
- Wired in as `zig build test-conformance`, separate from `zig build test`, per plan.
- **Current result: 168/168 (100%)**, 0 compile errors (started at 141/168, 83.9%, with 13
  compile errors — see the fix history below).

**What this number does and doesn't mean**: it's a real signal from real, official
ECMAScript conformance tests — not made up — but it's a biased sample (only the JS-source
shapes simple enough to extract without a JS engine) and a small one (168 of test262's
several-thousand-plus RegExp-relevant tests). Treat it as "100% of the easy-to-check
subset," not "100% JS RegExp compatible" — `\p{...}`, case folding, `u`/`v` flags, and
`$1`/`$&` replacement substitution are all real, known gaps this sample doesn't exercise.

**Immediate payoff — a real crash bug found and fixed**: the very first extracted case run
against zregexp (`/(a*)b\1+/.exec("baaac")`, test262's `S15.10.2.9_A1_T5.js`) **segfaulted
the process** instead of returning a result, using the library's real default settings
(not a contrived stress test). Root cause: `isStarConsumePath` (the heuristic that lets a
quantifier loop use the iterative, zero-width-progress-guarded `matchStarGreedy` instead of
plain recursion) didn't recognize `BACK_REF` as a quantifiable atom, and separately only
recognized the `X*` bytecode shape, not the `X+` shape `generatePlus` actually emits. Both
gaps sent `\1+` down plain recursive alternation, which has no protection against a
zero-width atom (an empty backreference) — 1000 levels of that specific recursion
(the default `max_recursion_depth`) overflows the native stack before the counter can
return `error.RecursionLimitExceeded`. Fixed in `src/executor/recursive_matcher.zig`; see
`KNOWN_LIMITATIONS.md` for the full writeup and the regression test.

**The road from 141/168 to 168/168, one triaged batch at a time** (full writeup of each in
`KNOWN_LIMITATIONS.md`; every fix has a permanent regression test in `src/regex.zig`):

1. Three character-class parsing gaps: metacharacters weren't literal inside `[...]`
   (`[*&$]`, `[.]` — the lexer had no "inside a class" context), shorthand classes
   couldn't be class members (`[a-c\d]`), and `[^]` ("match anything") wasn't recognized.
   Fixed via a parser-toggled `in_char_class` lexer mode and shorthand-splicing in
   `parseCharClass`. This alone took compile errors from 13 to 0.
2. Incidental: `\s`/`\S` were missing `\f`/`\v` from their byte-range tables.
3. A bug in the *test harness itself*, not the engine: `scripts/extract_test262.py`'s
   JS-string decoder didn't handle `\b`/`\f`/`\v` string escapes, silently corrupting
   input strings like `"easy\btoride"` before they ever reached zregexp. Fixed the
   extractor and regenerated `tests/test262_data.zig` against a fresh test262 checkout.
4. Six real backtracking-correctness bugs in the engine, found one at a time by
   re-running the suite after each fix and triaging the next-simplest failure: case
   folding not applied to character classes/ranges (only single chars), a quantified capturing
   group losing its last iteration's capture on backtrack, `*`/`?` on a capturing group
   not actually being greedy (`generateStar` had a literal `// Non-greedy for now` TODO
   left since early development), lazy quantifiers capped at exactly one iteration by an
   inverted-order zero-width-progress check, a stale nested-optional capture leaking
   across an enclosing loop's iterations, a backreference to a never-participated group
   failing instead of matching empty (per spec), and a negative lookahead's own captures
   leaking out through a path per-instruction rollback couldn't catch.

**What we'd do differently**: stand this up literally alongside Phase 0, as originally
planned, instead of after Phases 0-5. It would have caught the `\1+` crash (and, as
confirmed, every gap above, since backreferences, basic classes, and quantifiers existed
from early on) months of hypothetical development time sooner. The lesson generalizes: a
conformance/fuzz harness against *real* external test data is worth building before
polishing new features, not after — several of this session's earlier "done" phases
shipped on top of a matcher whose core greedy-quantifier and capture-backtracking logic,
it turns out, had been subtly wrong since early development, invisible until a real
external test suite exercised the right combinations.

**Size**: M to stand up (matched estimate) — the JS-vs-heuristic-extraction reality was
the surprise, not the raw effort.

---

## Phase 7 — API and documentation parity — ✅ DONE (2026-07-06)

- ✅ **`replace()`/`replaceAll()` implemented in the pure Zig API** (`src/regex.zig`):
  `Regex.replace` (first match only, JS `.replace` default semantics) and
  `Regex.replaceAll` (every match, JS `.replaceAll`/`.replace` with `/g`), plus one-shot
  free-function wrappers. Initially literal-only (same scope as the C API's
  `zregexp_replace`); **later extended** to support JS's full replacement substitution
  syntax — `$$`, `$&`, `` $` ``, `$'`, `$1`-`$99`, `$<name>` (`expandReplacement` in
  `src/regex.zig`) — since that was identified as the simplest remaining documented gap
  and tackled as a direct follow-up. A group that exists in the pattern but didn't
  participate substitutes as empty string; a `$N`/`$<name>` with no corresponding group
  is left as literal text, matching JS exactly (no error). Needed threading a new
  `group_count: u8` field through `CompileResult`/`Regex` to distinguish those two cases,
  since `MatchResult.getCapture` alone can't tell "group doesn't exist" from "group
  exists but is unset." The C API's `zregexp_replace` was deliberately left as literal-only
  substitution — out of scope for this pass, not forgotten (see `KNOWN_LIMITATIONS.md`).
  Covered by regression tests in `src/regex.zig`.
- ✅ `docs/KNOWN_LIMITATIONS.md` and `README.md`/`README.es.md` rewritten to cite the
  measured test262 pass rate instead of the old informal "~70%" estimate, with the
  "Supported Features"/roadmap sections updated for `replace`/`replaceAll` and the
  character-class fixes, mirrored into `README.es.md` per the established
  English-primary, Spanish-translation rule. (Phase 6 kept running after this phase
  landed and drove the cited pass rate from 89.3% up to 100% — see Phase 6 above for the
  final numbers; these docs were updated again alongside that work rather than treated as
  a one-time snapshot.)

**Size**: S (matched estimate).

---

## Phase 8 — Real conformance measurement infrastructure — 🚧 Phase 0 (C API parity, then public C/C++ support dropped) DONE (2026-07-08); harness not started

**Why this phase exists**: every "100%" number cited above (Phase 6's 168/168) measures a
**biased, heuristically-extracted sample** of test262, not real JS RegExp conformance —
see `KNOWN_LIMITATIONS.md`'s "test262 conformance sample" section for exactly what's
extracted and what's silently skipped (whole feature categories: unicode property
escapes, the `v` flag, `d`/match-indices, duplicate named groups, lookbehind, and more).
Asked directly whether 168/168 meant "100% of real JS RegExp," the honest answer was no —
which prompted a deliberate strategic pivot: stop treating the biased sample as the goal,
and build toward a **real, verifiable** conformance number instead. The approach: embed
zregexp as the actual `RegExp` backend inside Node.js via FFI and run the official,
unmodified test262 harness against it (full design in the approved plan file this phase
was scoped from). That requires the C API to actually be usable as a real `RegExp`
implementation, which it wasn't yet — hence Phase 0 below as this phase's prerequisite.

### Phase 0 (of this phase) — C API parity — ✅ DONE (2026-07-08)

The C API (`include/zregexp.h`/`.hpp`, `src/c_api.zig`) had fallen behind the pure Zig
API it wraps: no way to set `m`/`s`/`y`/`u`/`v` flags, no capture byte offsets, no named-
group enumeration, no position-parameterized matching, and `zregexp_replace` was still
literal-only with no all-matches equivalent at all. Closed all five gaps:

- `ZRegexOptions` gained `multiline`/`dot_all`/`sticky`/`unicode`/`v` bool fields
  (mirroring `CompileOptions` in `src/codegen/compiler.zig`), wired through
  `zregexp_compile`.
- `zregexp_match_capture_start`/`_end` and `zregexp_match_named_capture_start`/`_end`
  wrap `MatchResult.getCaptureIndices`/`getNamedCaptureIndices`, returning byte offsets
  (`ZREGEXP_NO_CAPTURE` = `SIZE_MAX` sentinel for "doesn't exist or didn't participate").
- `zregexp_named_group_count`/`_name`/`_index` enumerate a compiled pattern's named
  groups without needing a name in hand (`re.compiled.named_groups`), needed to build a
  JS-style `match.groups` object from the outside.
- `zregexp_find_at` wraps `Regex.findAt` for `lastIndex`-driven `exec()` semantics.
- `zregexp_replace` was rewritten to call the Zig `Regex.replace` (which already supports
  `$$`/`$&`/`` $` ``/`$'`/`$1`-`$99`/`$<name>` substitution, added in Phase 7) instead of
  reimplementing literal-only replacement in C; a new `zregexp_replace_all` wraps
  `Regex.replaceAll`. This also deleted ~50 lines of duplicated find-all-and-splice logic
  that's now just two thin wrapper calls.

**Bug found and fixed along the way**: `zregexp_match_group`'s doc comment always said
`group_index=0` returns the full match, but the implementation silently returned `NULL`
for index 0 unconditionally — verified with a standalone C probe before the fix (`(a)(b)`
matched against `"ab"`, `zregexp_match_group(match, 0)` returned `NULL` instead of
`"ab"`). Root cause: the internal `captures` array is 1-indexed by capture-group number
(group numbering starts at 1 in the parser; slot 0 is never written by any `SAVE_START`/
`SAVE_END`), so `getCapture(0, ...)`/`getCaptureIndices(0)` always read an always-invalid
slot. Fixed by special-casing `group_index == 0` in `zregexp_match_group` and the two new
`zregexp_match_capture_start`/`_end` functions to read `match.result.start`/`.end`/
`.group()` directly instead of going through the 1-indexed capture lookup. This bug
predates this session's work — it was latent in the original C API — but was only
discovered because building `match.indices[0]` support (needed for the harness's `d`-flag
shim) required actually exercising index 0 for the first time.

Verified (at the time) via the C-binding smoke test, `examples/cpp_example.cpp` (extended
with a new "Example 11" exercising named groups, capture indices, `findAt`, and
`replaceAll`), manually compiled with `g++ -std=c++17` against the freshly built shared
library and run — plus a standalone C probe isolating the `group(0)` bug before/after the
fix. Full `zig build test`/`examples`/`test-conformance`/`build` all still passed
(402/402 unit/integration tests, 168/168 conformance sample, clean build).

### Follow-up, same session — public C/C++ support dropped (2026-07-08)

Immediately after the parity work above landed, explicit user direction: stop
maintaining a public C/C++ surface at all. Every Zig-side feature this whole plan adds
had been requiring five parallel updates (`src/c_api.zig`, `include/zregexp.h`,
`include/zregexp.hpp`'s C++ RAII wrapper, `examples/cpp_example.cpp`, and doc sections in
two READMEs) just to stay in sync — a real, recurring maintenance tax the parity work
above made concrete, unrelated to the actual goal of this plan (JS conformance). Decision:
zregexp is Zig-first; `include/zregexp.h`, `include/zregexp.hpp`, and
`examples/cpp_example.cpp` were **deleted**, and `build.zig` no longer builds a static
library or installs headers (removed the `lib`/`static` steps and the two
`addInstallHeaderFile` calls). `src/c_api.zig`'s exported C ABI itself is **kept
unchanged** — it's still built via `zig build shared` — because it's exactly the FFI
substrate Phase A below needs to drive zregexp from Node.js; it's just no longer
presented, documented, or verified as a supported *public* interface. Anyone wanting to
call zregexp from C/C++ externally would need to write their own bindings against those
exported symbols. `docs/KNOWN_LIMITATIONS.md` and both READMEs updated accordingly; full
`zig build test`/`examples`/`test-conformance`/`build` re-verified clean after the
`build.zig` changes (402/402, 168/168, clean build, no static lib or `zig-out/include`
produced anymore).

**Not yet started**: Phase A (the actual harness — Node + `koffi` FFI + a JS-literal-to-
`new RegExp()` AST transform + the official `test262-harness` package pointed at a real
test262 checkout), and everything downstream of it (Phase B: triage real gaps from real
failure data; Phase C: iterate to 100% or an explicitly documented architectural limit).
See the approved plan file for the full design of those phases — they're substantial,
multi-session-scale work, deliberately not pre-planned in detail here until Phase A's
real data exists to drive prioritization.

**Size**: Phase 0 was S (a few hours). Phase A is L+; Phase B/C are unknown until Phase A
reports real numbers.

---

## Suggested sequencing

```
Phase 0 (bug fixes)  ──┐
                       ├─→ Phase 6 (test262 harness) starts here, runs continuously
Phase 1 (Unicode core) ┘
        │
        ├─→ Phase 2 (named groups)         [independent, can run in parallel with Phase 1]
        ├─→ Phase 3 (\p{} properties)      [needs Phase 1]
        │        └─→ Phase 4 (case folding) [reuses Phase 3's UCD tooling]
        └─→ Phase 5a (y, d flags)          [independent]
                 Phase 5b (u flag)          [needs Phase 1, Phase 3]
                          Phase 5c (v flag) [needs Phase 5b — hardest, do last]
                                   │
                                   └─→ Phase 7 (docs + API parity, closes the loop)
```

Phases 0, 1, 2, 5a, and 7 are done. Phase 3 is fully done, including `\p{...}`/`\P{...}`
General_Category support, 50 binary properties (including Emoji, Bidi_Mirrored, and
Assigned), all 174 Unicode scripts via `\p{Script=...}`/`\p{sc=...}`, their short
aliases (`\p{Script=Grek}`), Script_Extensions
(`\p{Script_Extensions=...}`/`\p{scx=...}`), and `\p{...}`/`\P{...}` as a
character-class member (`[\p{L}\d]`, `[^\p{L}\d]`) — the "blocked on UCD data"
assessment turned out to be wrong (this environment does have network access to
unicode.org; see Phase 3's notes above for what actually happened). Phase 6 (test262
harness) is stood up, running, and at 168/168 (100%) on its sample. Phase 7's
`replace()`/`replaceAll()` also gained `$1`/`$&` substitution as a same-session
follow-up.

Phase 4 is also now mostly done: case folding for a literal non-ASCII character
(standalone or as a single character-class member) is implemented, contrary to the
original "needs an AST redesign first" assessment — the actual fix turned out to be a
one-field, one-call-site addition to the existing `.sequence`-of-raw-bytes
representation, not a representation overhaul (see Phase 4's notes above for what
changed and why the original blocker turned out smaller than expected). Phase 5b (`u`
flag) shipped its first slice too: `CompileOptions.unicode` now rejects an unrecognized
escape as a compile error (see Phase 5b's notes above for the two real bugs — `\v`/`\f`
never being recognized at all, and a lookahead-mode interaction in `parseCharClass` —
found and fixed while building it). Phase 2's one deferred gap is closed too: duplicate
named groups across mutually exclusive alternation branches (`(?<x>a)|(?<x>b)`) now
compile, matching JS exactly instead of the "reject unconditionally" subset originally
shipped — see Phase 2's follow-up notes above for the branch-path-tracking mechanism
and the two bugs (a duplicate-name-lookup bug in `getNamedCapture`/`$<name>`, and a
memory-leak-shaped design mistake) found and fixed while building it. Phase 5c (`v`
flag), the one item this whole plan always flagged as "genuinely hard, do last," also
shipped a real (if deliberately narrow) slice: `CompileOptions.v` plus exactly one
character-class set operation per class (`[A--B]`/`[A&&B]`, no chaining, no deep
nesting) — see Phase 5c's notes above for the match-time-evaluation design (needed to
avoid materializing a property like `\p{L}`'s ~700 ranges) and the four parser bugs
(double-free, two lexer-mode-timing bugs, and a double-counted negation) found and
fixed while building it.

**What's left**: four items, all follow-ups to already-shipped (if partial) phases
rather than blocked from the start:

- Phase 4's remaining gap — non-ASCII character *ranges* (`[À-Ö]`) and `\p{...}`-in-a-
  class members still aren't case-folded, each for a different, genuine reason (a range
  isn't a uniform offset the way ASCII is; a property is a whole set of codepoints with
  no single case pair to add) — see Phase 4's notes above.
- Phase 5b's remaining gap — malformed `\x`/`\u`/`\c`/`\k`/`\p` and backreferences to
  nonexistent groups still aren't strict under `unicode = true`; both need
  whole-pattern context (how many groups exist, whether any are named) rather than the
  purely local, pattern-context-free rule this pass implemented — see Phase 5b's notes
  above for why that distinction mattered for scoping this pass.
- Phase 5c's remaining gap — operator chaining/deep nesting (a scope decision, not a
  blocker — the recursive `parseCharClass` structure could likely support it, but
  wasn't tested that far), `\q{...}` multi-string literals, and `v`'s own additional
  reserved-punctuator rules beyond `u`'s — see Phase 5c's notes above.
- Full `u`-mode strictness (both Phase 5b's own remaining gap and the prerequisite for
  `v` to be spec-complete) remains the largest coherent chunk of gap-closing work left,
  though it's now properly Phase B/C work under Phase 8 (see below) — closed only once
  real test262 data says it's worth prioritizing, not on assumption.
- Phase 8's Phase A: building the real test262 conformance harness (Node + FFI shim +
  literal-to-constructor transform + the official `test262-harness` package). This is
  the actual current next step — see Phase 8 above. Everything else in this list becomes
  a Phase B candidate once Phase A produces real failure data, rather than being worked
  on speculatively.
