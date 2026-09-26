# Performance baseline

`zig build bench` runs `bench/bench.zig` (always ReleaseFast): throughput cases
(`Regex.findAll` over a deterministic 1 MiB input, median of up to 5 timed runs) and
adversarial cases (time until the engine gives up). See the header of `bench.zig` and
`docs/REGEX_TIERS_PLAN.md` §7.2.

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
