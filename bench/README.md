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

One run moves by ±15 % on this machine, so a comparison is:

- **10 runs of each version, interleaved** (A, B, A, B, ...), so drift in the machine
  hits both alike. The base goes in a separate directory (`git archive <commit>`).
- **The median of the 10 per case.** The measured resolution is about 5 %; below that a
  difference is noise.
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

Summary: `execAt` MB/s, median of 10 interleaved rounds (min–max bands and the
other metrics — findAll, V8 cold, ns per short exec, compile, bytes — in docs/BENCHMARKS.md).
zig-regex has no execAt API and a quadratic findAll: it isn't in these tables.

| T0 case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| `literal hello` | 943.1 | 1791.8 | 20999.1 |
| `[a-z]+` | 214.8 | 116.7 | 75.0 |
| `\d{3}-\d{4} (sparse)` | 644.7 | 1342.9 | 2319.2 |
| `\d{3}-\d{4} (dense)` | 42.5 | 222.8 | 85.0 |
| `email` | 45.5 | 87.8 | 778.0 |
| `(\d{3})-(\d{4}) (sparse)` | 358.9 | 1629.6 | 1493.7 |
| `(\d{3})-(\d{4}) (dense)` | 33.6 | 198.5 | 76.5 |
| `(?:(a)\|b)*c` | 15.5 | 37.2 | 58.4 |
| `book: Darcy` | 885.5 | 15514.4 | 19231.8 |
| `book: [A-Z][a-z]+` | 400.7 | 622.9 | 290.1 |
| `book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` | 681.5 | 532.0 | 2662.5 |

| T1 case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| `\p{L}+ /u` | 30.1 | 48.8 | 85.1 |
| `\p{Script=Greek}+ /u` | 32.2 | 100.7 | 252.6 |
| `\p{General_Category=Lu} /u` | 26.5 | 61.8 | 204.1 |
| `[\p{L}--[a-z]] /v` | 25.6 | 36.6 | n/a |
| `book: \p{L}+ /u` | 24.7 | 34.2 | 67.7 |

| T2 case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| `<(\w+)>.*?<\/\1>` | 33.8 | 262.1 | 276.3 | 69.6 |
| `(?=.*[a-z])(?=.*[A-Z]).{8,}` | 3.8 | 54.8 | 70.3 | 10.9 |
| `(?<=\$)\d+` | 0.8 | 233.2 | 1073.6 | 529.1 |
| `book: \b(\w+) \1\b` | 11.4 | 134.1 | 112.3 | 31.9 |

Notes:

- V8 has a JIT; z-regex doesn't. Both are real.
- Rust regex doesn't support backreferences; the T2 cases are not compared against it.
- Absolute numbers vary with LLVM's code layout between builds. Median of 10 runs.
- z-regex T0 has 0 divergences from V8 in test262 and in the differential. The 477
  divergences are T2/T1.
