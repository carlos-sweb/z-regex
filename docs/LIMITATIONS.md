# Limitations - zregex

What zregex does and doesn't do **today**, as of 0.8.0 (the API freeze of 0.7.0, plus T0 throughput and T0's DFA).
Each entry was checked against the code, its tests or V8 (Node 22). How each item got here, phase by phase, is in [HISTORY.md](HISTORY.md);
what a release promises is in [API.md](API.md).

## Status

- **test262:** 3087 of the 3110 entries that run pass (99.3 %), in UTF-16 and in WTF-8;
  728 are skipped: 509 by the harness (its runner, or a feature its Node lacks, such as
  the 377 of RegExp modifiers) and 219 of the `v` flag (`scripts/test262/features.json`).
  Of the `v` flag's 314 entries, the 93 of the engine suite that pass run
  (`v-subset.json`); the rest: 192 `UnsupportedFeature` (F5c), 26 the laxity under `v`
  (below), 1 host, and 2 of the host suite
  (they pass; that suite isn't in the count). Of the 23 that run and don't pass: 4 are lookbehinds
  zregex rejects as `UnsupportedFeature` (2 `nested-lookaround`, 2 under `u` in
  `named-groups/lookbehind`), 4 fail in the JS lexer (host), 15 can't be extracted.
- **Against V8:** `zig build differential-v8` (4,000 generated patterns), `lbdiff-v8`
  (5,580 patterns with a lookbehind) and `ivdiff` (1,059 patterns with `i` and `v`) give
  no pattern with a different result: every difference is `UnsupportedFeature`.
- **The C API** exports 40 `zregex_*` symbols (`zig build shared`).

## The rule: honest errors

Valid syntax that zregex doesn't implement is `error.UnsupportedFeature` (C:
`ZREGEXP_ERROR_UNSUPPORTED`, 9), never a wrong result and never a SyntaxError name. A later
release only removes such cases ([API.md](API.md), "Errors").

### Not implemented: `UnsupportedFeature`

| What | Example | Plan |
|---|---|---|
| RegExp modifiers (ES2025) | `(?i:a)`, `(?-m:a)` | Pending until further notice (see below) |
| A lookaround inside a lookbehind matched backward | `(?<=a(?=b)c+)` | 1.x |
| Under `u`/`v`, a lookbehind matched backward (variable length, captures or backreferences inside) | `/(?<=a+)b/u` | 1.x |
| `v`: `\q{...}` | `[\q{abc}]` | F5c (1.x) |
| `v`: a bare character or shorthand as the right operand (bug B) | `[\p{L}--a]`, `[a--b]`, `[\w--\d]` | F5c (1.x) |
| `v`: a chain of one operator | `[A--B--C]`, `[A&&B&&C]` | F5c (1.x) |
| `v`: a union with nested classes | `[[a][b]]`, `[a[b]]` | F5c (1.x) |
| `v`: properties of strings | `\p{RGI_Emoji}` and 6 more | F5c (1.x) |
| `i` with `v`: property escapes, negated classes and set operands not closed under the folding | `/\p{Lu}/iv`, `/[^a-z]/iv`, `/[[a-z]--[q]]/iv` | F5c (1.x) |

### Row by row: `v`, modifiers and escapes

Each row: what V8 says, what zregex gave before E0 (0.5.1), and what it gives now
(F7c-4b's rows included).

| Pattern | V8 | Before E0 | Since E0 |
|---|---|---|---|
| `[\q{a}]` (`\q{...}`) | valid | **wrong result**: `\q` was the letter q | `UnsupportedFeature` |
| `\q`, `[\q]`, `\q{a}`, `\z` | SyntaxError | accepted | `InvalidEscape` |
| `[\p{L}--\d]`, `[\p{L}--a]`, `[a--b]`, `[a&&b]`, `[[a]&&b]`, `[\w--\d]` (a bare right operand, bug B) | valid | `InvalidClassSetOperand` | `UnsupportedFeature` |
| `[[a][b]]`, `[a[b]]` (a union with nested classes) | valid | `InvalidClassSetOperand` / `UnexpectedToken` | `UnsupportedFeature` |
| `[A--B--C]`, `[A&&B&&C]` (the same operator chained) | valid | `ChainedClassSetOperatorNotSupported` | `UnsupportedFeature` |
| `[A--B&&C]` (operators mixed) | SyntaxError | `ChainedClassSetOperatorNotSupported` | `MixedClassSetOperators` (flat operands too since F7c-4b) |
| `[ab&&[c]]`, `[a-z--b]` (a list or a range as an operand) | SyntaxError | compiled / `UnsupportedFeature` | `InvalidClassSetOperand` (F7c-4b) |
| `[a--]`, `[--a]` | SyntaxError | `InvalidClassSetOperand` | the same |
| `\p{RGI_Emoji}` and the other 6 properties of strings | valid | `UnknownUnicodeProperty` | `UnsupportedFeature` |
| `\P{RGI_Emoji}`; those names with `u` | SyntaxError | `UnknownUnicodeProperty` | the same |
| `(?i:a)`, `(?-m:a)`, `(?i-s:a)` (RegExp modifiers, any flags) | valid (ES2025) | `UnexpectedToken` | `UnsupportedFeature` |
| `(?x:a)`, `(?i)`, `(?ii:a)`, `(?-:a)` | SyntaxError | `UnexpectedToken` | the same |

- **An operand of `--`/`&&` is one character, `\p{…}`, shorthand or nested class.**
  ECMA-262 (`ClassSetOperand`) and V8 agree: a list or a range is only a `ClassUnion`, so
  `[a-z--b]` is a SyntaxError and the range is written nested, `[[a-z]--b]`.
- **Limit of the rule:** a pattern that is invalid *and* uses a form that isn't implemented
  reports the first one it reaches: `[A--\d]\w(?!a){2}` with `v` is `UnsupportedFeature`
  (the class comes first), where V8 reports the SyntaxError of the quantified lookahead.
  Both are compile errors; neither is a wrong result.

## Known divergences from V8

- **Still accepted under `v`, V8 rejects** (for 1.x, with bug B and chaining): an
  unescaped ClassSetSyntaxCharacter (`[(]`) and the reserved double punctuators
  (`[a!!b]`).
- **V8 matches inside a surrogate pair under `u`/`v`.** With `u`/`v` and a search that
  passes over a surrogate pair, V8 reports a match at the position between the pair's two
  units, which the spec doesn't require: under `u`/`v` the input is a list of code points
  and no position falls inside one. zregex follows the spec; not fixed. Found by the
  lookbehind differential of F6b's precheck (F2c corpus, UTF-16), four patterns, all
  zero-width at that position:

| Pattern | Subject, `lastIndex` | V8 | zregex |
|---|---|---|---|
| `/(?<!a)/v` | `"a𝌆bé"`, 1 | `[2,2]` | `[3,3]` |
| `/[0-9a]ß\|(?<n0>(?<!^))+?/mv` | `"😀x😀"`, 0 | `[1,1]` | `[2,2]` |
| `/é*(…){0,1}?(?<!(?<=\S))/mu` | `"😀x😀"`, 2 | `[4,4]` | no match |
| `/\B(?<![^\sa]😀\*[^z])/v` (also `/\B/v`) | `"😀x😀"`, 2 | `[4,4]` | `[5,5]` |

- **`\p{ASCII}` and the Kelvin sign under `iv`:** see "`v` with `i`" below.

## Lookbehind

**What it covers.** Every lookbehind outside `u`/`v` except one with a lookaround inside a
body matched backward:

| Lookbehind | How it runs | Since |
|---|---|---|
| Fixed length, no capture group inside | Forward from `L` characters back (`LOOKBEHIND_FIXED L`); LookLinear may delegate it | B′ (0.5.0), any mode |
| Variable length, no capture group or backreference inside | Backward: body in reverse, backward atoms | F6b(1), commit a |
| With capture groups inside (fixed length or not) | Backward; a group saves its end first | F6b(2), commit b |
| With backreferences inside | Backward; the group's text compared right to left | F6b(3), commit c |

**What it doesn't cover (`error.UnsupportedFeature`, never a wrong result).**
- **A lookaround nested inside a lookbehind matched backward** (B6): `(?<=a(?=b)c+)`,
  `nested-lookaround.js`. A 1.x decision. A lookaround inside a fixed lookbehind (B′,
  forward) runs, and so does a backward lookbehind inside a fixed one (`(?<=a(?<=b+))`: the
  outer runs forward, the inner backward, with different barriers; covered by the
  differential).
- **Any lookbehind matched backward under `u`/`v`** (variable length, captures or
  backreferences inside): `(?<=a+)b/u`, `named-groups/lookbehind.js`. Under `u`/`v` only
  B′'s form runs.

**How it works (architecture B, chosen by E1's spike P3).** The code generator emits a
backward body in reverse (sequences, literals; a group as `SAVE_END`, body, `SAVE_START`)
and turns each of its atoms into its backward form, the same opcode with the high bit set
(`CHAR_B` = `CHAR | 0x80` … `BYTE_B`, and `BACK_REF_B` / `BACK_REF_I_B`; same operands). A
backward atom tests the character before the position (`matchSingleInstructionBack`,
`Subject.decodeBefore`) and moves to its start; the star's fast paths (`consumeAll`,
`star_lazy`) consume right to left; `checkBackRefBack` compares a group's text from its end
to its start against the text before the position, decoding each side on its own (under
`i`, equal characters of different lengths in WTF-8 compare: U+2C65 is three bytes, U+023A
two). `LOOKBEHIND` / `NEGATIVE_LOOKBEHIND` open the same barrier as a lookahead and the body
may end anywhere before; the trail undoes a negative one's captures. No executor state
holds the direction, so the forward path doesn't test it per character: P3's callgrind was
within ±1 % on 16 cases for B, where direction as executor state (A) reached +1.84 %.
LookLinear doesn't delegate backward bodies (backward delegation is for 1.x). Captures come
out as the spec's backward matching gives them: `(?<=(\d+)(\d+))$` on `"1053"` gives
`"1"` and `"053"`; a group to the right of a backreference is matched first, and one that
hasn't participated yet matches empty (`(?<=(\w)\1)x` on `"aax"` gives `[2,3]`, V8 too).

## RegExp modifiers (ES2025)

`(?i:…)`, `(?-m:…)` and the other forms of ES2025's modifiers are not implemented:
`(?i:a)` is `error.UnsupportedFeature`. Decision (2026-09-29): pending until further
notice, not on the way to 1.0. Their 377 test262 entries are skipped because the
harness's Node lacks the feature, so they are not counted in 3087/3110. What exists and
what is missing: `docs/plans/F7.md`, "Decisiones", 4.

## `v` with `i`

Up to 0.6.0, under `v` with `i` sets folded with the pre-F5b rule (ASCII letters and a
literal's simple pair): a silent wrong result, which the freeze doesn't allow. Since F7c-0:
- **Literals and classes fold as under `iu`** (F5b's `unicode` folding, the long s and the
  Kelvin sign included): `/[a-z]/iv` matches U+212A and U+017F, `/k/iv` the Kelvin sign,
  `/σ/iv` "ς", `/ß/iv` "ẞ", `/[\w]/iv` "ſ". `\b` already used the extended WordCharacters.
- **`error.UnsupportedFeature`** where `v`'s MaybeSimpleCaseFolding differs from `iu` or
  might (F5c, 1.x):
  - every property escape, `\p{...}` or `\P{...}`, alone, in a class or in a set
    operation. Under `v`, `\P{Lu}` complements after folding (V8: `/\P{Lu}/iv` doesn't
    match "a", `/\P{Lu}/iu` does);
  - a negated class whose members aren't closed under the folding (`[^a-z]`);
  - a set operation (`--`, `&&`) with an operand that isn't closed under the folding
    (`[[a-z]--[q]]`). Closed operands fold to themselves, so `[[0-9]--[5]]` still runs.
- **`\p{ASCII}` and the Kelvin sign:** V8 doesn't match U+212A with `/\p{ASCII}/iv`
  (it does with `iu`, and with `/[a-z]/iv`). By our reading of the spec (MaybeSimpleCaseFolding,
  Canonicalize) it should. V8 is the reference; revisit in F5c if the spec says otherwise.
  Under `iv` the property is `UnsupportedFeature`, so the difference can't show.

## What works

| Feature | Status |
|---|---|
| Syntax | ECMA-262 RegExp, with Annex B's extensions without `u`/`v` (`{,5}` and a lone `]` as text, legacy octal, `\c` as text when invalid) |
| Flags | `i`, `m`, `s`, `y`, `u`, `v` (see the tables above); `d` is `getCaptureIndices`/`execAt`'s slots, `g` is `findAll`/`iterator`/`execAt` |
| Quantifiers | greedy, lazy, counted; possessive `*+`, `++`, `?+` as an opt-in extension (`CompileOptions.possessive`) |
| Groups | capturing, non-capturing, named; duplicate names in mutually exclusive alternatives; up to 65,535 groups |
| Backreferences | `\1`…, `\k<name>` (to every group of a duplicated name) |
| Lookahead | every form, captures included |
| Lookbehind | see "Lookbehind" above |
| Classes | ranges, shorthands and properties as members, negation, `[]` and `[^]`; under `v`, one set operation `--`/`&&` per class |
| `\p{…}` / `\P{…}` | every UCD 17.0.0 name: General_Category, the binary properties, `Script`/`sc` and `Script_Extensions`/`scx` with their aliases |
| Case folding | `i`: ECMA-262's Canonicalize (`toUppercase` without `u`, simple case folding with `u`), in literals, classes, ranges, properties, `\w`, `\b` and backreferences; `iv` as above |
| Subjects | WTF-8 (bytes, lone surrogates allowed) and UTF-16 (code units), indices in the subject's units (`Subject`, `execAt`) |
| Replacement | `replace`/`replaceAll` with `$1`…`$99`, `$&`, `` $` ``, `$'`, `$$`, `$<name>` |

## Limits

| Limit | Value | Error |
|---|---|---|
| Nesting of groups, lookarounds and classes | 256 levels | `NestingTooDeep` (compile) |
| Capture groups | 65,535 | `TooManyCaptures` (compile) |
| Compiled program | 16 MiB of bytecode | `PatternTooLarge` (compile) |
| Backtracker steps | `ExecLimits.max_steps`, 1,000,000 by default, **per start position** | `StepLimitExceeded` |
| Backtracker stack (choicepoints, capture trail, loop guards) | `ExecLimits.max_backtrack_stack_bytes`, 64 MiB by default | `BacktrackStackExhausted` |
| LookLinear memo | `ExecLimits.max_memo_bytes`, 1 MiB by default | none: the lookahead runs without memo |

- **Which patterns can take exponential time:** only the ones the backtracker runs
  (backreferences, lookarounds, and what T0's VM doesn't take yet). T0's VM runs in
  O(subject × pattern). The step budget bounds the backtracker per start position, so a
  search over a subject of `n` positions can take up to `n × max_steps` steps; the budget
  is per start position on purpose (D11): a budget per execution would fail long subjects
  that match correctly.
- Parsing 256 nested levels fits in a 1 MiB stack in every build mode (~0.5 KiB a level
  in ReleaseSafe, ~1.7 KiB in Debug). Matching doesn't use the native stack.

## Using the API

- **`test_()` is not a search:** it takes the match that starts at 0 and asks whether it
  reaches the end of the input. `regex.test_(allocator, "\\d+", "Price: 42")` is `false`.
  To ask whether the pattern appears anywhere, use `find()` or `findAll()`. Since it looks
  at the first match only, `test_` with `a|ab` on `"ab"` is `false` (the match is `"a"`);
  anchor the pattern (`^(?:a|ab)$`) to ask for a full match.
- **Byte offsets.** The facade (`find`, `findAll`, `MatchResult`) gives byte offsets into
  the input; `execAt` and `iterator` give offsets in the `Subject`'s units (bytes in
  WTF-8, code units in UTF-16). `lastIndex`, `exec` arrays and `Symbol.replace` belong to
  the host.
- **The C API** (`src/c_api.zig`, `zig build shared`) is stable for FFI consumers such as
  this repository's test262 harness: its 40 symbols, `ZRegexOptions`'s layout and the
  error codes follow [API.md](API.md). It is not a documented public C API: there is no
  header, and callers declare the functions themselves from `src/c_api.zig`.

## Confirmed bugs

None open.
