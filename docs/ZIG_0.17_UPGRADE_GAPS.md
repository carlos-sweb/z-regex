# Zig 0.16 → 0.17 upgrade gaps

## Current disposition

The project retains the API changes needed to compile with Zig 0.17.
Performance workarounds are not retained. In particular, literal candidate
verification calls `std.mem.eql` directly; the experimental `candidateEqual`
helper has been removed. The sentinel and noinline-forward DFA experiments
were confined to temporary checkouts and were never applied to project source.

The three confirmed performance regressions are open upgrade gaps.
Functional correctness and performance acceptance are separate: passing the
tests does not establish parity with Zig 0.16. v0.9.1 ships the migration with these known gaps. The new
[benchmark publication](BENCHMARKS.md) compares the unpatched Zig 0.17 build
with v0.9.0 built with Zig 0.16 on the same machine.

## Investigations

The studies were performed on October 10, 2026, using an Intel Core i3-10100F,
Zig 0.16.0 and 0.17.0, ReleaseFast, and `x86_64_v3`. These findings concern
specific generated code and workloads, not every Zig 0.17 program or target.

| Open gap | Affected measurement | Root-cause evidence | Workaround disposition |
|---|---|---|---|
| [Literal `hello`](LITERAL_SEARCH_CODEGEN.md) | Long-corpus `execAt`, iterator, and `findAll` | Executed SIMD scan stack loads increase from five to nine per block; selected std comparison sources are unchanged | Candidate-verifier boundary recovered sparse scanning, but was removed because of dense-candidate overhead |
| [Book: `Darcy`](DARCY_CODEGEN.md) | Literal search over the original book | Same shared scan and extra reloads as `hello` | Helper recovered book throughput but added about 18% time on a separate `Dxxxy` stress corpus; removed |
| [Unicode `\b\p{Lu}{5}\b /v`](UNICODE_DFA_CODEGEN.md) | Short `execAt` on `abc ABCDE` | About 14.5% more time; identical DFA tables; additional forward-loop work maintaining an optional match end | Sentinel representation gave partial recovery; noinline forward worsened results; neither is retained |

The percentages in the reports measure additional execution time, not a
percentage reduction in throughput. Medians, best rounds, and isolated-probe
results have different purposes and must not be substituted for each other.
The exact Zig/LLVM optimization pass or commit responsible remains unknown.

## What the investigation rules out

The array-initialization `@splat` migration is not supported as the cause:
removing those initializers in a Zig 0.17 control produced identical loaded
binary sections. Literal vector broadcasts already existed in the baseline.
The relevant literal-comparison std sources are identical between versions;
the Unicode short path uses project DFA tables and ASCII transitions rather
than std Unicode decoding. These observations do not establish universal
performance equivalence for the standard libraries or compilers.

## Future acceptance

A future fix must be checked against the Zig 0.16 baseline and the unpatched
Zig 0.17 build in the actual harness, with interleaved rounds and a focused
confirmation or profile for apparent regressions. It must cover:

- The original hello and book corpora and exact match positions.
- Absent matches, dense matches, and dense rejected candidates.
- Short execution of the Unicode assertion pattern and the long Unicode corpus.
- UTF-8/WTF-8 and UTF-16, valid indices, sticky searches, vector boundaries,
  empty interiors, and shorter/longer literals.
- The existing unit and integration tests and the full cross-engine benchmark.

A fix that helps one corpus while regressing another is not sufficient for
performance acceptance. All numbers preserved in the investigation reports
are historical measurements; removal of a workaround does not turn its
results into measurements of a newly rebuilt binary.

## Reproduction and evidence

Build each comparison checkout with its explicit compiler executable and
separate caches. Build the harness with `zig build xbench -Dcpu=x86_64_v3`.
For a focused original-harness run, copy `bench/compare/cases.json` into a
separate working directory at the same relative path and retain only the
case under investigation (`t0_literal`, `t0_book_name`, or `t1_v_lu5`). Run
`zregex_xbench` there with the same absolute corpus directory for each binary.
Rotate process order for at least ten rounds, avoid concurrent profiling or
compilation, and verify match counts before comparing timings.

The reports preserve the measured tables, source dissection, profiling
counts, validation scope, and rejected approaches in English. Their raw local
artifacts under `/tmp` are ephemeral and are not packaged dependencies.
See [Benchmarks](BENCHMARKS.md) for the published comparison and benchmark
policy and the v0.9.1 measurements. Historical study tables remain unchanged.
