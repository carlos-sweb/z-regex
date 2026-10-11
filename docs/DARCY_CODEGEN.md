# Investigation of the `book: Darcy` regression

**Status: open upgrade gap; the candidate-verification workaround was removed.**

The historical regression on the real book corpus has the same cause as
`literal hello`: Zig 0.17 generates extra stack reloads in the shared literal
scan. A `noinline` candidate verifier restored sparse-book throughput but
introduced a confirmed regression on an artificial dense-rejected-candidate
corpus (`Dxxxy` repeated). That tradeoff is why the helper is not retained.
The Zig 0.17 API migration remains, with direct `std.mem.eql` verification.

All helper-build results below are historical experiments. They do not
describe the current unpatched source. The artificial case must not be
confused with the original book measurement. See the
[upgrade-gap index](ZIG_0.17_UPGRADE_GAPS.md) and the
[hello investigation](LITERAL_SEARCH_CODEGEN.md).

## Scope and method

- `t0_book_name`: pattern `Darcy`, no flags, original `book.txt`, 724,725 bytes, WTF-8/u8, code-unit mode, literal prefilter, two slots, not sticky.
- Route: `Regex.execAt → tier0.exec → literalSearch → findLiteralWith`. It uses 32-byte AVX2 vectors on `x86_64_v3`; it does not run the general VM, DFA, or backtracker.
- Each real-book pass has 418 searches, 22,802 vector blocks, 463 candidate comparisons, 417 matches, and 27 scalar-tail positions without interior comparisons. The verifier checks `arc` after the scan checks `D` and `y`.
- Three controls: the v0.9.0 Zig 0.16 baseline, the archived Zig 0.17 binary before the experimental helper, and the experimental Zig 0.17 binary with the helper.
- Same Intel Core i3-10100F host, ReleaseFast, `x86_64_v3`, logical CPU 2. Ten alternating/rotating rounds. Timing was separate from compilation, correctness checks, and Callgrind.
- Original harness tested with only Darcy and with hello followed by Darcy. Isolated probes tested direct search, fixed width, independent comparison, tier0 execution, execAt, iterator, and findAll. Blocks were calibrated to at least 100 ms, with equal repetition counts across versions.
- The experimental isolated probe was compiled from a fresh copy of the actual workspace source. All investigation changes and artifacts are under `/tmp/z-regex-darcy-study`.

## Original real-book results

Throughput in MiB/s. Each cell is median / best of ten rounds; the best-round estimator follows the repository benchmark policy.

| Interface | Zig 0.16 | Zig 0.17 before helper | Zig 0.17 helper build | Helper-build best-round time difference vs 0.16 |
|---|---:|---:|---:|---:|
| execAt | 16,152.9 / 16,472.1 | 13,936.5 / 13,955.9 | 16,203.5 / 16,631.8 | -0.96% |
| iterator | 16,067.9 / 16,511.0 | 13,769.6 / 13,944.9 | 16,241.0 / 16,658.3 | -0.88% |
| findAll | 10,871.4 / 11,069.6 | 9,495.9 / 9,784.6 | 10,250.0 / 11,006.8 | +0.57% |

The old slowdown is reproducible before the helper. After it, execAt and iterator return to approximately the 0.16 baseline in both harness contexts. findAll has lower medians in this run (about 3–6% additional time depending on context), but its best results differ by less than 1%, and the isolated long-block difference is about 4%. An independent findAll regression greater than the repository threshold of 10% was not confirmed. This is not evidence that allocation has zero cost or that every median must match.

The short `Mr. Darcy` input remains close to baseline: medians 20.485 ns (0.16), 20.755 ns (pre-helper 0.17), and 21.435 ns (helper build). Compile medians are 1.3915, 1.1910, and 1.1950 µs; compiled live bytes remain 185. No >10% short-input regression was established.

## Source dissection and profiling

The actual call path uses the same std functions as hello. Local primary-source comparison confirms identical implementations of `suggestVectorLengthForCpu`, `eqlBytes`, and `sliceAsBytes` across the installed 0.16.0 and 0.17.0 libraries. Both select byte comparison for u8; the changed float fallback in `eql` does not participate. `indexOfPos` and the single-unit search are not executed for this five-unit pattern with a non-null vector width.

The original executed scan block has five stack loads in 0.16, nine before the helper in 0.17, and five with the experimental helper. Callgrind observed 402,930 executions of each of these loads in the book scan. Disassemblies and per-instruction evidence are saved in `016.asm`, `017-before.asm`, `017-current.asm`, and `hot-scan.json`. Both versions still emit `vpbroadcastb` for the first/last bytes.

Direct search profile: 100 fixed passes plus one warm-up; the million short-input calls in the original harness are excluded.

| Event | Zig 0.16 | Zig 0.17 before | Zig 0.17 helper build |
|---|---:|---:|---:|
| Instructions | 44,241,939 | 48,571,910 | 44,348,595 |
| Data reads | 17,015,268 | 21,489,972 | 17,015,268 |
| Data writes | 939,098 | 896,880 | 943,542 |

Pre-helper 0.17 adds 9.79% instructions and 26.30% reads. The experimental helper returns the read count exactly to baseline. This reproduces the mechanism established for hello.

The exact Zig/LLVM commit or pass that introduced this arrangement was not identified. Callgrind cache/branch events are simulated and do not measure hardware cycles. Original-harness profile totals include 1.11 million short calls, so they must not be used as the long-book cost without separating the executed scan block.

## Isolated timings

Median µs per real-book pass, all results checked against the scalar reference:

| Layer/control | Zig 0.16 | Zig 0.17 before | Zig 0.17 helper build |
|---|---:|---:|---:|
| direct | 38.697 | 41.897 | 38.689 |
| fixed32 | 40.455 | 43.818 | 40.815 |
| nolib | 33.839 | 34.245 | 34.094 |
| vm | 42.636 | 46.319 | 43.065 |
| exec | 44.769 | 48.922 | 45.366 |
| iter | 44.702 | 48.781 | 47.062 |
| findall | 68.008 | 72.225 | 70.962 |

The first slowdown appears in direct search; it does not require iteration or allocation. Fixing the width does not remove it. The independent comparison control remains close between compilers. A standalone kernel without the regex-engine context also does not reproduce the original slowdown:

- 016/std: 37.780 µs/pass.
- 016/nolib: 31.828 µs/pass.
- 017/std: 36.089 µs/pass.
- 017/nolib: 32.508 µs/pass.

## Confirmed dense-false-candidate regression

The artificial corpus is 724,725 bytes of `Dxxxy` repeated, with zero matches. It retains the same pattern and flags, but produces 120,787 failed interior comparisons instead of the real book's 46 failures. It requires 22,647 vector blocks. This is a distinct stress condition, not a second measurement of the novel.

The original harness was run unchanged against a temporary corpus directory containing this input as `book.txt`. Ten rotating rounds confirmed the slowdown:

| Interface | Zig 0.16 best MiB/s | Pre-helper 0.17 best MiB/s | Helper-build 0.17 best MiB/s | Helper-build time increase vs pre-helper |
|---|---:|---:|---:|---:|
| execAt | 1,980.4 | 1,999.6 | 1,691.6 | +18.21% |
| iterator | 1,980.4 | 1,999.4 | 1,691.6 | +18.20% |
| findAll | 1,979.4 | 1,998.7 | 1,688.2 | +18.39% |

Direct-search profile of this input, 20 fixed passes plus warm-up:

| Event | Zig 0.16 | Pre-helper 0.17 | Helper-build 0.17 |
|---|---:|---:|---:|
| Instructions | 116,526,879 | 110,978,154 | 133,331,121 |
| Data reads | 28,695,492 | 27,110,202 | 28,695,492 |
| Data writes | 5,073,726 | 5,073,705 | 7,610,211 |

The experimental helper adds 20.14% instructions and 49.99% writes versus pre-helper 0.17. Here, saved scan reloads cannot amortize the extra verifier-call work: rejected candidates dominate. The helper performs its own frame/slice preparation and tail-calls the general `eqlBytes` implementation. The independent-comparison control remains around 120 µs/pass, rather than the experimental approximately 430 µs/pass, showing that the extra generic comparison/call work can be avoided experimentally.

A possible next experiment is to retain the boundary that protects the scan while handling tiny interiors directly inside the helper, avoiding the second generic comparator call. Compare it against a standalone loop verifier and validate both real and dense-false corpora, hello, two-unit needles with empty interiors, UTF-16, and longer literals. This is a candidate approach, not a measured solution or an applied patch. The previous inline-inside-the-scan experiment is insufficient because it affected scan code generation adversely.

## Correctness and disposition

Each of the three versions passed 10,038,336 alignment/length/position/start combinations for Darcy and exact verification of all 417 real-book match positions through iterator and findAll. Every layer/control also matched reference counts and position checksums on original, absent, dense, false-candidate, and vector-boundary inputs; experimental execAt additionally passed all 32 input offsets on each fixture.

During the diagnostic study, the workspace diff and status remained unchanged.
The study stopped after confirming the dense-false-candidate regression.
The subsequent disposition is to remove the candidate verifier and retain
only the compiler/API migration. Thus the original real-book regression
remains open; the additional helper-induced stress regression is evidence
against reintroducing that workaround, not a gap in the unpatched build.
No complete replacement has been validated, and v0.9.1 ships with this known upgrade gap.

## Artifacts

- `metadata.json`, `reference.json`, `instrumentation.json`, `verification.json`, `workspace-check.json`.
- `original-rounds.json`, `original-summary.json`: actual book results, both working-directory contexts.
- `probe-rounds.json`, `probe-summary.json`: timed layers and synthetic controls.
- `profile-summary.json`, `hot-scan.json`, `*-cg-*.out`: profiles and actual executed loads.
- `false-original-rounds.json`, `false-original-summary.json`, `false-profile-summary.json`: confirmed stress regression.
- `minimal-rounds.json`, `minimal-summary.json`: standalone controls.
- `setup.py`, `prepare_probe.py`, `timing.py`, `verify.py`, `profile.py`, `false_check.py`, `false_profile.py`, `minimal_check.py`, `hot_scan.py`: scripts used for this investigation. The experimental-probe build uses the explicit Zig 0.17 executable with a separate cache and `-Dcpu=x86_64_v3`.

The raw artifacts reside in `/tmp/z-regex-darcy-study` and are temporary. The findings, numerical evidence, and disposition are retained in this repository report; reading it does not require those local files.
