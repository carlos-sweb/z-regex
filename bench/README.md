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
