# Project Structure

Where each thing is, one line per file or directory. How the pieces work together is in
[ARCHITECTURE.md](ARCHITECTURE.md); which module may import which is `build.zig`'s
`layers` table, checked by `zig build check-layers`.

## Root

```
build.zig            the module layers, every build step
build.zig.zon        package manifest (version, minimum Zig 0.16.0)
README.md            overview, usage, the API stability summary
CONTRIBUTING.md
LICENSE
src/                 the engine (below)
tests/               integration tests, corpora, references (below)
tools/               Zig tools run by build steps: differentials, layer check, probes
scripts/             test262 harness, generators, the gate, measurement
bench/               performance baseline and the cross-engine comparison
examples/            small programs using the public API (`zig build examples`)
docs/                documentation (below)
```

## `src/`

```
main.zig             the `zregex` module: the 19 stable declarations and `internal`
regex.zig            `Regex`, the facade (find, findAll, replace, ...), execAt, iterator
compile.zig          CompileOptions, compileTiers: front end, route, code generation
c_api.zig            the exported C ABI (`zig build shared`)
leaves_tests.zig     test aggregator of the leaf layers
analysis/
  classify.zig       analyze(): the minimum tier of a pattern, from its HIR
frontend/
  root.zig
  parser/            lexer.zig, parser.zig, ast.zig
  lower/             lower.zig (AST -> HIR), fold.zig (case-folding closure of a set)
ir/
  hir.zig            the HIR
  charset.zig        CharSet: sorted code point ranges and their algebra
  word.zig, word_fold.zig   word-character sets for \w, \b
subject/
  root.zig           Subject: WTF-8 or UTF-16, positions, decoding both ways
tier0/
  compile.zig        HIR -> Thompson program; which patterns T0 takes
  program.zig        the program
  pikevm.zig         the Pike VM without captures
  pikevm_tagged.zig  the tagged Pike VM (captures, two passes)
  prefilter.zig      exact prefilters and fast paths
tier1/
  root.zig           empty: T1 patterns run on tier0 or tier2
tier2/
  program.zig        CompileResult: bytecode, CharSet table, named groups, LookLinear sites
  bytecode/          opcodes.zig, writer.zig, reader.zig, format.zig
  codegen/           generator.zig (HIR -> bytecode)
  executor/          backtrack.zig (explicit-stack backtracker), core.zig (its state and
                     atom checks), matcher.zig (ExecLimits, MatchResult, byte-offset entry
                     points), thread.zig
unicode/
  tables.zig         generated from UCD 17.0.0 (scripts/gen_unicode_tables.py)
  properties.zig     \p{...} name resolution and lookup
  casefold.zig       Canonicalize classes and simple case mapping
utils/
  bitset.zig, bittable.zig, dynbuf.zig, pool.zig, budget.zig, debug.zig, config.zig
```

## `tests/`

```
integration_tests.zig    end-to-end tests; the root of the integration binary
regression_tests.zig     one test per fixed bug or contract (API, errors, V8 cases)
syntax_tests.zig, captures_tests.zig, exec_tests.zig, subject_tests.zig,
code_unit_tests.zig, dual_encoding.zig, t0_tests.zig, tier2_pipeline_tests.zig,
hir_contract_tests.zig   by subject
bytecode_snapshot.zig, snapshot_common.zig, snapshot_update.zig, snapshots/bytecode.txt
fuzz_common.zig, fuzz_parser.zig, fuzz_stress.zig
differential.zig         WTF-8 against UTF-16: the same match from every position
test262_conformance.zig, test262_data.zig   the 168-case sample (generated data)
layers/ref_all.zig       compile canaries of check-layers
corpus/                  pattern corpora: f2c.txt, f2c-2.txt, npm.tsv, lookbehind.tsv, iter_v8.tsv
differential/reference/  references the gate compares against (dv8, lbdiff-v8, ivdiff, pfdiff slots)
```

## `tools/`, `scripts/`, `bench/`

```
tools/check_layers.zig   the layer lint
tools/pfdiff.zig, t1diff.zig, lldiff.zig, lbdiff.zig   internal differentials
tools/f0c.zig, cgprobe.zig                         tier histogram, callgrind probe
scripts/gate.sh          the gate (every check, one verdict)
scripts/gate/            V8 arbiters of pfdiff and t1diff
scripts/test262/         the test262 harness, baselines, V8 differentials (Node + koffi)
scripts/measure_binary.sh   binary size, one procedure
scripts/gen_unicode_tables.py, gen_test262_data.py, extract_test262.py
scripts/f0c/, snapshot/, iter_corpus/   corpus extraction and generators
bench/bench.zig          the performance baseline (`zig build bench`)
bench/compare/           z-regex against V8, Rust regex, PCRE2 and zig-regex
```

## `docs/`

```
API.md                   the API contract
ARCHITECTURE.md          how the engine works
PROJECT_STRUCTURE.md     this file
LIMITATIONS.md           what works and what doesn't, today
HISTORY.md               the record of every phase
KNOWN_LIMITATIONS.md     index to the two above (cited by the sources)
BENCHMARKS.md            performance numbers
REGEX_TIERS_PLAN.md      the tier design and its phases
ECMASCRIPT_COMPATIBILITY_PLAN.md   the compatibility plan of the first phases
F6A_PRECHECK.md          F6a's precheck (cited by the sources)
RELEASE_NOTES_v*.md      one per release
plans/                   ROADMAP_1.0.md and the plans of E1, F7 and F7c
archive/                 documents of closed phases and the Spanish README
```
