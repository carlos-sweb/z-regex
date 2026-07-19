# Known Limitations - zregex

This document describes the current, **verified** limitations and known issues in the
zregex regex engine. Every claim below was checked by direct execution against the
current source tree (compiling small probe programs against the `zregex` module and
observing the actual result), not inferred from design docs or past status reports.

## Version: 402/402 unit/integration tests passing, 168/168 (100%) on a test262-derived
conformance sample (Phases 0, 1, 2 (now including duplicate named groups across
mutually exclusive alternation branches, e.g. `(?<x>a)|(?<x>b)`, matching JS exactly),
3 (including `\p{...}` General_Category support, 50 binary properties incl.
Emoji/Bidi_Mirrored/Assigned, all 174 Unicode scripts via `\p{Script=...}`, their short
aliases via `\p{Script=Grek}`, Script_Extensions via
`\p{Script_Extensions=...}`/`\p{scx=...}`, and `\p{...}`/`\P{...}` as a character-class
member, e.g. `[\p{L}\d]`), 4 (case_insensitive folding of a literal non-ASCII
character's simple case pair, standalone or as a single class member — non-ASCII
*ranges* and `\p{...}`-in-a-class members still don't fold), 5a, 5b (`CompileOptions.unicode`
now rejects an unrecognized escape as `error.InvalidEscape`; malformed `\x`/`\u`/`\c`/
`\k`/`\p` and bad backrefs still lenient), 5c (`CompileOptions.v` now supports one
character-class set operation per class, `[A--B]`/`[A&&B]`; no chaining/deep nesting,
`\q{...}`, or full `u` strictness yet), the Phase 6 character-class gaps and
backtracking-correctness fixes, and Phase 7's `replace()`/`replaceAll()`, including
`$1`/`$&` substitution, complete — see
[ECMASCRIPT_COMPATIBILITY_PLAN.md](ECMASCRIPT_COMPATIBILITY_PLAN.md)). **100% on this
168-case sample is not 100% JS RegExp compatibility** — see "test262 conformance sample"
below for exactly what this measures and its known biases.

---

## What works

The following are confirmed working correctly by direct testing, including cases that
older internal notes had previously (incorrectly) listed as broken:

- **Backreferences** `\1`-`\9` — e.g. `(\w+) \1` correctly matches `"hello hello"` and
  rejects `"hello world"`.
- **Alternation** `a|b` — no infinite loop; correctly matches either branch.
- **Lookahead** `(?=...)`, `(?!...)` and **lookbehind** `(?<=...)`, `(?<!...)` — all four
  forms are zero-width and behave correctly (verified with `find`, not `test_`, since
  these assertions don't consume input — see the `test_` vs `find` note below).
- **`\W`, `\S` negation** — correctly inverted (an older internal note claimed these were
  "parsed but not correctly inverted"; that is no longer true).
- **Counted quantifiers** `{n}`, `{n,}`, `{n,m}` and their lazy forms `{n,m}?`.
- **Possessive quantifiers** `*+`, `++`, `?+` — verified non-backtracking (`a++a` correctly
  fails to match `"aaaa"` because the possessive `a++` consumes all four `a`s and refuses
  to give any back).
- **Character classes** `\d \D \w \W \s \S`, `[abc]`, `[^abc]`, `[a-z]`.
- **`\s`/`\S` include `\f` (form feed) and `\v` (vertical tab)** *(bug found and fixed in
  Phase 6)* — the standalone-atom code path's comment already said `\s is [ \t\n\r\f\v]`
  but the implementation only ever included space/`\t`/`\n`/`\r`, silently dropping the
  other two. Fixed by introducing shared `DIGIT_RANGES`/`WORD_RANGES`/`WHITESPACE_RANGES`
  byte-range tables in `src/parser/parser.zig`, used by both the standalone shorthand atoms
  and the new shorthand-as-class-member handling below, so both stay in sync.
- **Anchors** `^`, `$`, `\b`, `\B` (string-level; see the multiline caveat below).
- **`case_insensitive` option** — works correctly for ASCII letters.
- **`findAll`** — returns all non-overlapping matches correctly.
- **ReDoS protection** — verified with the classic catastrophic pattern `(a+)+b` against
  40 `a`s followed by a non-matching character: the engine returns
  `error.StepLimitExceeded` in under 0.2s instead of hanging. The step limit and
  recursion-depth limit (`max_steps`, `max_recursion_depth` in `CompileOptions`) are real
  and enforced in `src/executor/recursive_matcher.zig`.
- **`multiline` option** *(fixed in Phase 0)* — `^`/`$` now anchor at line boundaries
  (after/before `\n`) when set, via a new `LINE_START`/`LINE_END` vs. `STRING_START`/
  `STRING_END` opcode split (`codegen/generator.zig`, `executor/recursive_matcher.zig`).
- **`dot_all` option and default dot-vs-newline** *(fixed in Phase 0)* — `.` now excludes
  `\n` by default (matching JS) and only matches it when `dot_all = true`.
- **Escapes `\xHH`, `\uHHHH`, `\u{H+}`, `\0`, `\cX`** *(fixed in Phase 0)* — all decode to
  the correct byte/code point instead of being read as literal characters. `\u{H+}` code
  points above `0x7F` are UTF-8-encoded and expanded into an atomic multi-byte sequence, so
  `\u{1F600}+` correctly repeats the whole 4-byte emoji, not just its last byte.
- **Invalid quantifier ranges** *(fixed in Phase 0)* — `{n,m}` with `n > m` (e.g. `a{2,1}`)
  is now a compile-time `error.InvalidQuantifier`, matching JS's `SyntaxError`.
- **`.` consumes one Unicode scalar value, not one byte** *(fixed in Phase 1)* — `^.$`
  now matches a single 2-byte character like `é` or a 4-byte emoji like 😀 in one step
  (`^..$` correctly does *not* match a single `é`). Implemented via a new `CHAR_ANY`
  opcode (dot with `dot_all`) and by making the existing `CHAR` opcode (dot without
  `dot_all`) decode a full UTF-8 sequence at match time instead of one byte
  (`src/executor/recursive_matcher.zig`). Falls back to matching exactly 1 byte if the
  input isn't valid UTF-8 at that position, so non-UTF-8/binary input doesn't error.
- **Negated character classes consume one Unicode scalar value** *(fixed in Phase 1)* —
  `\W`, `\S`, and `[^...]` now correctly match (and fully consume) a whole non-ASCII
  character as a single unit, the same fix applied to `CHAR_RANGE_INV`/`CHAR_CLASS_INV`.
- **Literal multi-byte characters in a pattern quantify as one atomic unit** *(fixed in
  Phase 1)* — a literal `é` (2 UTF-8 bytes) directly in a pattern now tokenizes as one
  unit, so `é+` correctly repeats the whole character (previously `+` only applied to
  the second byte, and could even match stray continuation bytes as if they were more
  `é`s). Implemented in the lexer (`src/parser/lexer.zig`), reusing the same
  "decode to a `sequence` of byte nodes" mechanism built in Phase 0 for `\u{H+}` escapes.
- **Named capture groups `(?<name>...)` and `\k<name>` backreferences** *(added in
  Phase 2)* — `(?<year>\d+)` compiles, and `MatchResult.getNamedCapture("year", input)`
  retrieves it; named groups are still numbered like ordinary groups (`getCapture(1, ...)`
  works too). Duplicate names are rejected (`error.DuplicateGroupName`) *unless* every
  occurrence is in a mutually exclusive alternation branch, matching JS exactly — see
  the dedicated bullet below for how that's determined. An unresolvable `\k<name>` is
  `error.UnknownGroupName`; a bare `\k` not followed by a valid `<name>` falls back to a
  literal `k` (Annex-B-style leniency, like `\x`/`\u`/`\c` when malformed).
- **Literal `-` outside a character class** *(bug found and fixed while verifying Phase
  2)* — `555-1234` previously failed to compile at all (`error.UnexpectedToken`): the
  lexer always tokenizes `-` as `.hyphen` (used for character-class ranges) with no notion
  of "inside a class," and the parser only ever handled `.hyphen` inside
  `parseCharClass`, never as a plain atom. Fixed by treating `.hyphen` as a literal `-`
  character in `parseAtom`.
- **Character classes can contain multi-byte members and ranges** *(added in Phase 3)* —
  `[é]`, `[a-\u{2FF}]`, `[\u{1F600}-\u{1F64F}]` (and negated forms, `[^...]`) now work
  correctly, including with quantifiers (`[é]+`). New `CHAR_CLASS_RANGES`/
  `CHAR_CLASS_RANGES_INV` opcodes hold up to `opcodes.MAX_CLASS_RANGES` (8) code-point
  ranges and decode UTF-8 at match time; classes with only byte-range (≤ U+007F) members
  still use the original 256-bit bitmap opcodes, unchanged. A class needing more than 8
  ranges is a compile-time `error.TooManyRanges` rather than a silent truncation. This
  closes out the character-class work Phase 1 deliberately deferred (see Phase 1's notes
  in the compatibility plan).
- **`sticky` option (JS `y` flag)** *(added in Phase 5a)* — `CompileOptions{ .sticky =
  true }` makes `find` only match starting exactly at position 0 (no scanning ahead), and
  makes `findAll` stop at the first non-matching position instead of skipping past it.
  New `Regex.findAt(input, pos)` / `Matcher.findAt` primitive underlies this and is also
  public on its own, for manually resuming iteration from a caller-tracked position (the
  Zig equivalent of tracking `lastIndex` in JS).
- **Capture indices (JS `d`/`hasIndices` flag equivalent)** *(added in Phase 5a)* —
  `MatchResult.getCaptureIndices(index)` / `getNamedCaptureIndices(name)` return the
  `{start, end}` byte offsets of a capture. There's no `has_indices` `CompileOptions`
  field: captures already track their positions internally regardless, so gating this
  behind a flag (the way JS does, since JS's flag is a real memory/perf trade-off in a
  JIT-compiled engine) would only add API surface without saving anything here.
- **Quantified backreference to an empty capture no longer crashes** *(fixed in Phase 6)*
  — `/(a*)b\1+/.exec("baaac")` (a real test262 case, `S15.10.2.9_A1_T5.js`) used to
  **segfault the process** with the default `ExecOptions` (`max_recursion_depth = 1000`),
  not return a graceful error. Root cause: `isStarConsumePath` (the heuristic that
  recognizes a `SPLIT` as a bounded quantifier loop so it can be handled by the iterative,
  zero-width-progress-guarded `matchStarGreedy`) didn't recognize `BACK_REF`/`BACK_REF_I`
  as a quantifiable atom, *and* only recognized the `X*`-shaped bytecode
  (`SPLIT; X; GOTO back`), not the `X+`-shaped bytecode (`X; SPLIT_GREEDY back`) that
  `generatePlus` actually emits. Both gaps sent `\1+` down the generic "regular
  alternation" recursion path, which has no protection against an atom that matches zero
  width — recursing 1000 times (the default limit) through that specific call chain
  overflows the native stack before the counter ever returns
  `error.RecursionLimitExceeded`. Fixed in `src/executor/recursive_matcher.zig`
  (`isQuantifiableAtomOpcode`, `isStarConsumePath`, `checkBackRef`). This was found by
  the test262 conformance sample below — the second real crash bug found in this project
  by systematic testing this way (the first was the `SPLIT` alternation infinite loop
  documented in project history, already fixed before this document existed).
- **test262-derived conformance sample** *(added in Phase 6)* — `zig build
  test-conformance` runs 168 cases heuristically extracted from real test262 RegExp test
  files (not hand-written by this project) and reports a pass rate: **168/168 (100%)** as
  of this writing (started at 141/168, 83.9%, with 13 compile errors; see the fixes below
  and "What we'd do differently" for how it got there). See "test262 conformance sample"
  below for what this number does and doesn't mean — it is not "100% JS compatible."
- **Case-insensitive character classes and ranges** *(fixed via test262)* — `/[a-z]+/i`
  now matches uppercase letters too, and `/[^o]/i` now excludes both `o` and `O`.
  `generateCharRange`/`generateCharClass` in `src/codegen/generator.zig` previously only
  applied `case_insensitive` to single-character literals (`generateChar`'s
  lowercase/uppercase `SPLIT` alternation trick); ranges and classes silently ignored the
  option. Fixed by having both paths add each ASCII letter's opposite-case bit to the
  underlying `BitTable` when `case_insensitive` is set.
- **A quantified/repeated capturing group's last successful iteration wasn't retained**
  *(fixed via test262)* — `/(123){1,}/.exec("123123")` matched the right *length* but
  captured `""` instead of `"123"`. Root cause: `SAVE_START`/`SAVE_END` mutate the shared
  `self.captures` array directly with no rollback, so when a quantifier's loop tries one
  more (ultimately failing) repetition before settling on the last successful count, that
  failed attempt's `SAVE_START` write (setting the capture's `start` to the failed
  attempt's position) was never undone — leaving a corrupted, zero-length capture behind.
  Fixed by having `SAVE_START`/`SAVE_END` snapshot the previous capture value and restore
  it if their own immediate continuation fails (`src/executor/recursive_matcher.zig`).
- **`*` and `?` on a capturing group (or any atom too complex for the internal
  fast-path heuristic) were not actually greedy** *(fixed via test262)* — `/(a)*/.exec("aa")`
  matched an empty string instead of `"aa"`, and `/(a)?a/.exec("aa")` matched `"a"` instead
  of `"aa"`. Root cause: `generateStar` literally had a `// Non-greedy for now` TODO left
  in since early development, emitting a `SPLIT` that tried "zero reps" *before* "loop
  body"; `generateQuestion` had the same problem (tried "skip" before "consume"). This was
  invisible for plain single-character atoms (`a*`, `a?`) because a separate optimization
  (`isStarQuantifier`/`matchStarGreedy` in `recursive_matcher.zig`) detects that specific
  bytecode shape and overrides it with correct, explicitly-greedy iteration — but that
  detection only recognizes a short list of single-instruction opcodes, so it silently
  never applied to a capturing group (which starts with a multi-instruction `SAVE_START`).
  Fixed by making `generateStar`/`generateQuestion` emit genuinely greedy-first bytecode
  (`SPLIT_GREEDY` with loop/consume tried first) so the plain backtracking fallback is
  correct on its own regardless of atom complexity; the old `?`-specific "try both branches
  and compare lengths" workaround in the matcher was removed as unnecessary (and was
  itself buggy: it always evaluated *both* branches against the same shared `self.captures`
  array before picking one, so the discarded branch's capture mutations could leak into
  the chosen result).
- **Lazy `.*?` (and any lazy quantifier) could never expand more than one iteration**
  *(fixed via test262)* — `/^.*?$/.exec("Hello World")` (or any input longer than 1
  character) returned no match at all. Root cause: `matchStarLazy`'s zero-width-progress
  guard compared `matched.end_pos` against `current_pos` *after* `current_pos` had already
  been overwritten with `matched.end_pos` on the line above — a copy-paste ordering bug
  that made the comparison trivially always-true, capping the loop at exactly one
  character regardless of input length. Fixed by moving the check before the update.
- **A capturing group nested inside a repeated group could leak a stale value across
  iterations** *(fixed via test262)* — in `/(z)((a+)?(b+)?(c))*/.exec("zaacbbbcac")`, the
  3rd outer iteration correctly declines to match `(b+)?` (no `b`s left), but its capture
  still read back `"bbb"` from the *previous* iteration instead of the spec-correct
  `undefined`, because skipping an optional atom never touches its capture slot at all —
  there's nothing to roll back. Fixed with a new `CLEAR_CAPTURE` opcode
  (`src/bytecode/opcodes.zig`) that `generateQuestion`/`generateLazyQuestion` emit for
  every capture group nested inside an atom, on the atom's "skip" path only (a `GOTO` past
  a small clear-block keeps the "consume" path from also hitting it).
- **A backreference to a group that never participated in the match failed outright
  instead of matching empty** *(fixed via test262)* — `/(a)?\1b/.exec("b")` should match
  (`\1` referencing the never-taken `(a)?` branch matches the empty string, per spec), but
  `checkBackRef` explicitly returned "no match" for any capture that wasn't `isValid()`.
  This is a real, independent spec deviation, not the same bug as the earlier "quantified
  backreference to an *empty-string* capture" crash fix (that capture *was* valid, just
  zero-length; this one is a capture that never ran at all). Fixed in
  `src/executor/recursive_matcher.zig::checkBackRef`.
- **A negative lookahead's own captures could leak out even when the assertion behaved
  correctly** *(fixed via test262)* — combined with the backreference fix above,
  `/(.*?)a(?!(a+)b\2c)\2(.*)/.exec("baaabaac")` still failed: an *earlier, abandoned*
  attempt at a different `(.*?)` length caused the lookahead's inner `(a+)b\2c` to
  genuinely succeed as a raw sub-match (setting capture 2), which is exactly what makes a
  *negative* lookahead's assertion fail — but per-instruction `SAVE_START`/`SAVE_END`
  rollback only undoes a mutation when its *own* immediate continuation fails, not when a
  sibling assertion later decides the whole sub-match should never have counted. Per the
  ECMAScript spec, a lookahead's captures are only ever observable afterward in exactly
  one case: a *positive* lookahead that *succeeds* (the well-known `/(?=(a))/.exec("a")`
  capturing `"a"` behavior). Fixed by snapshotting the full `captures` array before
  probing a lookahead's inner pattern and restoring it in every other outcome
  (`matchLookahead` in `src/executor/recursive_matcher.zig`).
- **Character classes treat regex metacharacters as literals** *(fixed in Phase 6)* —
  `[*&$]`, `[.]`, `[^]{2,3}` etc. now compile and match the literal characters, matching
  JS's "most metacharacters lose their special meaning inside `[...]`" rule. Fixed by
  giving the lexer a parser-toggled `in_char_class` mode (`nextInClass`/`parseClassEscape`
  in `src/parser/lexer.zig`): inside a class, only `]`, `-`, and `\` keep special meaning.
  The tricky part is the transition at `[`/`[^`: the token right after `[` is fetched in
  normal mode (so `^` is still recognized as the negation marker, which class-mode doesn't
  special-case), and if it turns out not to be `^`, the lexer is rewound to that token's
  start position and re-fetched in class mode (`parseCharClass` in `src/parser/parser.zig`).
- **Character classes can contain shorthand classes as members** *(fixed in Phase 6)* —
  `[a-c\d]`, `[\D]`, etc. now compile and match correctly. `parseCharClass` splices a
  shorthand's byte ranges directly into the enclosing class's children; a negated
  shorthand (`\D`/`\W`/`\S`) contributes its own complement ranges (via
  `complementByteRanges`) rather than flipping the enclosing class's `inverted` flag —
  this is what JS's own "union of ClassAtom sets, then apply outer negation" class
  semantics require, and it composes correctly regardless of whether the enclosing class
  itself is negated.
- **`[^]` (negated empty class) recognized as "match anything"** *(fixed in Phase 6)* —
  the JS idiom for "match any character including newline" now compiles and works. The
  parser's `EmptyCharClass` check now only rejects the non-inverted empty case (`[]`,
  still almost certainly a mistake); `src/codegen/generator.zig`'s `generateCharClass` was
  updated the same way, so an inverted empty class flows through to an all-zero-bitmap
  `CHAR_CLASS_INV` opcode ("not nothing" = everything).
- **`replace()`/`replaceAll()` in the pure Zig API** *(added in Phase 7)* —
  `Regex.replace(allocator, input, replacement)` replaces only the first match (JS
  `String.prototype.replace` with a non-global regex), and `Regex.replaceAll` replaces
  every match (JS `.replaceAll`, or `.replace` with `/g`). Both allocate and return a new
  string (a plain copy of `input` if there's no match).
- **`$1`-`$99`, `$&`, `` $` ``, `$'`, `$$`, `$<name>` replacement substitution** *(added
  after Phase 7)* — `replace`/`replaceAll`'s `replacement` argument now supports JS's
  full substitution syntax (`expandReplacement` in `src/regex.zig`), not just literal
  text: numbered groups (two-digit tried first, per spec), the whole match, the
  before/after portions, a literal `$`, and named groups. A group that exists in the
  pattern but didn't participate in the match substitutes as an empty string; a `$N`/
  `$<name>` that doesn't correspond to any group in the pattern at all is left as literal
  text (matching JS exactly — it does *not* raise an error). `Regex`/`CompileResult`
  gained a `group_count: u8` field to make that "exists vs. didn't participate"
  distinction possible.
- **`src/c_api.zig`'s exported C ABI reached parity with the Zig API, then C/C++ was
  dropped as a supported public target** *(both later session, Phase 0/8 of the
  100%-conformance plan)* — `ZRegexOptions` gained `multiline`/`dot_all`/`sticky`/
  `unicode`/`v` fields, `zregex_replace`/`zregex_replace_all` gained the same
  `$1`/`$&`/`` $` ``/`$'`/`$<name>` substitution as the Zig `replace`/`replaceAll`, and
  new capture-index/named-group-enumeration/`find_at` functions were added, all to make
  the exported symbols usable as a real `RegExp` backend for the planned test262
  conformance harness (see Phase 8 in `ECMASCRIPT_COMPATIBILITY_PLAN.md`). **Bug found
  and fixed along the way**: `zregex_match_group`'s doc comment always claimed
  `group_index=0` returns the full match, but the implementation silently returned
  `NULL` for index 0 in every case — the internal capture array is 1-indexed by
  capture-group number (slot 0 is never written), so index 0 needs its own path rather
  than going through the same lookup as real capture groups; fixed by special-casing
  `group_index == 0` to read `match.result.start`/`.end`/`.group()` directly. Immediately
  after this parity work landed, the project's own C/C++ header (`include/zregex.h`),
  C++ RAII wrapper (`include/zregex.hpp`), and example were **deleted**: maintaining a
  hand-written header, a C++ wrapper class, an example, and doc sections in lockstep with
  every Zig-side feature was recurring maintenance debt unrelated to the actual goal (JS
  conformance), and zregex is Zig-first — see "Not Suitable For" below. The exported C
  symbols in `src/c_api.zig` still exist (built via `zig build shared`) purely as the FFI
  substrate the conformance harness needs; they're not a documented or supported public
  API, and anyone wanting to call zregex from C/C++ needs to write their own bindings
  against them.
- **`\p{Name}`/`\P{Name}` Unicode property escapes (General_Category)** *(added in Phase
  3)* — `\p{L}`, `\p{Lu}`, `\p{Letter}`, `\p{gc=Nd}`, etc. now compile and match real
  Unicode General_Category data (letters, digits, punctuation, ... including their
  two-letter subcategories), generated from the official Unicode Character Database's
  `UnicodeData.txt` (`scripts/gen_unicode_tables.py` → `src/unicode/tables.zig`, ~330KB,
  checked in — zero runtime dependency, same pattern as the test262 conformance sample).
  New `UNICODE_PROPERTY`/`UNICODE_PROPERTY_INV` opcodes decode a full UTF-8 codepoint and
  binary-search the property's range table (`properties.zig::UnicodeProperty`, which now
  covers General_Category and binary properties uniformly — see next bullet — so this
  mechanism didn't need to change to support both). An unrecognized property name is a
  clear `error.UnknownUnicodeProperty` at compile time (not silently ignored). Script
  properties (`\p{Script=Greek}`) are implemented too — see the dedicated bullet below,
  and `\p{...}`/`\P{...}` as a character-class member (`[\p{L}\d]`) has its own bullet
  further down as well.
- **`\p{Name}`/`\P{Name}` for binary properties** *(added after Phase 3, expanded twice
  the same day: first an initial 4-property subset to validate the mechanism, then to
  every available property including Emoji properties)* — every ECMA-262 binary
  property available from `PropList.txt`/`DerivedCoreProperties.txt`/`emoji-data.txt`
  (48 properties — e.g. `\p{White_Space}`, `\p{Alphabetic}`, `\p{Math}`, `\p{Dash}`,
  `\p{Hex_Digit}`, `\p{Quotation_Mark}`, `\p{ID_Start}`, `\p{Cased}`, `\p{Emoji}`,
  `\p{Extended_Pictographic}`, ...; see `src/unicode/README.md` for the full list),
  generated with the same range-table/binary-search mechanism as General_Category, plus
  the two trivial properties `\p{ASCII}` (codepoint ≤ U+007F) and `\p{Any}` (matches
  every codepoint), computed directly with no table. Found and fixed a real bug in the
  generator along the way: some `emoji-data.txt` lines have no space before the trailing
  `#` comment (e.g. `Extended_Pictographic# E0.6 ...`), which a naive `\S+` regex would
  have folded into the property name, silently losing every such line — caught before it
  shipped by checking the extracted range count wasn't suspiciously small.
- **`\p{Script=Name}`/`\p{sc=Name}`/`\P{Script=Name}`** *(added after Phase 3)* — all
  174 scripts from `Scripts.txt` (e.g. `\p{Script=Greek}`, `\p{Script=Han}`,
  `\p{sc=Latin}`). Architecturally different from General_Category/binary properties:
  174 scripts is too many for a hand-maintained `UnicodeProperty` enum variant + switch
  arm each, so scripts get their own generated lookup (`tables.zig`'s parallel
  `SCRIPT_NAMES`/`SCRIPT_RANGES` arrays, searched by `properties.zig::resolveScript`/
  `isInScript`) and their own opcodes (`UNICODE_SCRIPT`/`UNICODE_SCRIPT_INV`, taking a
  script-table index instead of a `UnicodeProperty` value) — same underlying
  binary-search-over-codepoint-ranges idea, different plumbing to keep the hand-written
  `UnicodeProperty` enum from ballooning to ~260 variants. Both the canonical long name
  (`Greek`) and the short alias (`Grek`, see the next bullet) are accepted; a bare
  `\p{Greek}` with no `Script=`/`sc=` prefix is correctly rejected too
  (`error.UnknownUnicodeProperty`), matching real JS (only General_Category can be used
  bare — Script always needs the prefix). Script_Extensions (`\p{Script_Extensions=...}`
  / `\p{scx=...}`) is a related but different property — see its own bullet below.
- **Short script aliases** (`\p{Script=Grek}` as well as the long `\p{Script=Greek}`)
  *(added after Phase 3)* — sourced from `PropertyValueAliases.txt`'s `sc ; <short> ;
  <long>` lines (e.g. `sc ; Grek ; Greek`), resolved to a `SCRIPT_NAMES` index at
  *generation* time and emitted as a third pair of parallel arrays,
  `SCRIPT_ALIAS_NAMES`/`SCRIPT_ALIAS_INDICES`, so `resolveScript` only ever does a flat
  binary search (first over aliases, then over canonical names) — no runtime
  alias-to-canonical string rewriting. No opcode, parser, or codegen changes were
  needed: `resolveScript`'s return type and callers didn't change, only what it
  recognizes as input. 174 of the 176 `sc` lines in `PropertyValueAliases.txt` map to a
  script `Scripts.txt` actually assigns to some codepoint; the two that don't
  (`Zzzz`→`Unknown`, `Hrkt`→`Katakana_Or_Hiragana`) are silently skipped rather than
  pointing at a nonexistent table entry.
- **`\p{Script_Extensions=Name}`/`\p{scx=Name}`/`\P{Script_Extensions=Name}`** *(added
  after Phase 3)* — a broader, possibly multi-valued property than `Script`: e.g. U+0301
  (a combining accent) has `Script=Inherited` but `Script_Extensions` includes Latin,
  Cyrillic, Greek, and every other script it's actually combined with in real text —
  the textbook UAX24 example of why the property exists. Reuses `Script`'s index space
  exactly (`resolveScript` resolves both the long name and short alias identically for
  both properties — a script's identity doesn't change, only which codepoints count as
  using it), with its own opcodes (`UNICODE_SCRIPT_EXTENSIONS`/`_INV`) and a fourth
  generated table, `SCRIPT_EXTENSIONS_RANGES` (same index space as `SCRIPT_RANGES`).
  Per UAX24, `ScriptExtensions.txt` only lists the codepoints (669 total, currently)
  where Script_Extensions actually diverges from Script — everywhere else `scx == sc` —
  so the generator builds `SCRIPT_EXTENSIONS_RANGES[i]` by applying just those overrides
  on top of `SCRIPT_RANGES[i]` (add the codepoint to every script its override line
  lists; remove it from its old default script if that script isn't listed), never
  recomputing either table from scratch.
- **`\p{Bidi_Mirrored}`/`\p{Assigned}`** *(added after Phase 3)* — the two remaining
  binary properties that don't live in a separate range-list file at all:
  `Bidi_Mirrored` is a plain Y/N column already present in `UnicodeData.txt` (field 9,
  previously read but never emitted), and `Assigned` is just "any codepoint
  `UnicodeData.txt` lists" (every assigned codepoint already falls under one of the 7
  major General_Category buckets, so this needed no new parsing, just collecting
  codepoints the General_Category pass already sees into one more table). No new UCD
  file fetch was needed for either — both simplest of the whole `\p{...}` property
  set to add, since the data was already being read.
- **`\p{...}`/`\P{...}` as a character-class member** (`[\p{L}\d]`, `[\P{Alphabetic}a-z]`,
  `[^\p{L}\d]`) *(added after Phase 3)* — up to 4 property/script/script-extensions
  tests per class (`error.TooManyClassProperties` beyond that), via a new
  `CHAR_CLASS_UNICODE`/`CHAR_CLASS_UNICODE_INV` opcode pair that ORs an inline
  code-point-range table (same layout `CHAR_CLASS_RANGES` uses, for the class's literal
  chars/ranges/spliced shorthand like `\d`) with a small table of property tests. Each
  property test carries its *own* `negated` bit for `\P{...}` used as a class member —
  `[\P{L}\d]` ("not-a-letter, or a digit," a per-member complement inside the union) is
  a different thing from the whole class's `[^...]` negation (`[^\p{L}\d]`, still
  applied once via the opcode's `_INV` form, the same single-XOR-at-the-end approach
  `CHAR_CLASS_RANGES_INV` already used correctly — verified both stay distinct via a
  dedicated regression test). This closes out the one remaining Phase 3 follow-up that
  needed real new opcode/matcher work rather than reusing an existing mechanism as-is.
- **`case_insensitive` folds a literal non-ASCII character's simple case pair**
  *(Phase 4, added later in the session)* — a literal non-ASCII character, standalone
  (`café` also matches `CAFÉ`) or as a single character-class member (`[é]` also
  matches `É`; mixed classes like `[aé]` fold both members), also matches its
  `casefold.zig` case-fold pair when one exists. The parser tags the `.sequence` node
  it already built for one atomic multi-byte literal character (see the earlier Phase 1
  note on why multi-byte literals decompose into per-byte nodes) by setting its
  otherwise-unused `char_value` to the decoded code point — an ordinary multi-atom
  sequence (`"ab"`) never sets it — so `generateSequence` can tell "one atomic
  character" apart from any other sequence with no new AST node type, then emits the
  same SPLIT/GOTO alternation `generateChar` already used for ASCII letters, just with
  a whole UTF-8 byte run per branch instead of one byte. Quantifiers over a case-folded
  literal still work correctly (`é+` repeats the whole atomic character regardless of
  which case each repetition matched). Codepoints with no case pair (`casefold.toUpper`/
  `toLower` both `null`, e.g. CJK ideographs) are left unchanged, not miscompiled. Not
  covered: non-ASCII character *ranges* (`[À-Ö]`) and `\p{...}`-in-a-class members —
  see the dedicated limitation entry below for why those are harder.
- **`\v`/`\f` recognized as vertical tab / form feed** *(bug found and fixed while
  building the `u` flag below)* — these were never handled as standalone escapes at
  all: `\n`/`\r`/`\t` were recognized right next to them in the same `switch`, but
  `\v`/`\f` silently fell through to a literal `'v'`/`'f'` character, in both the
  normal-atom and character-class escape paths. Not related to the earlier Phase 6 fix
  for `\s`/`\S` including form feed/vertical tab as *shorthand-class members* — this is
  the standalone-escape-token bug, a different code path. Fixed unconditionally (not
  gated behind the `unicode` flag below), since it was simply wrong before.
- **`CompileOptions.unicode` (JS `u` flag), partial** *(added after Phase 4)* — this
  engine was already unconditionally code-point-aware and already supported `\p{...}`
  (including inside a class) with no flag at all, so most of what `u` mode toggles in
  real JS was already the only behavior here regardless. What the flag adds: an escaped
  character that isn't a recognized escape sequence or `SyntaxCharacter` (`^ $ \ . * +
  ? ( ) [ ] { } |`, plus `/`, plus `-` inside a class) is `error.InvalidEscape` instead
  of the Annex-B-style literal fallback this engine uses by default (`unicode` defaults
  to `false`, so no existing pattern's behavior changes unless a caller opts in) — e.g.
  `\q`, `\-` outside a class, `\B` inside a class, and legacy octal (`\0` followed by a
  digit) all become compile errors under `unicode = true`. **A real, subtle bug found
  and fixed while building this**: `parseCharClass` speculatively tokenizes the
  character right after `[` in *normal* (non-class) mode first, purely to check whether
  it's `^`, then rewinds and re-tokenizes in class mode if it isn't (a pre-existing
  design, see its doc comment) — but `-` is a valid class-mode identity escape and *not*
  a valid normal-mode one, so that speculative fetch could itself trip the new strict
  check and error out before the rewind-and-retry ever ran, making `[\-a]` wrongly fail
  to compile under `unicode = true`. Fixed by disabling `unicode_mode` for just that one
  speculative, always-discarded-or-redone lookahead token. Malformed `\x`/`\u`/`\c`/
  `\k`/`\p` and backreferences to nonexistent groups are **not** yet made strict under
  this flag — see the dedicated `u`/`v` section below.
- **`CompileOptions.v` (JS `v` flag), partial** *(added later in the session)* —
  character-class set operations, `[A--B]` (difference) and `[A&&B]` (intersection),
  exactly one per class (no chaining, `error.ChainedClassSetOperatorNotSupported`; no
  nesting beyond one bracket level), each operand an ordinary class body, a bare
  `\p{...}`/`\P{...}` atom, or a nested (possibly `[^...]`-negated) `[...]` class. A new
  opcode, `CHAR_CLASS_SET_OP`, evaluates both operands' own `CHAR_CLASS_UNICODE`-shaped
  membership tests against one decoded code point at *match* time and combines with
  AND/AND-NOT — deliberately not compile-time range arithmetic, since a real operand
  like `\p{L}` (~700 ranges) would blow past the fixed 8-slot range table every other
  class opcode uses; per-operand match-time evaluation sidesteps that. `--`/`&&`/`[`
  (nested operand) only tokenize specially inside a class when `v_mode` is on (default
  `false` — existing patterns using literal `-`/`&`/`[` in a class are unaffected). Four
  real bugs found and fixed while building this (a double-free from duplicate `errdefer`
  ownership between the parser functions handling operand1 vs. the shared
  operator-and-operand2 logic; two lexer-mode-timing bugs where recursing into
  `parseCharClass` for a nested operand while still in class mode broke that recursive
  call's own `^`-negation lookahead, both on the way in and the way back out; and a
  double-counted outer `[^...]` negation for flat, non-bracketed operands) — see the
  dedicated `u`/`v` section below for the full writeup of each. **Not implemented**:
  chaining/deeper nesting (by design), `\q{...}` multi-string literals, `v`'s own
  additional reserved-punctuator restrictions, and full `u`-mode strictness under `v`.
- **Duplicate named groups across mutually exclusive alternation branches**
  *(added later in the session)* — `(?<x>a)|(?<x>b)` now compiles, matching JS's actual
  rule (this engine previously took the simpler, always-reject subset described in the
  Phase 2 bullet above). Implemented via a compile-time-only "branch path" the parser
  tracks per named group: every `parseAlternation` call reserves a fresh id and pushes
  `(id, branch_index)` onto a fixed-depth stack (`MAX_ALTERNATION_DEPTH = 32`, no heap
  allocation, `error.AlternationTooDeep` beyond that) while parsing each branch, whether
  or not that call turns out to contain a real `|` -- necessary so that two groups
  sharing no real alternation ancestor are guaranteed to disagree on id the first time
  their paths diverge. A named group snapshots the live stack into its
  `GroupNameEntry.branch_path` when created; two same-named groups are allowed exactly
  when their paths first diverge at the *same* id with a *different* branch index (a
  shared disjunction they take different arms of) -- identical paths, one a prefix of
  the other, or diverging at different ids, all still conflict. **Two real bugs found
  and fixed while building this, both pre-existing and unrelated to each other**: (1)
  `MatchResult.getNamedCapture`/`getNamedCaptureIndices` and `Regex.replace`'s
  `$<name>` substitution all stopped at the *first* `named_groups` entry with a
  matching name, regardless of whether that specific group actually participated --
  never exercised before since duplicate names were always rejected, but with
  `(?<x>a)|(?<x>b)` now valid, looking up `"x"` after matching `"b"` needs to find the
  *second* declaration's capture, not the first (unmatched) one; fixed by checking every
  same-named entry and using whichever one actually captured. (2) An early version of
  this feature stored each group's branch-path snapshot as a heap-allocated dupe, which
  meant *every* pattern (not just ones with named groups) now allocated via
  `parseAlternation` -- silently breaking the many existing unit tests across the
  codebase that construct a `Parser` directly and never call `parser.deinit()` (previously
  harmless, since `group_names` starts empty and only allocates for patterns with named
  groups). Switched to the fixed-depth array above specifically to keep this feature
  allocation-free, avoiding the need to audit every such test site.

### test262 conformance sample

`zig build test-conformance` (`tests/test262_conformance.zig` + `tests/test262_data.zig`,
regenerated by `scripts/extract_test262.py` + `scripts/gen_test262_data.py`, see
`scripts/README.md`) runs a **heuristically extracted** sample of test262's RegExp tests.

**Why "heuristically extracted"**: test262 tests are full JS programs with imperative
assertions (`var arr = /pattern/.exec(str); if (arr[0] !== "x") throw ...`), not
declarative pattern/input/expected data — there's no JS interpreter here to run them
as-is. The extraction scripts recognize a handful of common simple shapes (bare
`.test()`/`.exec()` calls checked against a boolean, `null`, or a Sputnik-style
`__expected` capture array) via pattern matching on the JS source, and honestly skip
anything else (loops, shared harness helpers like `compareArray.js`, multi-statement
logic) rather than guessing. Of ~2117 files under test262's `test/built-ins/RegExp` and
`test/language/literals/regexp` (after excluding `\p{...}`/`Symbol.*`-related and
syntax-error-expecting tests, which are out of scope or need different handling), 168
cases were extracted from 167 files — a small, simple-case-biased sample, not a
conformance percentage in the way browser engines report one.

**Current result: 168/168 (100%)**, reached in stages, each one individually triaged and
fixed (see the "What works" bullets above for the engine-side fixes): the three
character-class gaps (metacharacters-as-literals, shorthand-classes-as-members, `[^]`)
first dropped compile errors from 13 to 0; then a real bug in the extraction *tooling*
itself (not the engine) was found and fixed — `scripts/extract_test262.py`'s JS-string
decoder didn't handle `\b`/`\f`/`\v` string escapes (only regex-pattern escapes), so a
JS source string literal like `"easy\btoride"` was silently corrupted into
`"easybto\x08ride"` (dropping the backslash, keeping the `b`) before ever reaching
zregex — 4 tests were failing against wrong input data, not because of an engine bug;
then the six deeper backtracking-correctness bugs listed above accounted for the rest.
**Caveat unchanged from before**: 168 cases is still a small, simple-case-biased sample of
test262's several-thousand-plus RegExp-relevant tests (see above) — 100% here means "100%
of what this harness currently checks," not "0 known JS RegExp incompatibilities." The
unblocked-but-not-yet-implemented items in the summary table below (`\p{...}`, case
folding, `u`/`v` flags, `$1`/`$&` in `replace`) are real gaps this sample doesn't exercise.

### `test_()` vs `find()` — a common source of confusion

`test_()` requires the **entire** input string to match (it's an anchored full match), not
a substring search. `regex.test_(allocator, "\\d+", "Price: 42")` returns `false`, not
`true`, because `"Price: 42"` as a whole doesn't match `\d+`. To check "does this pattern
appear anywhere in the string", use `find()` or `findAll()` instead. This previously caused
incorrect examples in this repository's own README and doc comments.

---

## Confirmed bugs (still open)

*(none currently tracked here — see "Genuinely unimplemented" below for known gaps, all
of which are scoped-out features, not bugs in what's implemented)*

---

## Genuinely unimplemented

### Unicode Case Folding — non-ASCII character *ranges*

```zig
const options = CompileOptions{ .case_insensitive = true };
var re = try Regex.compileWithOptions(allocator, "[\xc3\x80-\xc3\x96]", options); // [À-Ö]
try re.test_("à"); // false — the range itself isn't case-folded, only individual members
```

`case_insensitive` folds ASCII `a-z`/`A-Z` fully (standalone, in ranges, and in classes),
and — as of a same-session Phase 4 follow-up — a literal non-ASCII character's simple
case-fold pair too, both standalone (`café` also matches `CAFÉ`) and as a single
character-class member (`[é]` also matches `É`; mixed ASCII/non-ASCII members like
`[aé]` fold both). Quantifiers over a case-folded non-ASCII literal work correctly
(`é+` still repeats the whole atomic character, matching either case per repetition).
What's still not folded: non-ASCII character *ranges* (`[À-Ö]`) — unlike ASCII's uniform
+32 shift, Unicode case mappings aren't a simple offset over an arbitrary range, so
folding one would need per-codepoint expansion rather than the single-pair-per-member
mechanism the literal/class-member case uses; and `\p{...}`-in-a-class members (a
property's *set* of codepoints doesn't have a single "case-fold pair" to add the way one
literal character does). See `docs/ECMASCRIPT_COMPATIBILITY_PLAN.md` Phase 4 for the
mechanism and the reasoning behind what's covered vs. not.

### `u` (Unicode mode) flag — partial; `v` (Unicode Sets mode) flag — partial

```zig
regex.Regex.compileWithOptions(allocator, "\\q", .{ .unicode = true }); // error.InvalidEscape
regex.Regex.compile(allocator, "\\q"); // matches literal "q" -- unicode defaults to false
regex.Regex.compileWithOptions(allocator, "[\\p{L}--[a]--[b]]", .{ .v = true }); // error.ChainedClassSetOperatorNotSupported
```

`CompileOptions.unicode` *(added after Phase 4)* exists now. This engine is already
unconditionally code-point-aware for `.`/negated classes/character-class ranges/
`\p{...}` (see Phase 1/3 above), and `\p{...}` inside a class (which `u`-mode patterns
commonly rely on, e.g. `[\p{L}\p{N}_]`) is supported unconditionally too (see above) —
so most of what `u` mode toggles in real JS was already the only behavior this engine
has, flag or not. What the flag actually does: reject an escaped character that isn't a
recognized escape sequence (`d`/`w`/`s`/`p`/`x`/`u`/`c`/`k`/digits/...) or a
`SyntaxCharacter` (`^ $ \ . * + ? ( ) [ ] { } |`, plus `/`, plus `-` inside a class) with
`error.InvalidEscape` instead of the Annex-B-style literal-character fallback this
engine uses everywhere by default (`unicode` defaults to `false`, so nothing about
existing patterns' behavior changes unless a caller opts in) — e.g. `\q`, `\-` outside a
class, `\B` inside a class, and `\0` followed by a digit (legacy octal) are all
`error.InvalidEscape` under `unicode = true`. **Found and fixed a real, independent bug
while building this**: `\v` (vertical tab) and `\f` (form feed) were never recognized as
standalone escapes at all — falling through to literal `'v'`/`'f'` even *without* the
new flag, unlike `\n`/`\r`/`\t` right next to them in the same `switch`. Fixed
unconditionally (not gated behind `unicode`), since it was simply wrong before, and
needed anyway so `\v`/`\f` wouldn't become spuriously ungrammatical under the new
strict check. **Not yet modeled** under `unicode = true`: malformed `\x`/`\u`/`\c`/`\k`/
`\p` still fall back to Annex-B leniency rather than erroring (real `u` mode requires
each to be well-formed); a backreference to a group number that doesn't exist in the
pattern isn't rejected.

`CompileOptions.v` *(added later in the session)* exists too, covering exactly one
piece of real `v`-mode syntax: character-class set operations, difference (`[A--B]`,
matches `A` but not `B`) and intersection (`[A&&B]`, matches both) — **but only a single
operation per class, no chaining (`[A--B--C]` is `error.ChainedClassSetOperatorNotSupported`)
and no nesting beyond one bracket level**. Each operand (`A`/`B`) is either an ordinary
class body (`\p{L}`, `a-z\d`, a bare `\p{...}`/`\P{...}` atom, ...) or a nested `[...]`
class, which may itself be `[^...]`-negated (`[[a-z]&&[^x]]`). Implemented via a new
opcode, `CHAR_CLASS_SET_OP`, that evaluates *two* independent `CHAR_CLASS_UNICODE`-shaped
operand specs against one decoded code point at match time and combines them with AND
(intersection) or AND-NOT (difference) — deliberately not compile-time range-set
arithmetic, since a real operand like `\p{L}` has ~700 ranges, far past the fixed 8-slot
range table every other class opcode in this engine uses; evaluating each operand's own
membership test independently at match time sidesteps that entirely. `--`/`&&`/`[` (for
a nested operand) only tokenize specially inside a class when `v_mode` is on (default
`false`), so existing patterns using literal `-`/`&`/`[` inside a class are unaffected.
**Four real bugs found and fixed while building this** (all in `src/parser/parser.zig`,
none in the matcher, which worked correctly from the start once the parser produced a
correct AST):

1. A double-free: both the caller (`parseCharClass`, for a nested operand1) and the
   callee (`finishClassSetOp`, which takes ownership of `left`) registered an `errdefer`
   for the same node — if `finishClassSetOp` failed after its own cleanup ran, the
   caller's stale `errdefer` fired again on the same freed pointer. Fixed by making
   ownership-transfer points explicit: a `_owned` boolean flag gates each `errdefer` off
   the moment ownership actually passes elsewhere (flipped *after* a fallible transfer
   like `appendChild` succeeds, not before, so a failed transfer still leaves exactly
   one owner responsible for cleanup).
2. A lexer-mode timing bug: recursing into `parseCharClass` for a nested operand (e.g.
   the `[^x]` in `[[a-z]&&[^x]]`) happened while the lexer was still in class mode from
   the *outer* class — but `parseCharClass`'s own `^`-negation lookahead assumes it's
   entered from *normal* mode (the same tradeoff its own doc comment already describes
   for the top-level case). Entering from class mode instead meant `^` never got
   recognized as `.line_start`, silently losing the nested operand's negation. Fixed by
   resetting `in_char_class = false` before every such recursive call, matching how the
   top-level entry point already always starts that way.
3. A related mode bug on the way *out*: after a nested operand's `parseCharClass` call
   returns, whatever follows its `]` (an operator, for chaining, or the outer class's
   own `]`) was fetched during that nested call's own cleanup — but in *normal* mode
   again, for the same underlying reason as bug 2. Fixed with the same
   rewind-to-token-start-and-re-fetch-in-class-mode trick `parseCharClass` already used
   for its own top-level `^` lookahead.
4. A double-counted outer negation: a *flat* (non-bracketed) operand1's `char_class`
   node was reusing the *outer* class's `[^...]` flag as if it were operand1's own
   negation (correct for an ordinary, non-set-op class, where that's the only
   negation there is) — but for a set operation, the outer `^` belongs solely to the
   whole operation's result (`[^\p{L}--[aeiou]]`'s `^` negates "letters that aren't
   vowels" as a whole, not `\p{L}` by itself). Left uncorrected, `[^\p{L}--[aeiou]]`
   silently computed `NOT(letter) AND NOT(vowel)`, negated again, instead of
   `NOT(letter AND NOT(vowel))`. Fixed by clearing the flat operand's own `.inverted`
   back to `false` right before handing it to `finishClassSetOp`.

**Not implemented in `v` mode**: chaining/deeper nesting (by design, see above); `\q{...}`
multi-string literals; `v`'s own additional reserved-punctuator restrictions inside a
class (beyond what `u`-mode strictness already covers, itself only partial); and full
`u`-mode strictness under `v` (since `v` implies all of `u`'s rules, and Phase 5b's
strictness is itself only the unrecognized-escape slice — see above).

---

## Summary

| Feature | Status |
|---|---|
| Basic character matching | ✅ Working |
| Character classes (`\d`, `[a-z]`, `\W`, `\S`) | ✅ Working |
| Quantifiers (greedy, lazy, possessive, counted) | ✅ Working |
| Alternation (`\|`) | ✅ Working |
| Capturing / non-capturing groups | ✅ Working |
| Backreferences `\1`-`\9` | ✅ Working |
| Lookahead / Lookbehind | ✅ Working |
| Anchors `^`, `$`, `\b`, `\B` (string-level) | ✅ Working |
| `case_insensitive` (ASCII) | ✅ Working |
| ReDoS protection (step/recursion limits) | ✅ Working |
| `multiline` option | ✅ Fixed (Phase 0) |
| `dot_all` option / default dot-vs-newline | ✅ Fixed (Phase 0) |
| Escapes `\xHH`, `\uHHHH`, `\u{H+}`, `\0`, `\cX` | ✅ Fixed (Phase 0) |
| Invalid quantifier range `{n,m}` with `n > m` | ✅ Fixed (Phase 0) |
| `.` consumes a full Unicode scalar value | ✅ Fixed (Phase 1) |
| Negated classes (`\W`, `\S`, `[^...]`) consume a full scalar value | ✅ Fixed (Phase 1) |
| Literal multi-byte characters quantify atomically | ✅ Fixed (Phase 1) |
| Literal `-` outside a character class (e.g. `555-1234`) | ✅ Fixed (found during Phase 2) |
| Named capture groups `(?<name>...)` and `\k<name>` | ✅ Added (Phase 2) |
| Duplicate names across mutually-exclusive alternation branches | ✅ Implemented (matches JS exactly; see above) |
| Character classes with multi-byte members/ranges (`[é]`, `[a-\u{2FF}]`) | ✅ Fixed (Phase 3) |
| `src/unicode/` module (General_Category + 50 binary properties, simple case mapping) | ✅ Implemented (Phase 3) |
| Unicode property escapes `\p{...}`/`\P{...}` (General_Category) | ✅ Implemented (Phase 3) |
| `\p{...}`/`\P{...}` binary properties (50 total, incl. Emoji/Bidi_Mirrored/Assigned — see `src/unicode/README.md`) | ✅ Implemented (Phase 3) |
| `\p{Script=Name}`/`\p{sc=Name}` (174 scripts + short aliases, e.g. `\p{Script=Grek}`) | ✅ Implemented (Phase 3) |
| `\p{Script_Extensions=Name}`/`\p{scx=Name}` | ✅ Implemented (Phase 3) |
| `\p{...}`/`\P{...}` as a character-class member (`[\p{L}\d]`, up to 4 tests) | ✅ Implemented (Phase 3) |
| Unicode case folding: literal non-ASCII char (standalone or single class member) | ✅ Implemented (Phase 4) |
| Unicode case folding: non-ASCII character ranges (`[À-Ö]`) / `\p{...}`-in-a-class | ❌ Not implemented |
| `sticky` option (`y` flag) + `Regex.findAt` | ✅ Added (Phase 5a) |
| `getCaptureIndices`/`getNamedCaptureIndices` (`d` flag equivalent) | ✅ Added (Phase 5a) |
| `u` flag (`CompileOptions.unicode`): strict unrecognized-escape rejection | ✅ Implemented (Phase 5b) |
| `u` flag: malformed `\x`/`\u`/`\c`/`\k`/`\p`, bad backrefs still lenient | ❌ Not implemented |
| `v` flag (`CompileOptions.v`): class set ops `[A--B]`/`[A&&B]`, single op, no chaining | ✅ Implemented |
| `v` flag: chaining/deep nesting, `\q{...}`, `v`-only reserved punctuators, full `u` strictness | ❌ Not implemented |
| Quantified backreference to an empty capture (e.g. `\1+`) crashing | ✅ Fixed (Phase 6) |
| test262 conformance sample (`zig build test-conformance`) | ✅ Added (Phase 6) — 168/168 (100%) |
| Metacharacters as literals inside `[...]` (e.g. `[*&$]`, `[.]`) | ✅ Fixed (Phase 6) |
| Shorthand classes as class members (e.g. `[a-c\d]`) | ✅ Fixed (Phase 6) |
| `[^]` (negated empty class = "match anything") | ✅ Fixed (Phase 6) |
| `\s`/`\S` missing `\f`/`\v` | ✅ Fixed (Phase 6) |
| Case-insensitive character classes/ranges (e.g. `/[a-z]/i`) | ✅ Fixed (Phase 6) |
| Capture on a quantified group losing its last iteration's value | ✅ Fixed (Phase 6) |
| `*`/`?` on a capturing group not actually greedy | ✅ Fixed (Phase 6) |
| Lazy quantifiers capped at one iteration | ✅ Fixed (Phase 6) |
| Stale capture leaking across outer-loop iterations | ✅ Fixed (Phase 6) |
| Backreference to a never-participated group failing instead of matching empty | ✅ Fixed (Phase 6) |
| Negative lookahead's own captures leaking out | ✅ Fixed (Phase 6) |
| `replace()`/`replaceAll()` in pure Zig API, with `$1`/`$&`/`` $` ``/`$'`/`$<name>` substitution | ✅ Done |
| `replace()`/`replaceAll()` substitution syntax + capture indices + named-group enumeration + `findAt` + `m`/`s`/`y`/`u`/`v` flags in the exported C ABI (internal FFI substrate only, not a public API — see above) | ✅ Implemented (Phase 0) |
| Public, documented/supported C/C++ API (headers, C++ wrapper, examples) | ❌ Removed — not a project goal (see above) |

---

## When to Use zregex

### ✅ Good For:
- ASCII text matching with the full range of standard regex syntax (quantifiers,
  alternation, groups, backreferences, lookaround, named groups)
- Patterns using `multiline`, `dot_all`, `sticky`, or `\x`/`\u`/`\0`/`\c` escapes
- Text with multi-byte UTF-8 characters matched via `.`, negated classes (`\W`, `\S`,
  `[^...]`), literal characters in the pattern, or character classes/ranges containing
  a non-ASCII member (`[é]`, `[a-\u{2FF}]`) — these are all code-point-aware
- Character classes containing a literal metacharacter (`[*&$]`, `[.]`), a shorthand
  class member (`[a-c\d]`), or the `[^]` "match anything" idiom
- Unicode General_Category property escapes (`\p{L}`, `\p{Lu}`, `\p{Letter}`, `\p{gc=Nd}`,
  ...), binary properties (`\p{White_Space}`, `\p{Alphabetic}`, `\p{Math}`, `\p{Dash}`,
  `\p{Hex_Digit}`, `\p{ID_Start}`, `\p{Emoji}`, `\p{Bidi_Mirrored}`, `\p{Assigned}`,
  `\p{ASCII}`, `\p{Any}`, and 40 more), `\p{Script=Name}`/`\p{sc=Name}` for all 174
  Unicode scripts and their short aliases (`\p{Script=Greek}`, `\p{Script=Grek}`,
  `\p{Script=Han}`, ...), and `\p{Script_Extensions=Name}`/`\p{scx=Name}` for the same
  174 scripts' broader membership (`\p{Script_Extensions=Latin}`, `\p{scx=Grek}`, ... —
  see `src/unicode/README.md`), both as standalone atoms and as class members
  (`[\p{L}\d]`, `[\P{Alphabetic}a-z]`, `[^\p{L}\d]`, up to 4 property tests per class)
- `case_insensitive` matching where non-ASCII literal characters are involved,
  standalone (`café` also matches `CAFÉ`) or as a single class member (`[é]` also
  matches `É`) — but not non-ASCII character ranges (see "Not Suitable For")
- `CompileOptions.unicode` to reject an unrecognized escape (`\q`, stray `\-` outside a
  class, `\B` inside one, legacy octal) as a compile error rather than a silent literal
  fallback — but not malformed `\x`/`\u`/`\c`/`\k`/`\p` or bad backrefs (see "Not
  Suitable For")
- `CompileOptions.v` for a single character-class set operation, `[\p{L}--[aeiou]]`
  (difference) or `[[a-z]&&[^x]]` (intersection), with either operand an ordinary class
  body, a bare `\p{...}`/`\P{...}` atom, or a nested (optionally `[^...]`-negated)
  `[...]` class — but not chained/deeply nested operations, `\q{...}`, or `v`'s other
  syntax (see "Not Suitable For")
- Iterative matching that tracks its own position (`Regex.findAt`), or needs capture
  offsets rather than substrings (`getCaptureIndices`/`getNamedCaptureIndices`)
- Patterns requiring ReDoS protection guarantees

### ⚠️ Use with Caution:
- Character classes needing more than 8 non-ASCII ranges/members (`error.TooManyRanges`)
  or more than 4 `\p{...}`/`\P{...}` tests (`error.TooManyClassProperties`)
- Alternations nested more than 32 levels deep (`error.AlternationTooDeep`, needed for
  duplicate-named-group mutual-exclusion tracking) — far beyond any realistic pattern

### ❌ Not Suitable For:
- `case_insensitive` matching of non-ASCII character *ranges* (`[À-Ö]`) or
  `\p{...}`-in-a-class members — only literal non-ASCII characters (standalone or as a
  single class member) are case-folded, see above
- Full `u`-mode strictness (malformed `\x`/`\u`/`\c`/`\k`/`\p` still fall back
  leniently; a backreference to a nonexistent group isn't rejected)
- Chained (`[A--B--C]`) or deeply nested `v`-mode class set operations, `\q{...}`
  multi-string literals, or `v`'s own additional reserved-punctuator restrictions
- Calling zregex directly from C or C++: no headers, wrapper library, or examples are
  shipped or maintained (deliberate — see the "C API" bullet above). `src/c_api.zig`
  still exports a plain C ABI, built via `zig build shared`, but only as the internal FFI
  substrate for this project's own conformance-testing tooling; write your own bindings
  against it if you need this.

---

**Last Updated**: 2026-07-08
**Test Coverage**: 402/402 unit/integration tests passing; 168/168 (100%) on the
test262-derived conformance sample (`zig build test-conformance`) — see the caveat in
"test262 conformance sample" above before reading too much into that number. C API
parity (Phase 0 of the plan to measure and reach *real* test262 conformance, not just
this biased sample) is done — see "C API parity with the Zig API" above; a real
test262-conformance harness (Phase A) is the next step, not yet built.
