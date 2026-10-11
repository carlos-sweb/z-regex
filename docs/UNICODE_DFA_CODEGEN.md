# Zig 0.17 regression investigation: `\b\p{Lu}{5}\b /v`

## Finding and status

The short-input regression is reproducible. On `abc ABCDE`, the original
harness measured 39.405 ns with Zig 0.16 and 45.115 ns with the investigation-time
Zig 0.17 control: **14.49% more time** by median, and 14.98% by best result.
The match is `[4, 9]` in UTF-8 byte offsets.

The regression is localized to the context-sensitive DFA, especially its
forward scan and the generated code that maintains an optional match end.
This is a different mechanism from the literal-search stack reloads seen
for `hello` and `Darcy`.

A temporary representation change provides causal evidence but only partial
recovery. It does not constitute a validated fix. The diagnostic study itself made no
project source or release changes.
Its findings are now retained as an open upgrade gap. The project keeps the
Zig 0.17 API migration without performance workarounds; the literal-search
helper was subsequently removed. No sentinel or `noinline` forward experiment
was ever applied to project source. v0.9.1 ships with this known upgrade gap.

See the [upgrade-gap index](ZIG_0.17_UPGRADE_GAPS.md). Helper-build labels in historical
tables refer to the binary at investigation time, which still contained the
literal helper; they are not fresh results
for the current unpatched source.

## Scope and controls

- Same host as the earlier investigations; Intel Core i3-10100F.
- ReleaseFast, `-Dcpu=x86_64_v3`, explicit Zig 0.16/0.17 executables.
- Original Zig 0.16 baseline, archived pre-patch Zig 0.17 binary, and the investigation-time
  Zig 0.17 control containing the experimental literal-search helper.
- Twelve interleaved rounds for each original-harness comparison, with
  rotated process order; separate ten-round isolated-layer comparison.
- Timing runs used no concurrent profiling or builds in the final layer
  comparison and original-harness experiments. Earlier exploratory layer
  runs were superseded by the final `layer-rounds.json`.
- Runtime pattern and input arguments in isolated probes; `doNotOptimizeAway`
  protects the context; each timing block lasts at least 150 ms.
- Independent checkout caches, especially for Zig 0.16, avoid stale artifacts.

Artifacts and executable hashes are recorded in `metadata.json`. Original
binaries remain untouched. Archived `016-layer-probe` and `017-layer-probe`
preserve the isolated timing/verification binaries before adding a table-dump
mode to the temporary checkout harnesses.

## Actual execution route

`Regex.execAt` → `Regex.exec` → `tier0.exec` → `pikevm.dfaSearch`
→ `Dfa.find` → `Ctx.find` → `Ctx.forward` → `Ctx.backward`.

The compiled program has two slots, code-point mode (`v`), a DFA with
assertion-context tables, and `dfa_skip == .none`. The isolated probe checks
these conditions at startup. Tier label T1 describes the pattern's Unicode
requirements; execution uses the DFA implementation in `src/tier0/dfa.zig`.

On the nine-byte short input:

- Nine forward character transitions, plus an end-of-input transition.
- Six reverse character transitions to recover start position 4.
- Every processed character is ASCII. Classification uses `d.ascii` directly.
- No Unicode-range binary search or UTF-8 multibyte decoding is executed.
- The literal prefilter, `candidateEqual`, the Pike VM thread walk, and the
  backtracker are not executed.
- Warm execution does not allocate; compilation and collection allocation
  are outside the measured short-input loop.

`dfa.zig`, `pikevm.zig`, and `subject/root.zig` are byte-for-byte identical
between the baseline source and the project source (`source-comparison.json`).
The generated DFA tables are also identical: 18,957 serialized bytes,
SHA-256 `13b5310b069a7d0369e683f88a2551ea6c0bb4ae71415fc6fe72e5db0f777c0f`
(`table-comparison.json`). The dump includes classification/cut tables,
forward/reverse transitions, assertion contexts, start states, and dimensions.
This rules out different compiled table contents as the explanation here.

## Original-harness results

Initial focused comparison, medians across twelve rounds:

| Metric | Zig 0.16 | Zig 0.17 before literal patch | Zig 0.17 helper-build control |
|---|---:|---:|---:|
| Short execAt, ns | 39.405 | 45.045 | 45.115 |
| Corpus execAt, MiB/s | 255.421 | 237.467 | 260.422 |
| Corpus iterator, MiB/s | 257.256 | 236.990 | 264.058 |
| Corpus findAll, MiB/s | 248.062 | 224.498 | 250.378 |
| Compile, µs | 195.130 | 187.553 | 189.176 |

All builds report 931 corpus matches and 24,586 live compiled bytes.
The investigation-time binary's long-corpus performance is near or above the baseline;
the remaining confirmed regression concerns short execution. Long-input
results must not be used to conclude that short execution recovered.
The literal helper is not called by this route, so the long-input improvement
between the two Zig 0.17 binaries does not establish an algorithmic repair
of this DFA; surrounding code/layout changes can affect these measurements.

## Isolation of API and engine costs

Final ten-round calibrated probe, median ns per call:

| Entry point | Zig 0.16 | Zig 0.17 |
|---|---:|---:|
| Public API | 42.130 | 48.962 |
| Direct tier0.exec dispatch | 40.249 | 42.786 |
| Direct DFA, no skipper | 28.460 | 32.006 |

The direct DFA is 12.46% slower, even after bypassing public API dispatch,
subject normalization, scratch ownership, and slot validation. Absolute
numbers differ from the original harness because this probe has a noinline
call boundary and checks match bounds. Do not subtract timings from separate
entry-point specializations as if they had identical generated code.

## Machine-code evidence

Callgrind collection toggled only around the original harness's
`pikevm.dfaSearch*` calls. A temporary corpus containing `abc ABCDE` makes
both corpus and short-input calls exercise the same short route. Timing under
Callgrind is not used as a hardware-performance result.

| Binary | Instructions (Ir) | Conditional branches (Bc) |
|---|---:|---:|
| Zig 0.16 | 406,267,092 | 58,830,996 |
| Zig 0.17 before patch | 421,807,368 | 58,830,990 |
| Zig 0.17 helper-build control | 421,807,368 | 58,830,990 |

Zig 0.17 adds about 14 instructions per successful short search, roughly
3.8% more instructions in the collected region. This percentage is not the
wall-time slowdown: dependencies and instruction placement also matter.
The reverse function's exclusive count is exactly 137,642,232 in both builds;
the additional work is in the forward search and its surrounding code.

The hot source is `Ctx.forward` (`src/tier0/dfa.zig:669,694`):

```zig
var end: ?usize = null;
// ...
if (e & emit != 0) end = pos;
```

Zig 0.17 carries the optional's presence flag through an additional register
move at the top of every forward iteration (ten executions for this input).
Its transition update uses `sets`, `cmovs`, and `or` to merge the presence
flag, with additional work at end of input. Zig 0.16 uses a different
`movzx`/`cmovs` selection and has no corresponding top-of-loop flag move.
The investigation-time Zig 0.17 DFA search also executes a `vzeroupper` at return.

Selected addresses in the original binaries:

- Zig 0.16 forward ASCII block: `0x10fc2d0`; loop header `0x10fc302`.
- Zig 0.17 helper-build forward ASCII block: `0x11030a0`; loop header `0x11030d0`.
- Additional Zig 0.17 loop-header flag move: `mov r15d, ecx`.
- Reverse ASCII transitions retain the same executed instruction structure.

`016-executed.asm` and `017-current-executed.asm` annotate instructions with
observed execution multiplicity. Full disassembly, Callgrind dumps, and
exclusive annotations are included. No specific LLVM optimization pass or
compiler commit has been identified.

## Standard-library and @splat review

The actual hot forward/reverse path uses project code, scalar arithmetic,
array indexing, and prebuilt DFA tables. It does not call `std.mem.eql`,
`std.mem.indexOf*`, standard-library Unicode decoding, or SIMD selection.
The `std` containers, sorting, hashing, and allocations in DFA construction
run during compilation, which is timed separately and is faster here with
Zig 0.17. Identical compiled tables further separate construction from the
execution regression.

The timer is outside the profiled search. Isolated direct-DFA timing also
reproduces the slowdown, and the instruction-count difference does not
depend on the timer. There is no evidence that a changed std algorithm
causes this particular short-input regression.

The earlier no-array-splat Zig 0.17 experiment produced identical loaded
binary sections. In this route, existing DFA `@splat(.empty)` initializers
are construction-time list initialization. No candidate-comparison splat or
new initialization executes in the short loop. The observed forward-loop
regression is therefore not supported as an @splat-related failure.

## Temporary causal experiments

Experiments were confined to `/tmp/z-regex-lu5-study`.

1. Replace the internal optional `end` with a `usize` sentinel and convert
   back to `?usize` only at function return (`sentinel.patch`). This avoids
   maintaining an optional-presence flag on every transition. Public return
   types and behavior remain the same for tested inputs.
2. Keep the optional but make `Ctx.forward` noinline.
3. Combine the sentinel representation and the noinline boundary.

Sentinel comparison, twelve rounds, median ns:

| Build | Short ns |
|---|---:|
| Zig 0.16 control | 38.600 |
| Zig 0.17 helper-build control | 45.965 |
| Zig 0.17 sentinel experiment | 43.045 |

The sentinel improves time by 6.35% relative to its concurrent control, but
remains 11.52% slower than Zig 0.16. Its collected instruction count drops
to 377,406,624, below the baseline count, yet it is still slower in wall time.
This proves that removing the optional flag work contributes to recovery,
while instruction count alone does not explain the remaining gap. Changes
in register dependencies and code layout remain candidates for that gap;
they have not been independently proven.

Separate boundary comparison, twelve rounds, median ns:

| Build | Short ns |
|---|---:|
| Zig 0.16 control | 39.300 |
| Zig 0.17 helper-build control | 44.790 |
| Zig 0.17 noinline forward | 47.650 |
| Zig 0.17 noinline forward + sentinel | 52.255 |

The call boundary is counterproductive here. It must not be recommended
merely because a boundary helped literal search.

## Correctness and possible next solution

- 201 deterministic ASCII/Unicode inputs, including absent matches, exact
  bounds, longer/shorter uppercase words, punctuation, accented characters,
  Greek uppercase, and astral uppercase characters.
- 1,206 checks across API, tier0 dispatch, and direct DFA under both compilers.
- All agree with Node/V8 `/\b\p{Lu}{5}\b/v`; reference UTF-16 offsets are
  converted to UTF-8 byte offsets before comparison.
- The isolated sentinel checkout passes `zig build test --summary all`:
  21/21 steps succeeded; 924/939 executed tests passed, 15 skipped.
- Every original-harness experiment preserves the 931 corpus matches.

A reasonable next optimization direction is to avoid carrying the optional
presence flag through each forward transition, then examine the resulting
ASCII dependency chain and code placement. The sentinel experiment is an
initial candidate, not a permanent patch recommendation. Its remaining
regression exceeds the release threshold, and making forward noinline is
already rejected by the measurements.

Any future fix needs controls for this short input, the long Unicode corpus,
sticky searches and nonzero indices, no-match inputs, UTF-16/malformed input,
other assertion patterns, and the previously identified literal false-candidate
regression. The exact compiler-level cause of the residual gap is open.
No complete fix has been validated; no experimental performance change is retained and v0.9.1 ships with this known upgrade gap.

## Evidence provenance and reproduction artifacts

The scripts and raw evidence listed below reside in `/tmp/z-regex-lu5-study`
and are temporary local artifacts. They are not required to read the findings
and tables preserved in this report.

- `run.py`, `original-rounds.json`, `original-summary.json`: original controls.
- `layers.py`, `layer-rounds.json`, `layer-summary.json`: final isolated timing.
- `profile.py`, `profile-summary.json`: original machine-code profiles.
- `experiment.py`, `experiment-summary.json`: sentinel experiment.
- `boundary.py`, `boundary-summary.json`: function-boundary experiments.
- `experiment_profile.py`, `experiment-profile-summary.json`: profile controls.
- `verify.py`, `verification.json`: independent V8 comparison.
- `source-comparison.json`, `table-comparison.json`: source/table controls.
- `metadata.json`, `findings.json`, `test-summary.txt`: provenance and findings.
