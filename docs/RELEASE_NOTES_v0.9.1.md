# z-regex v0.9.1: migrate Zig 0.16 to 0.17

Zig 0.17.0 is now the minimum supported compiler. The public Zig API, the
40-symbol C ABI, error sets and regular-expression semantics are unchanged.

## Migration

- Build paths use `b.path` and `Run.addFileArg2`; command-line arguments use
  `Run.addPassthruArgs`.
- Array initialization uses `@splat`, static bit sets use `.empty`, and integer
  type construction uses `@Int`.
- Reflection consumers use Zig 0.17 declaration names, enum field names and
  values, function attributes and error-set names. This includes test tools.
- Allocation-failure tests disable backing-allocator resizing to keep failure
  indices deterministic. Production allocation and matching code are unchanged.

## Performance and known gaps

The full cross-engine benchmark was rerun on an Intel Core i3-10100F
(4 cores / 8 threads), 31.19 GiB reported RAM, Fedora Linux 44, with
ReleaseFast and `x86_64_v3`. v0.9.0 compiled with Zig 0.16 runs as the baseline
in the same ten rotated rounds as v0.9.1, V8, Rust regex, PCRE2, zig-regex and
zoptia0regex.

Three confirmed migration regressions remain open. In this full run, the
best-round additional time is 17.96% for hello execAt, 17.34% for Darcy
execAt, and 16.70% for the short Unicode case:

- Long literal `hello` search: additional generated stack reloads in the SIMD scan.
- Book `Darcy` search: the same shared literal-scan code generation issue.
- Short `\b\p{Lu}{5}\b /v` execution: extra forward-DFA work maintaining the
  optional match end, despite identical DFA tables.

This release ships without the experimental literal helper, sentinel change
or noinline DFA experiments. It does not claim parity with Zig 0.16. The
`@splat` migration was ruled out by a control with identical loaded binary
sections; the responsible compiler optimization pass remains unidentified.

See [Benchmarks](BENCHMARKS.md) for the current measurements and machine
metadata, and [Zig 0.17 upgrade gaps](ZIG_0.17_UPGRADE_GAPS.md) for all three
English investigations, including discarded approaches.

Additional full-harness flags on set-subtraction compile time and e-mail
short execution did not reproduce above 10% in focused probes. The compile
signal remains unexplained; all samples and limitations are recorded in the
[benchmark regression review](../bench/regression_review_v0.9.1.json).

## Compatibility validation

The Node 26 test262 harness reports 3383 passing entries out of 3406 run,
with 432 skipped, for both UTF-16 and WTF-8. The 23 existing non-passing
entries are unchanged. Node 26 enables 78 additional passing entries compared
with the Node 22 reference; their statuses were verified against v0.9.0 built
with Zig 0.16 before updating both baselines. This is harness coverage, not a
new engine capability. Host `RegExp.escape` tests do not exercise z-regex.

The complete release gate finished with **GATE-PASS**. The stripped shared
library exports exactly 40 `zregex_*` symbols in ReleaseFast and ReleaseSmall.
Validation covers Debug and ReleaseSafe tests, module layers,
fuzz stress, test262 in both encodings, external V8 differentials and internal
capture, lookbehind, lookahead and DFA differentials. Benchmark match counts
are checked across every completed round.

## Consumption

Update the dependency tag to `v0.9.1` and build with Zig 0.17.0:

```sh
zig fetch --save https://github.com/carlos-sweb/z-regex/archive/refs/tags/v0.9.1.tar.gz
```

The C ABI remains available through `zig build shared`.
