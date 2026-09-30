# Performance baseline

`zig build bench` runs `bench/bench.zig` (always ReleaseFast): throughput cases
(`Regex.findAll` over a deterministic 1 MiB input, median of up to 5 timed runs) and
adversarial cases (time until the engine gives up). See the header of `bench.zig` and
`docs/REGEX_TIERS_PLAN.md` §7.2.

Since F4a it also reports, in separate tables:

- **`execAt`** per throughput case: a loop of `execAt` + `advanceIndex` with a warm
  `Scratch` (no allocation, what a host runs), on the executor the dispatcher picks, on
  T0's VM without prefilters (`t0_prefilters = false`) and on the backtracker
  (`force_tier = .expert`), with the compile time of the dispatcher and of the
  backtracker alone. §7.2's T0 targets are read here: `findAll` allocates per match and
  hides the executor.
- **Overhead**: ns per `execAt` of `/abc/` on 5 B and on 2 KB (and two more cases), per
  executor, with the ratio to the backtracker (§7.2: ≤ 1.5× under 64 B, ≤ 1.2× from 1 KB).
- **Compile**: the dispatcher against the backtracker alone, for a pattern with the
  literal prefilter, one with `first`, and a T0 pattern the VM doesn't take (§7.2:
  ≤ 2×).

Since F4b the cases with groups run on the tagged VM (D5's two passes): four throughput
cases (`(\d{3})-(\d{4})` sparse and dense, `(\w+)@(\w+)\.com`, `(?:(a)|b)*c` on the
`ab_runs` input), whose `execAt` row adds **Without groups**: the routed throughput of the
same pattern without its groups (§7.2: with captures ≥ 50% of it); three overhead and
three compile cases with groups; and the count of D5 fallbacks to the backtracker
(`two_pass_fallbacks`, must be 0). Engines read "tagged VM" for a tagged program.

The JSON has them under `exec_at`, `overhead`, `compile` and `two_pass_fallbacks`. To run only some
throughput cases, run the bench binary by hand with a second argument: the cases whose
name contains it (`bench out.json '<'`).

## Comparing two versions

A case moves by ±20% from one process to the next on this machine, so a comparison is:

- **10 runs of each version, interleaved** (A, B, A, B, ...), so drift in the machine
  hits both alike. The base goes in a separate directory (`git archive <commit>`).
- **The best run per case** (the minimum time, the maximum MB/s), not the median: since F7-0
  two series of 10 differ by ~4% (p90) on the best run and by ~20% on the median
  (docs/BENCHMARKS.md, "Precision"). A flag still needs callgrind or a probe to confirm it
  (F7b's criterion).
- **Nothing else runs meanwhile.** Don't compile or run tests while a bench runs: the
  build competes for the CPU and skews the numbers (it happened in F3c, and that run was
  thrown away).

## Thresholds

- A case worse than the resolution is reported with its numbers and range.
- **ASCII cases** (literal, `[a-z]+`, `\d{3}-\d{4}`, email, the backreference and
  lookbehind cases on ASCII input): from F3d on, a slowdown above 10 % is a bug, not
  an accepted regression. The subject mode (code units or code points) only affects
  surrogates and astral characters, so no ASCII pattern should take the new path.

## Cross-engine

`bench/compare/` measures z-regex against V8, Rust regex, PCRE2 and zig-regex, tier by tier
(`prepare.sh`, then `node bench/compare/run.mjs 10` and `node bench/compare/analyze.mjs`;
raw aggregated numbers in `bench/results.json`). The full tables, the method, the machine and
the analysis are in **[docs/BENCHMARKS.md](../docs/BENCHMARKS.md)**.

A second z-regex (another build of `zregex_xbench`, e.g. the last published version) runs in
the same rounds as engine `zregex_base` when `zig-out/xbench/bin/zregex_base_xbench` exists;
`analyze.mjs` then adds a table of the two.

Summary: `execAt` MB/s, the best of 10 interleaved rounds, z-regex at the end of F7c (0.7.0)
built with `-Dcpu=x86_64_v3` (bands and the other metrics — findAll, V8 cold, iterator, ns per
short exec, compile, bytes, adversarial — in docs/BENCHMARKS.md). zig-regex has no execAt API
and a quadratic findAll: it isn't in these tables.

| T0 case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| `literal hello` | 13668.9 | 1809.3 | 19916.7 |
| `[a-z]+` | 195.3 | 77.9 | 59.0 |
| `\d{3}-\d{4} (sparse)` | 473.4 | 909.5 | 1819.2 |
| `\d{3}-\d{4} (dense)` | 34.0 | 172.8 | 84.3 |
| `email` | 36.2 | 79.4 | 705.0 |
| `(\d{3})-(\d{4}) (sparse)` | 244.3 | 1002.5 | 1155.5 |
| `(\d{3})-(\d{4}) (dense)` | 24.8 | 143.7 | 71.5 |
| `(?:(a)\|b)*c` | 13.6 | 29.5 | 51.3 |
| `book: Darcy` | 13284.0 | 8759.7 | 19276.8 |
| `book: [A-Z][a-z]+` | 322.4 | 506.5 | 301.0 |
| `book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` | 527.7 | 460.8 | 2116.5 |

| T1 case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| `\p{L}+ /u` | 40.3 | 38.0 | 67.6 |
| `\p{Script=Greek}+ /u` | 55.6 | 94.2 | 228.9 |
| `\p{General_Category=Lu} /u` | 47.7 | 53.2 | 186.8 |
| `[\p{L}--[a-z]] /v` | 20.1 | 27.1 | n/a |
| `book: \p{L}+ /u` | 38.8 | 26.2 | 53.1 |

| T2 case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| `<(\w+)>.*?<\/\1>` | 28.5 | 176.6 | 207.9 | 65.4 |
| `(?=.*[a-z])(?=.*[A-Z]).{8,}` | 7.5 | 42.0 | 57.6 | 9.1 |
| `(?<=\$)\d+` | 15.1 | 200.5 | 872.8 | 440.3 |
| `book: \b(\w+) \1\b` | 8.9 | 123.6 | 88.7 | 21.6 |

Notes:

- V8 has a JIT; z-regex doesn't. Both are real.
- Rust regex doesn't support backreferences; the T2 cases are not compared against it.
- Against z-regex 0.3.2 in the same rounds: the `u` cases of T1 1.4–2.2× faster (on T0's VM since F5a), the
  lookbehind case ~24× (F6b), the double lookahead 2.4× (LookLinear); everything else within
  ±10% but one z-regex-only cell (docs/BENCHMARKS.md, "Against 0.3.2").
- Measured on one shared container; compare engines within a table, not across machines.

## Binary size

`scripts/measure_binary.sh [--rev REV]` is the one procedure for the size of the library
(F7b): the `.so` built for x86_64-linux with a fixed CPU model (`-Dcpu=x86_64_v3`),
stripped, in ReleaseFast and ReleaseSmall, with its main sections and its `zregex_*`
symbol count. A `native` build follows the host's CPU features, so figures measured that
way differ between hosts (~26 KB on this container: `docs/HISTORY.md`, "Binary size").
