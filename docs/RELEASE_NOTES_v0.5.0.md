# z-regex v0.5.0

Four pieces since v0.4.0: F7a (correctness), F7b (performance and size), step 1 of F6b
(B′, fixed-length lookbehind) and error names in the C API. Details and measurements are in
`docs/KNOWN_LIMITATIONS.md` ("Fixed in F7a", "F7b closed", "F6b step 1 (B′)"), and the plan
is in `docs/plans/F7.md`.

## F7a: correctness

- **Bug E (D17).** Without `u`/`v`, `\u{H+}` was read as a code point escape. It is now
  Annex B's identity escape: `u` followed by a quantifier when one forms, and text
  otherwise. `/\u{2}/` matches "uu".
- **Bug D.** With `u`/`v`, an index inside a surrogate pair started at the trail half. It
  now starts at the pair, in UTF-16 and in WTF-8.
- **Item 13.** On the backtracker, quantified groups now follow RepeatMatcher steps 4 and
  2.b:
  - Step 4: each iteration starts with the captures inside the atom undefined.
  - Step 2.b: an empty iteration above the minimum fails.
  - The two steps shipped together because step 4 alone made 5 differential cases worse.
- **Loop guards.** Past 64 guards, a hash set mirrors them, so long loops are linear.
- **Results:**
  - test262: 2978 → 2980.
  - `differential-v8`: 470 different results → 0; `StepLimitExceeded` 17 → 2.
  - Internal differentials against T0's VM: 0 differences.

## F7b: performance and size

Six items, one commit each:

- **Guard.** The loop guard's set is `GuardSet`, a LIFO linear-probing table.
- **Compile cost.**
  - Three local costs removed: −30 % to −39 % instructions per compile on small patterns
    with a class or a property (callgrind).
  - `compile` no longer runs the `Optimizer`, which only copied the bytecode.
- **LookLinear under `iu`.** Lookaheads under `i` in code-point mode are delegated to T0's
  VM: 7,234 → 7,264 delegated sites, 0 differences.
- **C API `max_steps`.** The C API applies `ZRegexOptions.max_steps`.
- **Binary.** One measuring procedure, `scripts/measure_binary.sh`. F7b's own change in
  ReleaseFast is −2,240 B.
- **Performance criterion since F7b.** A regression is declared when the bench and callgrind
  (or a probe that reproduces the context) both show it.

## B′ (F6b step 1): fixed-length lookbehind

- **What runs now.** A lookbehind whose body has a fixed length L and no capture runs on the
  explicit-stack backtracker:
  - It steps back L characters: code units without `u`/`v`, code points with them.
  - It matches the body forward from there and requires it to end where the lookbehind
    stands (`LOOKBEHIND_FIXED` / `NEGATIVE_LOOKBEHIND_FIXED`).
  - There is no reverse code generation. LookLinear delegates such a body to the VM.
- **`recursive_matcher.zig` is retired.** Every pattern runs on the explicit-stack
  backtracker. The state and the atom checks moved to `core.zig`. Patterns with a lookbehind
  now also get F7a's steps 4 and 2.b.
- **Other lookbehinds are rejected at compile time** with `error.UnsupportedFeature`:
  - variable length;
  - a capture inside;
  - a backreference inside;
  - a variable-length lookbehind inside a `{0}`.

  In the C API this is `ZREGEXP_ERROR_UNSUPPORTED = 9`; no new symbol was added.
- **Against V8** (5,580 corpus patterns with a lookbehind):
  - Fixed-length patterns with a difference: 18 → 7, none new.
  - The 11 fixed ones differed only in a capture outside the lookbehind.
  - The 7 left: 3 not caused by the lookbehind, 3 V8 matches inside a surrogate pair (a
    documented divergence), and 1 `v` with `i` (F5c).
- **Binary** (ReleaseFast): −23,056 B.

## test262: 2980 → 2968

The 12 entries that stop passing come from 6 files, each in sloppy and strict mode:
`built-ins/RegExp/lookBehind/{alternations, back-references, do-not-backtrack, misc,
nested-lookaround, sliced-strings}.js`. Each file contains at least one lookbehind of
variable length or with captures. Such a pattern is now `UnsupportedFeature` at compile time
instead of running on the recursive matcher.

- The recursive matcher passed these 12, but it had defect D7: a 100-character window, and no
  RepeatMatcher steps 4 and 2.b.
- Retiring it and reporting the error was an approved decision (D7).
- All 30 lookbehind entries that don't pass are `UnsupportedFeature`; none fails at run time.
- Full F6b (matching backward, variable length and captures) lifts the error. It recovers
  these 12 and the other 18 lookbehind entries: 2968 + 30 = **2998**. It is mandatory:
  lookbehind is ES2018.

## C API: error names

Every exported function now records the failure's name for `zregex_last_error_name`:

- `setZigError` records the Zig error's name.
- When only a code is known, a code → name table supplies it (for example `InvalidGroup`).
- There is one test per function, including the out-of-memory paths.
- `zregex_version()` now returns the package version (`"0.5.0"`) instead of a fixed
  `"1.0.0"`.

## Numbers

| | v0.4.0 | v0.5.0 |
|---|---|---|
| test262 (UTF-16 and WTF-8) | 2978/3017 | 2968/3017 |
| `differential-v8` differences | 470 | 0 |
| ReleaseFast `.so` (`measure_binary.sh`) | 1,113,232 B | 1,096,512 B (−16,720) |
| ReleaseSmall `.so` | 708,104 B | 696,488 B (−11,616) |
| Exported symbols | 40 | 40 |

The binary change breaks down by phase: F7a +8,176, F7b −2,240, B′ −23,056, C API +400.

The cross-engine benchmarks (`docs/BENCHMARKS.md`, `bench/results.json`) are still the
0.3.0 measurements, marked †. They are re-published in F7c.
