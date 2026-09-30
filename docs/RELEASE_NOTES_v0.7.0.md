# z-regex v0.7.0

F7c, the API freeze (`docs/plans/ROADMAP_1.0.md`). From this release on, the API follows the
contract in `docs/API.md`: what is stable, what isn't, and what may change in a later release.
Details of each step: `docs/plans/F7c.md`.

## The API is frozen

- **Stable:** the 19 declarations at the root of the `zregex` module (`Regex`,
  `CompileOptions`, `RegexError`, `MatchResult`, `CaptureIndices`, `Subject`, `Scratch`,
  `MatchSlots`, `MatchIterator`, `ExecLimits`, `ExecError`, `version`, `test_`, `find`,
  `findAll`, `replace`, `replaceAll`, `unicode`, `internal`), and the C API: its 40
  `zregex_*` symbols, the layout of `ZRegexOptions` and the `ZRegexError` codes. The C API
  is stable for FFI consumers; there is no C header.
- **Not stable:** `zregex.internal` (the lexer, parser, HIR, tiers and analysis, for this
  repository's tests and tools) and the four diagnostic fields of `CompileOptions`
  (`force_tier`, `tier_diagnostic`, `t0_prefilters`, `t2_look_linear`).
- **The rule (the freeze):** valid syntax that zregex doesn't implement is
  `error.UnsupportedFeature` (C: `ZREGEXP_ERROR_UNSUPPORTED`, 9), never a wrong result. A
  later release only removes such cases; it never adds an error to `RegexError` or
  `ExecError`, and never turns a pattern that compiles into an error.
- **Enforced by tests:** the root's 19 declarations, `RegexError`'s 35 errors and
  `ExecError`'s 8, and the C code of each error.
- `ExecLimits.max_steps` counts per start position, and that is part of the contract.
  Deprecation: a symbol marked `/// Deprecated: use X.` stays at least one minor release.

## Breaking changes from 0.6.0

These are the last changes allowed before the freeze.

- **42 declarations moved from the root to `zregex.internal`** (`Lexer`, `Parser`, `compile`,
  `tier0`, `tier2`, `analyze`, …). Code that used them from the root must add `.internal`.
  `placeholder()` and `zig_version_required` are gone.
- **`Optimizer`, `OptLevel` and `CompileOptions.opt_level` removed.** The optimizer did
  nothing: it copied the bytecode unchanged. Opcodes `LOOP` (0x16) and `CHAR2` (0x02), never
  emitted, are reserved.
- **C error codes:** 11 syntax errors of the front end (`UnexpectedToken`, `UnexpectedEOF`,
  `UnmatchedBracket`, `DuplicateGroupName`, `UnknownGroupName`, `InvalidGroupName`,
  `InvalidRepeat`, `UnterminatedRepeat`, `UnknownUnicodeProperty`,
  `InvalidClassSetOperand`, `MixedClassSetOperators`) are `ZREGEXP_ERROR_SYNTAX` (1). Up
  to 0.6.0 they were `ZREGEXP_ERROR_UNKNOWN` (8). The 14 errors left in UNKNOWN are
  implementation limits, engine invariants, a diagnostic or errors nothing produces
  (`docs/API.md`, section 3).
- **`v` with `i`:** up to 0.6.0, sets under `iv` folded with the old ASCII rule, a silent
  wrong result. Now literals and classes fold as under `iu`, and what `v`'s folding would
  treat differently is `UnsupportedFeature` (property escapes, negated classes and set
  operands not closed under the folding; F5c, 1.x). Over the 1,059 `i`+`v` patterns of the
  corpora: 221 compile (all 221 give V8's result; 1,026 compiled before, 299 of them with a
  result different from V8's), 838 are `UnsupportedFeature` (33 before).
- **`v` set operations that ECMA-262 rejects are now SyntaxErrors:**
  - `--` and `&&` mixed in one class (`[a--b&&c]`) is `MixedClassSetOperators`. With flat
    operands it was `UnsupportedFeature`;
  - a list or a range as an operand (`[ab&&[c]]`, `[a-z--b]`) is `InvalidClassSetOperand`.
    `[ab&&[c]]` and `[a-z&&[b]]` compiled; the others were `UnsupportedFeature`. A range is
    written nested: `[[a-z]--b]`.

## Additions

- `RegexError` at the root (what compiling fails with), and one-shot `replace` and
  `replaceAll`.
- Doc comments on every stable declaration.
- The C API's `ZRegexOptions.max_steps` is documented as `ExecLimits.max_steps`;
  `max_recursion_depth` is reserved and has no effect.

## Documentation

- `docs/API.md`: the contract.
- `docs/ARCHITECTURE.md`: rewritten as the reference. `docs/PROJECT_STRUCTURE.md`: the
  index of the tree.
- `KNOWN_LIMITATIONS.md` split into `docs/LIMITATIONS.md` (what applies today) and
  `docs/HISTORY.md` (the phases). `KNOWN_LIMITATIONS.md` stays as an index.
- `docs/BENCHMARKS.md`: re-measured (below).
- Closed-phase documents and the Spanish README moved to `docs/archive/`.

## Conformance

- **test262:** 2994 of the 3017 entries that run (99.2%), the same in UTF-16 and WTF-8; 821
  skipped (the harness's Node lacks the feature, or zregex doesn't have it yet). The same
  count as 0.6.0.
- **Against V8:**
  - `differential-v8`: identical to its reference, with no pattern giving a different
    result;
  - `lbdiff-v8` and `ivdiff`: every difference is `UnsupportedFeature`.
- **Internal differentials** (pfdiff, t1diff, lldiff, lbdiff): 0 differences.
- **C API:** 40 exported symbols; `zregex_version()` is `"0.7.0"`.

## Benchmark

Re-measured against V8, Rust regex, PCRE2 and zig-regex: best of 10 interleaved rounds, on a
different host than 0.3.0's, with z-regex 0.3.2 in the same rounds as a base. Full tables:
`docs/BENCHMARKS.md`. The ratios below are `execAt` throughput.

- **Ahead:**
  - the fast paths: `[a-z]+` is 2.5× V8 and 3.3× Rust regex; the literal `hello` is 7.6×
    V8; `Darcy` is 1.5× V8;
  - the book's title pattern is 1.15× V8, and `\p{L}+` on the book 1.5× V8;
  - compile time: 1.7–92× less than Rust regex on T0;
  - adversarial `(a+)+b` and `(a|aa)*c`: a few µs at any n, where V8 is exponential.
- **Even (±10%):** `\p{L}+` and `\p{General_Category=Lu}` against V8; `[A-Z][a-z]+` on the
  book against Rust regex.
- **Behind:**
  - T0 classes and groups: 1.9–5.8× behind V8 and 2.5–19× behind Rust regex (its lazy DFA);
  - literals: 1.45× behind Rust regex;
  - T1: 1.4–4.1× behind Rust regex;
  - T2: 5.6–14× behind V8.
- **E-mail:** email validation is z-regex's worst T0 case against Rust regex: 19× slower
  (2.2× slower than V8). The Pike VM pays per-position overhead that a JIT or a lazy DFA
  avoids. No fix is planned for 0.7.0; a lazy DFA over T0's Thompson program is the
  candidate for 1.x.
- **Against 0.3.2:**
  - improvements: the `u` cases of T1 are 1.4–2.2× faster, the lookbehind case ~24×, the
    double lookahead 2.4×;
  - everything else is within ±10%, except one diagnostic cell (`[a-z]+` forced onto the
    backtracker, short input, +12%, not confirmed by callgrind).

## Binary

Measured with `scripts/measure_binary.sh`:

| Build | v0.6.0 | v0.7.0 | Change |
|---|---|---|---|
| ReleaseFast | 1,111,536 B | 1,112,368 B | +832 |
| ReleaseSmall | 704,328 B | 704,456 B | +128 |

## Next

- **Roadmap:** v0.7.0 → 1–3 months of production use (0.7.x for fixes, no API change) →
  v1.0.0 with the same API.
- **1.x, additive under the freeze:**
  - a lazy DFA for T0;
  - B6 (a lookaround inside a lookbehind matched backward);
  - lookbehind matched backward under `u`/`v`;
  - F5c (`\q{…}`, properties of strings, chained and bare-operand set operations, the rest
    of `v` with `i`);
  - RegExp modifiers (ES2025).
