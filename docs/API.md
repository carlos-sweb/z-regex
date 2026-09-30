# zregex API contract

What a release of zregex promises, from 0.7.0 on. The root of the `zregex` module and the C
API are the stable API; everything else can change. Tests enforce the lists below (see
"Enforcement").

## 1. The stable API

The 19 declarations at the root of the `zregex` module:

| Symbol | What it is |
|---|---|
| `version` | The package version, a string (`"0.7.0"`). |
| `Regex` | A compiled pattern: `compile`, `compileWithOptions`, `deinit`, `matchFull`, `test_`, `find`, `findAt`, `findFrom`, `findAll`, `execAt`, `iterator`, `advanceIndex`, `replace`, `replaceAll`, `getPattern`, `groupCount`, `slotCount`. |
| `CompileOptions` | The flags: `case_insensitive` (`i`), `multiline` (`m`), `dot_all` (`s`), `sticky` (`y`), `unicode` (`u`), `v`, and `possessive` (an extension: `*+`, `++`, `?+`). The four diagnostic fields are outside the contract (section 2). |
| `RegexError` | What `Regex.compile`, the byte-offset methods and the one-shot functions fail with (section 3). |
| `MatchResult` | A match of the byte-offset facade: `start`, `end`, `getCapture`, `getNamedCapture`, `getCaptureIndices`, `getNamedCaptureIndices`, `deinit`. |
| `CaptureIndices` | A capture's `start` and `end` (`MatchResult.getCaptureIndices`). |
| `Subject` | The input of `execAt` and `iterator`: WTF-8 or UTF-16, indices in its own units. |
| `Scratch` | The reusable working memory of `execAt` and `iterator`. |
| `MatchSlots` | Where `execAt` writes the slots of a match (2 per group, group 0 first). |
| `MatchIterator` | Every match of a subject without allocating (`Regex.iterator`). |
| `ExecLimits` | The execution budgets: `max_steps` per start position, `max_backtrack_stack_bytes`, `max_memo_bytes`. |
| `ExecError` | What `execAt` and `MatchIterator.next` fail with (section 3). |
| `test_`, `find`, `findAll`, `replace`, `replaceAll` | One-shot functions: compile, run, free. |
| `unicode` | `isInCategory` and `UnicodeProperty`: the General_Category tables, for reuse outside the engine. |
| `internal` | The engine's pieces, outside the contract (section 2). |

**The C API** (`src/c_api.zig`, `zig build shared`) is stable for FFI consumers, such as
this repository's test262 harness:
- its 40 exported `zregex_*` symbols;
- the `ZRegexOptions` layout (an `extern struct`; `reserved` fields for additions);
- the `ZRegexError` codes (section 3).

It is not a documented public C API: there is no C header and no C++ wrapper; a caller
declares the functions it uses from `src/c_api.zig`. What is stable is the ABI above, so
such declarations keep working across releases.

**Execution limits** (`ExecLimits`) are part of the contract:
- **`max_steps` counts per start position**, not per execution (1,000,000 by default). A
  search that tries `n` start positions can take up to `n × max_steps` steps before it
  answers; a single start position that passes the budget is `StepLimitExceeded`. This
  won't change to a budget per execution: long subjects that match correctly would then
  fail (`plans/F7.md`, item 8, D11).
- `max_backtrack_stack_bytes` (64 MiB) bounds the backtracker's stacks
  (`BacktrackStackExhausted`); `max_memo_bytes` (1 MiB) bounds LookLinear's memo, and a
  lookahead whose memo doesn't fit runs without it, never an error.
- T0's VM runs in linear time and doesn't read `ExecLimits`; which patterns run on it is
  outside the contract (section 2), so a caller can't rely on a pattern never raising
  `StepLimitExceeded`.
- **In the C API**, `ZRegexOptions.max_steps` is `ExecLimits.max_steps` for every
  execution of that regex (0 keeps the default). `max_recursion_depth` is reserved and has
  no effect (since 0.4.0, F6a: the backtracker has no recursion). The C API doesn't expose
  `max_backtrack_stack_bytes` or `max_memo_bytes`: they keep their defaults. Adding them
  would use the `reserved` fields.

## 2. Outside the contract

- **`zregex.internal`:** the lexer, parser, HIR, code generator, tiers and analysis, for this
  repository's tests, tools and bench. It can change in any release, without notice.
- **The diagnostic fields of `CompileOptions`** (`force_tier`, `tier_diagnostic`,
  `t0_prefilters`, `t2_look_linear`): tests and bench only. They can change or go away.
- **Performance, memory use and the choice of executor.** They can change as long as the
  results don't.
- **The text of error messages** (`zregex_error_message`, `zregex_last_error_name` for errors
  outside section 3's table).

## 3. Errors

**The rule (the freeze):**
- valid syntax that zregex doesn't implement is `error.UnsupportedFeature` (C:
  `ZREGEXP_ERROR_UNSUPPORTED`, 9), never a wrong result;
- a later release only removes such cases (a pattern that was `UnsupportedFeature`
  compiles and matches as ECMA-262 says); it never adds a new error to a public error set,
  and never turns a pattern that compiles into an error.

**`RegexError`** has 35 errors, fixed by a test. Each one has a C code
(`ZRegexError`, returned by `zregex_last_error`); `zregex_last_error_name` gives the Zig
name.

| Zig errors | C code |
|---|---|
| `InvalidEscape`, `InvalidQuantifier`, `IncompatibleFlags`, `UnexpectedToken`, `UnexpectedEOF`, `UnmatchedBracket`, `DuplicateGroupName`, `UnknownGroupName`, `InvalidGroupName`, `InvalidRepeat`, `UnterminatedRepeat`, `UnknownUnicodeProperty`, `InvalidClassSetOperand`, `MixedClassSetOperators` | `ZREGEXP_ERROR_SYNTAX` (1) |
| `OutOfMemory` | `ZREGEXP_ERROR_OUT_OF_MEMORY` (2) |
| `RecursionLimitExceeded`, `BacktrackStackExhausted` | `ZREGEXP_ERROR_RECURSION_LIMIT` (3) |
| `StepLimitExceeded` | `ZREGEXP_ERROR_STEP_LIMIT` (4) |
| `UnmatchedParen` | `ZREGEXP_ERROR_UNMATCHED_PAREN` (6) |
| `InvalidCharRange` | `ZREGEXP_ERROR_INVALID_RANGE` (7) |
| `UnsupportedFeature` | `ZREGEXP_ERROR_UNSUPPORTED` (9) |
| the other 14 (below) | `ZREGEXP_ERROR_UNKNOWN` (8) |

`SYNTAX` is a pattern ECMA-262 rejects (V8 throws a SyntaxError). Until 0.6.0 the 11 after
`IncompatibleFlags` were `UNKNOWN`; they were moved before the freeze.

The 14 that stay `UNKNOWN` are not a SyntaxError of the pattern:
- **implementation limits on valid syntax:** `NestingTooDeep` (more than 256 nested groups,
  lookarounds or classes), `TooManyCaptures` (more than 65,535), `PatternTooLarge` (the
  compiled program's size);
- **engine invariants** (seeing one is a bug in zregex): `InvalidPattern`, `UnknownOpcode`,
  `UnexpectedEndOfBytecode`, `UnresolvedLabels`, `BufferTooSmall`, `InvalidCharSet`;
- **diagnostic:** `TierUnavailable`, only with `force_tier` (section 2);
- **nothing produces them:** `EmptyGroup`, `EmptyAlternation` (an empty group or
  alternative is valid ECMA-262), `TooManyGroups`, `UnsupportedNode`.

`UnexpectedEOF` has no producer either; it is `SYNTAX` by what it names.

`ZREGEXP_ERROR_INVALID_GROUP` (5) has no Zig error behind it: the C API sets it when a group
index or name is out of range.

**`ExecError`** has 8: `OutOfMemory`, `StepLimitExceeded`, `BacktrackStackExhausted`,
`InvalidIndex` (an index inside a character or past the end), `SlotsTooSmall`, and three a
compiled program never produces (`UnknownOpcode`, `UnexpectedEndOfBytecode`,
`InvalidCharSet`).

**What each function can fail with:**
- `Regex.compile`, `compileWithOptions`, `matchFull`, `test_`, `find`, `findAt`, `findFrom`,
  `findAll`, `replace`, `replaceAll` and the one-shot functions: `RegexError`;
- `Regex.execAt` and `MatchIterator.next`: `ExecError`;
- the rest (`deinit`, `getPattern`, `groupCount`, `slotCount`, `advanceIndex`, `iterator`,
  `MatchResult`'s getters): nothing.

## 4. What is a breaking change

**Breaking** (only in a major release, after a deprecation; section 5):
- removing or renaming a stable symbol, method, field or C symbol;
- changing a signature, a field's type, or `ZRegexOptions`'s layout;
- changing what a stable function does on a pattern that compiles (except to fix a
  divergence from ECMA-262 or from V8, which is a bug fix);
- adding an error to `RegexError` or `ExecError`, or giving a new error to a pattern that
  compiled;
- changing an error's C code.

**Not breaking** (any release):
- adding a stable symbol or method;
- adding a `CompileOptions` or `ExecLimits` field with a default that keeps today's behavior;
- implementing something that was `UnsupportedFeature`;
- fixing a result that differs from ECMA-262 or V8;
- anything in `zregex.internal` or in the diagnostic fields;
- performance, memory and executor changes that keep the results;
- doc comments and documentation.

## 5. Deprecation

A stable symbol that will go is marked with a doc comment `/// Deprecated: use X.` and stays
at least one minor release (`0.x` → `0.x+1`, or `1.x` → `1.x+1`) before it is removed. The
release notes list it in both releases.

## 6. Enforcement

- **The root's 19 declarations** (`tests/regression_tests.zig`, "F7c-4"): a new root symbol, or
  one gone, fails the test until this file and the list change together.
- **`RegexError`'s 35 errors and `ExecError`'s 8** are fixed by the same test.
- **The table of section 3** is checked against the C API's mapping, and one pattern per
  `SYNTAX` error of the frontend, plus a limit that stays `UNKNOWN`, go through
  `zregex_compile` (`src/c_api.zig`, "F7c-4").
- **`zregex.internal`:** the F7c-3 test keeps the internal symbols out of the root.
