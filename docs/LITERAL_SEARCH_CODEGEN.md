# Literal search code generation on Zig 0.17

**Status: open upgrade gap; no performance workaround is retained.**

The Zig 0.16 → 0.17 migration exposes a throughput regression in the
`t0_literal` benchmark (`hello`). The private `noinline` candidate verifier
investigated below restored sparse-scan throughput, but the subsequent
[Darcy investigation](DARCY_CODEGEN.md) found that it adds roughly 18% more
time on dense rejected candidates. The helper was removed: both verification
sites use `std.mem.eql` directly, while the Zig 0.17 API migration is retained.

This report records historical controls and experiments, not a patch present
in the current source. It describes a performance gap, not a matching failure
or a public API change. See the [upgrade-gap index](ZIG_0.17_UPGRADE_GAPS.md)
for the disposition of all three investigations.

## Execution scope

The investigated case uses the 1 MiB `prose_hello` corpus, WTF-8 input (`u8`),
code-unit mode, no flags, and a literal prefilter with two match slots. Its path
is `Regex.execAt` → `tier0.exec` → `literalSearch` → `findLiteralWith`.
It does not execute the general VM, DFA, or backtracker.

With `x86_64_v3`, both compilers select a 32-byte SIMD vector. The scan compares
each possible start against the needle's first and last units. A candidate for
`hello` has `h` at the start and `o` four bytes later; equality of the interior
`ell` confirms the match. The remaining positions are checked by the scalar
tail. Each original-corpus pass performs:

- 88 search calls and 32,803 SIMD blocks;
- 1,174 interior comparisons and 87 matches;
- nine scalar-tail positions, with no interior comparisons in that tail.

## What changed in the generated code

The installed Zig 0.16.0 and 0.17.0 sources have identical implementations of
`std.simd.suggestVectorLengthForCpu`, `std.mem.eqlBytes`, and
`std.mem.sliceAsBytes`. For `u8`, both versions select the byte-comparison path
of `std.mem.eql`. The changed float handling in its fallback is irrelevant here.
The vector broadcasts were already present before the migration and remain
`vpbroadcastb` in both binaries.

Despite the identical comparison implementation, the generated scan differs.
Zig 0.17 separates paths for empty and nonempty interiors and changes register
allocation around the verifier. In the original benchmark's executed scan
backedge and vector comparison block, stack-load instructions increase from
five to nine per block. These additional loads are paid even when the block
contains no candidate.

The discarded experimental helper preserved the existing comparison:

```zig
noinline fn candidateEqual(comptime Unit: type, a: []const Unit, b: []const Unit) bool {
    return std.mem.eql(Unit, a, b);
}
```

In the experimental build, both the SIMD candidate loop and the scalar tail called it. `noinline` keeps the
verification boundary intact; it does not disable SIMD or optimization inside
the helper. The additional call work occurs at candidates, whereas the
avoided reloads affect the much more frequent scan blocks.

Callgrind measurements of the direct search, with 100 timed passes and one
warm-up pass, corroborate the change:

| Event | Zig 0.16 | Zig 0.17, direct comparison | Zig 0.17, `candidateEqual` |
|---|---:|---:|---:|
| Instructions | 62,396,184 | 68,425,480 | 62,965,117 |
| Data reads | 24,468,967 | 30,958,722 | 24,468,967 |
| Data writes | 416,120 | 407,232 | 525,705 |

The original 0.17 search executes 9.66% more instructions and 26.52% more reads.
The helper restores the read count while adding some call work. Callgrind's
cache and branch events are simulated; these counts are not hardware-cycle
measurements. The exact Zig/LLVM commit or optimization pass responsible was
not identified.

## Timing evidence

The investigation was run on October 10, 2026, on an Intel Core i3-10100F with
Zig 0.16.0 and 0.17.0, ReleaseFast, and `x86_64_v3`. Ten rounds alternated or
rotated executable order, pinned to logical CPU 2. Builds and profiling ran
outside timing sessions. These are median throughputs from the original
cross-engine harness restricted to `t0_literal`, not replacements for the
published cross-engine tables:

| Interface | Zig 0.16 (MiB/s) | Zig 0.17, direct comparison (MiB/s) | Zig 0.17, `candidateEqual` (MiB/s) |
|---|---:|---:|---:|
| `execAt` | 17,073.5 | 14,283.3 | 17,185.7 |
| `iterator` | 17,205.7 | 14,243.7 | 17,312.4 |
| `findAll` | 15,881.2 | 13,759.6 | 16,143.9 |

The unmodified 0.17 version takes 19.53%, 20.79%, and 15.42% more time,
respectively. The helper returns all three to approximately the baseline;
differences below 2% should not be interpreted as a separate speed improvement.

After temporarily adopting the experimental helper, `zig build test --summary all` passed
all 21 build steps, and `zig build xbench -Dcpu=x86_64_v3` succeeded. A fresh
ten-round comparison of the rebuilt binary, the pre-change 0.17 binary, and
the 0.16 baseline confirmed recovery on the same host:

| Interface | Zig 0.16 median (MiB/s) | Helper-build median (MiB/s) | Best-round time difference versus 0.16 |
|---|---:|---:|---:|
| `execAt` | 17,029.7 | 17,184.3 | -0.53% |
| `iterator` | 17,118.8 | 17,321.0 | -0.30% |
| `findAll` | 15,970.3 | 16,403.8 | -0.66% |

All three executables returned 87 matches per original-corpus pass. These
measurements confirm recovery for this case, not release-wide performance
approval.

Controls also established that:

- Fixing the vector width at 32 does not remove the regression.
- Moving the one-unit search branch out of line does not recover throughput.
- Forcing the `std.mem.eql` wrapper inline does not recover throughput; its
  private `eqlBytes` helper can still remain out of line.
- A standalone SIMD reproducer without the regex engine does not show the same
  regression. This is a contextual code-generation issue, not a general claim
  that Zig 0.17 or `std.mem.eql` is slower.
- The difference persists on a corpus with no candidates, but is small or
  absent on dense matches and dense false candidates. Scan cost is decisive.
- Longer timing blocks reproduce the direct-search difference, and the clock
  itself is faster in 0.17. Timer overhead does not explain the regression.

## Validation and maintenance

The investigation checked 10,038,336 alignment, length, match-position, and
initial-index combinations per compiler against a scalar reference. It also
checked complete iterator and `findAll` positions on the original corpus and
on absent-match, dense-match, false-candidate, and vector-boundary corpora.

The repository's existing `findLiteral` tests cover `u8` and `u16`, empty and
one-unit needles, two-unit needles with empty interiors, longer literals,
vector boundaries, and widths of 8, 16, 32, and 64 units plus the scalar
fallback. Run them through the full suite:

```sh
zig build test
zig build xbench -Dcpu=x86_64_v3
```

For focused timing, place a copy of `bench/compare/cases.json` containing only
`t0_literal` under a separate working directory's `bench/compare/` path. Run
each built `zregex_xbench` from that directory with the same absolute corpus
directory argument. Alternate at least ten rounds, check match counts, and
keep compilation and profiling outside those rounds. Compare medians, best
rounds, and dispersion; use profiling to confirm a suspected regression.

## Discarded workaround and remaining work

The candidate-verification boundary is not retained. Its sparse-corpus
recovery does not offset the confirmed dense-false-candidate regression
recorded in the [Darcy report](DARCY_CODEGEN.md). The unmodified Zig 0.17 scan
is accepted as an outstanding upgrade gap, not as performance-equivalent
to the Zig 0.16 baseline.

A future candidate must recover sparse scanning without increasing rejected
candidate cost, and must cover real hello/book corpora, absent matches, dense
matches and rejected candidates, short/long literals, empty interiors,
UTF-16, and vector boundaries. No complete solution has been validated.
The exact compiler optimization pass remains unidentified.

## Evidence provenance

The tables and profiling counts above preserve the October 10, 2026 study.
The initial controls are in `/tmp/z-regex-hello-study`, and the later helper
confirmation is in `/tmp/z-regex-hello-permanent`. These are temporary local
artifacts, not files required to read this report or shipped with the package.
The original cross-engine data are in `/tmp/z-regex-v091-benchmark`.
Historical published benchmark tables remain unchanged.
