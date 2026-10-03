# Benchmarks: z-regex against V8, Rust regex, PCRE2 and zig-regex

**v0.8.0, after T0-A (DFA).** What this measures: z-regex 0.8.0 (measured on commit
`c9274bc`, whose code is 0.8.0's) against the engines people would use instead, **tier by tier**
(docs/REGEX_TIERS_PLAN.md): a T0 case is compared only with engines that run it as a regular
expression, a T2 case (backreferences, lookaround) only with backtracking engines that
support it. Tiers are never mixed in one table. z-regex 0.7.0, the version of the previous
publication, runs in the same rounds as a base (see "Against 0.7.0").

## Setup

| | |
|---|---|
| Machine | Intel(R) Xeon(R) Processor @ 2.80GHz, 4 cores (no SMT), KVM guest, 15Gi RAM, Linux 6.18.44-fc-v64 |
| Environment | **shared container**: a case moves by ±20% from one process to the next; read the band, not only the best round |
| z-regex | 0.8.0 (commit `c9274bc`: the same code, before the version bump), and 0.7.0 as the base. Zig 0.16.0, ReleaseFast, **`-Dcpu=x86_64_v3`** (AVX2, no AVX-512), the CPU model of `scripts/measure_binary.sh` |
| V8 | 12.4.254.21-node.39 (Node v22.22.2) |
| Rust regex | 1.13.1 (rustc 1.94.1 (e408947bf 2026-03-25)), release, LTO |
| PCRE2 | 10.42, 8-bit library, JIT and interpreter |
| zig-regex | 0.1.1 (zig-utils/zig-regex, 173b298), the last release that builds with Zig 0.16 (v0.2.x needs 0.17-dev); built `native` by `setup_zigregex.sh` |

**The previous publication** (0.7.0) was measured on the same kind of host and the same CPU
model; what changed in z-regex since then is measured here against 0.7.0 in the same rounds:
see "Against 0.7.0". The route of each case (`<sub>(z-regex: …)</sub>`) now says when T0's DFA
runs it: "DFA" (the forward and reverse DFAs give the match), "DFA, tagged VM" (the DFA gives
the bounds and the tagged VM fills the groups over the span); "VM" covers the fast paths
(literal, class run, Shift-And) that run before the DFA.

**Method.** 10 interleaved rounds: each round runs every engine once over all its cases, and
the engines' order rotates from round to round. Within a round, a throughput number is the
median of up to 5 timed passes after one warm-up. Every cell below is **the best round (the
highest MB/s, the lowest ns, µs or ms), with the min–max band** in parentheses: since F7-0
the best round is the estimator (below). Harness, corpora and runner: `bench/compare/`
(`prepare.sh` builds everything, `run.mjs` only runs, `analyze.mjs` writes
`bench/results.json`, the raw aggregated numbers, with the best, median, min and max of each
cell).

**Precision (F7-0).** Two series of 5 interleaved rounds of the same z-regex binary differ
by more than 5% in 35 to 45 of the 66 throughput metrics, whatever was tried:

| Setup (same binary, series A vs B, 5 rounds each) | Metrics with \|A−B\| > 5% | Median \|A−B\| | Max \|A−B\| |
|---|---|---|---|
| Samples of ≥ 100 ms instead of one pass (tried in F7-0, not kept) | 45 / 66 | 7.3% | 33.8% |
| ASLR off (`setarch -R`), one pass per sample | 35 / 66 | 5.7% | 42.8% |
| ASLR off and the input 2 MiB-aligned | 36 / 66 | 5.8% | 35.5% |

With the same address layout in every process the spread doesn't drop, so it isn't layout:
it is the shared VM's timing noise, which moves one case by 20–45% from one process to the
next (each whole run stays within 0.91–1.01 of the median). A bootstrap over the 10 ASLR-off
runs gives how two series of n rounds compare, per estimator of a case:

| Estimator | n = 5 | n = 10 | n = 20 |
|---|---|---|---|
| Median of the rounds: metrics > 5%, p90 \|A−B\| | 52%, 32.0% | 44%, 20.0% | 31%, 14.8% |
| Best round (minimum time = the max MB/s of the band): metrics > 5%, p90 \|A−B\| | 21%, 7.9% | 8%, 4.2% | 2%, 2.1% |

**Regression criterion (since F7b).** A regression is declared when the bench flags it (10
interleaved rounds, minimum time per case, worse than 10%) **and** callgrind, or a probe
that reproduces the case's context, confirms it. Bench flag without confirmation: noise of
this environment, noted and passed. Callgrind flag without the bench: real, fixed. Both
have to agree to block a commit. Why: at the F7b close two runs of the same code flagged
disjoint sets of cases (16 and 7 of 110 metrics), every one executing the same instructions
as the base (callgrind, ±0.73%); and the one real regression of F7b (a compile cost in the
allocator) was invisible to callgrind and caught by the bench.

**In this environment the bench cannot detect changes under ~20% with 10 rounds using the
median; §7.2's 10% gate is applied with this precision.** Comparing the minimum time per case
(the max MB/s of the min–max band, already in `bench/results.json`), the precision with 10
rounds is ~4% (p90): regression checks compare the minimum. Changes finer than that are
measured with callgrind or a dedicated probe, not with this bench.

**Metrics.**
- *findAll MB/s*: every match through each engine's allocating convenience API (z-regex
  `Regex.findAll`, JS `String.prototype.matchAll`, Rust `find_iter`/`captures_iter` collected,
  PCRE2 ovectors copied to the heap, zig-regex `findAll`).
- *execAt MB/s*: the engine's own search loop from an index, with no per-match allocation
  where the API allows (z-regex `execAt` with a warm `Scratch`; Rust `find_at` /
  `captures_read_at` with reused locations; PCRE2 `pcre2_match` with reused match data). V8
  has no allocation-free API: its "execAt" is a `RegExp.prototype.exec` loop.
- *V8 (warm)*: after warm-up, when V8 has compiled the regexp to native code. *V8 (cold)*: a
  fresh Node process per case, `new RegExp` plus the first findAll pass timed together — what
  a script that runs a regexp once pays. V8 compiles lazily and caches compiled regexps by
  source, so it has no compile column: the cold column holds that cost.
- *ns per exec*: one search on a short input (< 64 B). *µs per compile* and *bytes per
  compiled pattern* (z-regex and zig-regex: live allocations of the compiled object; PCRE2:
  `PCRE2_INFO_SIZE` plus the JIT code). Rust regex exposes no size.
- MB/s is always over the corpus's UTF-8 bytes, the same count for every engine.

**Semantics check.** Every engine that runs a case finds the same number of matches on it
(checked by `analyze.mjs` on every run). For T0, Rust regex runs with `regex::bytes` and
`unicode(false)`, so `\d`, `\w` and classes are ASCII as in ECMAScript without `u`.

## Corpora

- **Synthetic**: 1 MiB per input, from a fixed-seed xorshift32 generator
  (`bench/compare/gen_corpus.mjs`; seeds 1–10, one per input: prose, prose with rare
  "hello", sparse phone numbers, dense digits, e-mails, `a`/`b` runs, mixed-script Unicode,
  HTML, prices, password-like lines). Byte-identical on every run and machine.
- **Realistic**: *Pride and Prejudice* (Project Gutenberg #1342, public domain, 724,725 bytes,
  UTF-8 with CRLF), from GITenberg's mirror at commit `81db45c`, sha256
  `48e0522844402a86a3ea98f0947ba85ea54838db3c59022299298ed968a5a163`
  (`bench/compare/fetch_book.sh` checks it).
- **Adversarial**: `a` × n followed by `c` (no match) or by `cb` (still no match, but it
  defeats PCRE2's required-character shortcut, which rejects `a^n c` without trying).
  Each run in its own process, killed after 5 s.

## Results

zig-regex has no findAll MB/s ("—"): its findAll is quadratic, see its growth below; it runs
the other T0 metrics. "n/a": the engine doesn't run that case (a z-regex-only variant, or a
feature it lacks). "unsupported": the engine rejects the pattern.


#### T0: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex | zig-regex |
|---|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 11559.9 (4668.3–11559.9) | 1803.0 (1313.1–1803.0) | 1567.3 (1174.5–1567.3) | 19676.5 (9943.1–19676.5) | — |
| [a-z]+ <sub>(z-regex: VM)</sub> | 56.4 (43.2–56.4) | 75.8 (69.8–75.8) | 54.0 (39.6–54.0) | 55.7 (49.1–55.7) | — |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 27.0 (24.3–27.0) | n/a | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 20.3 (19.3–20.3) | n/a | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 442.6 (258.9–442.6) | 1212.5 (804.7–1212.5) | 382.0 (225.1–382.0) | 1722.6 (1538.4–1722.6) | — |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 223.1 (194.6–223.1) | 165.2 (139.9–165.2) | 104.2 (60.0–104.2) | 82.1 (54.6–82.1) | — |
| email <sub>(z-regex: DFA)</sub> | 505.6 (470.1–505.6) | 79.7 (47.4–79.7) | 67.3 (43.7–67.3) | 702.8 (656.2–702.8) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 235.1 (216.4–235.1) | 973.5 (898.1–973.5) | 343.8 (286.3–343.8) | 820.6 (483.4–820.6) | — |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 58.3 (51.3–58.3) | 129.3 (111.3–129.3) | 94.0 (54.9–94.0) | 60.9 (38.6–60.9) | — |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 18.5 (17.6–18.5) | 29.1 (21.6–29.1) | 25.6 (23.8–25.6) | 39.1 (37.5–39.1) | — |
| book: Darcy <sub>(z-regex: VM)</sub> | 7172.4 (5554.5–7172.4) | 8029.0 (6958.1–8029.0) | 2686.1 (1153.5–2686.1) | 17762.8 (16263.2–17762.8) | — |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 335.5 (267.8–335.5) | 493.7 (287.0–493.7) | 145.1 (114.0–145.1) | 296.9 (278.5–296.9) | — |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 622.4 (559.6–622.4) | 458.3 (341.2–458.3) | 350.3 (258.9–350.3) | 1620.2 (1144.5–1620.2) | — |

#### T0: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex |
|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 13623.6 (5970.3–13623.6) | 1822.0 (1332.0–1822.0) | 20135.7 (11788.1–20135.7) | — |
| [a-z]+ <sub>(z-regex: VM)</sub> | 185.8 (178.5–185.8) | 79.2 (65.0–79.2) | 58.4 (51.2–58.4) | — |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 42.1 (38.6–42.1) | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 30.1 (17.6–30.1) | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 572.8 (518.4–572.8) | 955.4 (846.9–955.4) | 1772.2 (1226.3–1772.2) | — |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 409.5 (333.6–409.5) | 173.6 (151.2–173.6) | 84.5 (64.4–84.5) | — |
| email <sub>(z-regex: DFA)</sub> | 758.7 (725.3–758.7) | 80.0 (56.1–80.0) | 717.1 (663.2–717.1) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 283.3 (270.5–283.3) | 1052.6 (967.8–1052.6) | 1160.0 (554.0–1160.0) | — |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 74.5 (68.7–74.5) | 146.0 (140.4–146.0) | 71.5 (58.6–71.5) | — |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 22.1 (18.5–22.1) | 29.7 (26.4–29.7) | 51.2 (45.5–51.2) | — |
| book: Darcy <sub>(z-regex: VM)</sub> | 13532.6 (12870.1–13532.6) | 8677.4 (8148.8–8677.4) | 19334.0 (16933.4–19334.0) | — |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 599.3 (398.2–599.3) | 504.4 (320.4–504.4) | 302.6 (185.7–302.6) | — |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 725.5 (655.5–725.5) | 466.6 (345.0–466.6) | 2090.4 (1897.1–2090.4) | — |

#### T0: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 13712.7 (3419.0–13712.7) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 178.5 (171.4–178.5) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 42.3 (34.5–42.3) |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 30.2 (21.8–30.2) |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 575.9 (538.5–575.9) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 406.7 (382.7–406.7) |
| email <sub>(z-regex: DFA)</sub> | 756.6 (575.3–756.6) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 281.8 (276.1–281.8) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 74.2 (61.6–74.2) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 22.1 (19.6–22.1) |
| book: Darcy <sub>(z-regex: VM)</sub> | 13429.5 (9776.0–13429.5) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 595.8 (379.8–595.8) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 729.5 (520.3–729.5) |

#### T0: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex |
|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 25 (25–51) | 66 (66–75) | 21 (21–37) | 407 (407–733) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 20 (20–22) | 64 (64–91) | 83 (83–96) | 601 (601–892) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 112 (112–145) | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 158 (158–220) | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 33 (33–61) | 81 (81–97) | 75 (75–79) | 1447 (1447–1570) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 33 (33–35) | 79 (79–93) | 75 (75–86) | 1450 (1450–1765) |
| email <sub>(z-regex: DFA)</sub> | 74 (74–78) | 135 (135–154) | 85 (85–103) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 365 (365–384) | 108 (108–121) | 136 (136–142) | 3484 (3484–3718) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 393 (393–414) | 115 (115–137) | 136 (136–145) | 3508 (3508–3681) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 458 (458–494) | 75 (75–84) | 141 (141–146) | 3371 (3371–3619) |
| book: Darcy <sub>(z-regex: VM)</sub> | 25 (25–34) | 69 (69–76) | 21 (21–22) | 405 (405–425) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 57 (57–67) | 79 (79–89) | 86 (86–91) | 1782 (1782–2066) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 604 (604–641) | 105 (105–120) | 173 (173–197) | 8432 (8432–8844) |

#### T0: µs per compile

| Case | z-regex | Rust regex | zig-regex |
|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 1.76 (1.76–2.85) | 2.68 (2.68–4.95) | 0.97 (0.97–1.63) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 1.43 (1.43–1.99) | 8.41 (8.41–12.73) | 0.62 (0.62–0.94) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 1.34 (1.34–2.16) | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 0.83 (0.83–1.08) | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 2.61 (2.61–2.65) | 192.68 (192.68–235.62) | 1.30 (1.30–2.27) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 2.60 (2.60–3.77) | 192.38 (192.38–309.96) | 1.28 (1.28–2.31) |
| email <sub>(z-regex: DFA)</sub> | 12.36 (12.36–17.86) | 21.59 (21.59–23.39) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 3.27 (3.27–3.45) | 197.72 (197.72–301.68) | 3.99 (3.99–6.65) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 3.26 (3.26–3.34) | 197.00 (197.00–201.19) | 4.20 (4.20–5.60) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 7.24 (7.24–12.73) | 13.30 (13.30–15.15) | 3.54 (3.54–4.28) |
| book: Darcy <sub>(z-regex: VM)</sub> | 1.71 (1.71–1.99) | 2.60 (2.60–2.98) | 0.96 (0.96–1.15) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 4.87 (4.87–8.08) | 10.31 (10.31–14.81) | 0.87 (0.87–1.36) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 25.29 (25.29–26.63) | 29.89 (29.89–33.82) | 6.00 (6.00–7.84) |

#### T0: bytes per compiled pattern

| Case | z-regex | zig-regex |
|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 135 (135–135) | 1016 (1016–1016) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 135 (135–135) | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 19 (19–19) | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 1349 (1349–1349) | 3817 (3817–3817) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 1349 (1349–1349) | 3817 (3817–3817) |
| email <sub>(z-regex: DFA)</sub> | 2165 (2165–2165) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 1457 (1457–1457) | 5365 (5365–5365) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 1457 (1457–1457) | 5365 (5365–5365) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 1393 (1393–1393) | 3227 (3227–3227) |
| book: Darcy <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 1176 (1176–1176) | 1751 (1751–1751) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 3284 (3284–3284) | 9370 (9370–9370) |

#### T1: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex |
|---|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 41.5 (37.9–41.5) | 36.9 (29.1–36.9) | 30.1 (18.2–30.1) | 64.2 (54.2–64.2) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 132.8 (107.5–132.8) | 98.2 (84.1–98.2) | 65.9 (57.9–65.9) | 223.5 (134.4–223.5) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 81.2 (73.5–81.2) | 52.2 (47.8–52.2) | 40.0 (35.4–40.0) | 173.7 (149.8–173.7) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 12.6 (10.2–12.6) | 25.8 (24.0–25.8) | 22.2 (15.1–22.2) | n/a |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 39.5 (30.0–39.5) | 25.8 (23.1–25.8) | 20.9 (16.0–20.9) | 49.9 (28.3–49.9) |

#### T1: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 76.7 (69.8–76.7) | 38.2 (36.0–38.2) | 67.4 (62.2–67.4) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 169.8 (150.6–169.8) | 94.3 (85.2–94.3) | 230.4 (136.7–230.4) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 134.5 (127.1–134.5) | 53.9 (51.0–53.9) | 188.9 (137.1–188.9) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 20.1 (17.0–20.1) | 27.2 (17.8–27.2) | n/a |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 90.2 (78.2–90.2) | 26.3 (18.7–26.3) | 53.3 (51.0–53.3) |

#### T1: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 75.8 (55.6–75.8) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 169.1 (115.3–169.1) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 134.4 (129.6–134.4) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 20.0 (17.7–20.0) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 88.6 (60.9–88.6) |

#### T1: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 135 (135–157) | 176 (176–187) | 111 (111–121) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 107 (107–140) | 170 (170–180) | 114 (114–120) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 62 (62–67) | 154 (154–170) | 54 (54–58) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 275 (275–297) | 185 (185–199) | n/a |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 37 (37–41) | 71 (71–83) | 74 (74–81) |

#### T1: µs per compile

| Case | z-regex | Rust regex |
|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 42.11 (42.11–42.82) | 321.92 (321.92–517.56) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 5.96 (5.96–12.05) | 55.66 (55.66–90.93) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 40.24 (40.24–41.04) | 191.34 (191.34–198.76) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 5.74 (5.74–9.09) | n/a |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 41.78 (41.78–53.13) | 325.23 (325.23–343.23) |

#### T1: bytes per compiled pattern

| Case | z-regex |
|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 22852 (22852–22852) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 2116 (2116–2116) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 21871 (21871–21871) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 5486 (5486–5486) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 22852 (22852–22852) |

#### T2: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 23.9 (22.0–23.9) | 168.3 (127.5–168.3) | 89.2 (62.3–89.2) | 199.5 (112.2–199.5) | 64.6 (56.7–64.6) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 7.4 (6.6–7.4) | 41.2 (27.0–41.2) | 33.5 (23.1–33.5) | 57.1 (44.1–57.1) | 9.0 (7.6–9.0) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 14.1 (12.2–14.1) | 198.4 (176.1–198.4) | 119.9 (81.3–119.9) | 858.6 (554.2–858.6) | 429.4 (341.7–429.4) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 9.1 (8.7–9.1) | 124.2 (105.5–124.2) | 118.6 (75.5–118.6) | 87.8 (61.2–87.8) | 21.5 (20.2–21.5) |

#### T2: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 27.3 (25.7–27.3) | 178.8 (101.0–178.8) | 210.0 (126.8–210.0) | 66.2 (37.1–66.2) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 7.7 (6.9–7.7) | 41.7 (33.7–41.7) | 58.1 (41.0–58.1) | 9.1 (8.0–9.1) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 14.5 (13.7–14.5) | 201.6 (181.0–201.6) | 881.4 (556.8–881.4) | 442.2 (393.9–442.2) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 9.1 (8.7–9.1) | 124.7 (83.5–124.7) | 88.7 (67.8–88.7) | 21.5 (20.3–21.5) |

#### T2: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 27.5 (25.3–27.5) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 7.7 (7.4–7.7) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 14.5 (13.4–14.5) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 9.1 (8.8–9.1) |

#### T2: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 444 (444–470) | 79 (79–87) | 57 (57–63) | 187 (187–223) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 423 (423–448) | 128 (128–139) | 75 (75–77) | 346 (346–369) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 570 (570–602) | 93 (93–103) | 44 (44–48) | 107 (107–116) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 333 (333–371) | 93 (93–100) | 58 (58–61) | 125 (125–133) |

#### T2: µs per compile

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 2.91 (2.91–3.97) | 7.85 (7.85–12.62) | 0.78 (0.78–1.24) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 4.43 (4.43–4.53) | 6.57 (6.57–13.04) | 1.01 (1.01–1.02) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 1.80 (1.80–1.84) | 4.38 (4.38–8.24) | 0.53 (0.53–0.54) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 1.99 (1.99–2.83) | 7.32 (7.32–13.26) | 0.67 (0.67–0.86) |

#### T2: bytes per compiled pattern

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 92 (92–92) | 1287 (1287–1287) | 168 (168–168) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 1820 (1820–1820) | 963 (963–963) | 231 (231–231) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 714 (714–714) | 687 (687–687) | 156 (156–156) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 59 (59–59) | 1226 (1226–1226) | 160 (160–160) |

#### Adversarial: ms until the engine answers or gives up (best round; outcome)

| Case | n | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.001 (no match) | 107.907 (no match) | 0.005 (no match) | 0.006 (no match) |
| (a+)+b on a^n c | 25 | 0.002 (no match) | 3443.980 (no match) | 0.006 (no match) | 0.006 (no match) |
| (a+)+b on a^n c | 30 | 0.002 (no match) | 5003.000 (timeout (> 5 s, killed)) | 0.005 (no match) | 0.005 (no match) |
| (a+)+b on a^n c | 40 | 0.002 (no match) | 5004.000 (timeout (> 5 s, killed)) | 0.006 (no match) | 0.006 (no match) |
| (a+)+b on a^n cb | 20 | 0.001 (no match) | 108.223 (no match) | 12.262 (no match) | 100.420 (no match) |
| (a+)+b on a^n cb | 25 | 0.002 (no match) | 3535.186 (no match) | 29.096 (match limit) | 193.212 (match limit) |
| (a+)+b on a^n cb | 30 | 0.002 (no match) | 5003.000 (timeout (> 5 s, killed)) | 29.045 (match limit) | 191.977 (match limit) |
| (a+)+b on a^n cb | 40 | 0.001 (no match) | 5003.000 (timeout (> 5 s, killed)) | 29.224 (match limit) | 188.643 (match limit) |
| (?=(a+)+b) on a^n c | 20 | 31.951 (StepLimitExceeded) | 108.776 (no match) | 0.005 (no match) | 0.006 (no match) |
| (?=(a+)+b) on a^n c | 25 | 32.102 (StepLimitExceeded) | 3478.381 (no match) | 0.006 (no match) | 0.007 (no match) |
| (?=(a+)+b) on a^n c | 30 | 32.367 (StepLimitExceeded) | 5005.000 (timeout (> 5 s, killed)) | 0.005 (no match) | 0.006 (no match) |
| (?=(a+)+b) on a^n c | 40 | 32.127 (StepLimitExceeded) | 5007.000 (timeout (> 5 s, killed)) | 0.005 (no match) | 0.006 (no match) |

z-regex runs `(a+)+b` on T0's DFA (linear; the tagged VM fills the group over the span).
V8 grows by ~11× every 5 `a`s. PCRE2 answers at once
because the required character `c` is absent (its start-up shortcut, as for `(a+)+b` on
`a^n c`).

### Against 0.7.0

z-regex 0.8.0 and z-regex 0.7.0, the previous publication, in the same 10 rounds (the same
harness), both built with `-Dcpu=x86_64_v3`. 0.8.0's harness was built from `c9274bc`,
the code of 0.8.0 before the version bump, so its JSON still says 0.7.1.

#### Best round; ratio > 1: better now

| Case | Tier | execAt MB/s now | 0.7.0 | ratio | findAll MB/s now | 0.7.0 | ratio | ns short now | 0.7.0 | ratio |
|---|---|---|---|---|---|---|---|---|---|---|
| literal hello | T0 | 13623.6 | 13574.6 | 1.00 | 11559.9 | 11279.7 | 1.02 | 25 | 28 | 1.10 |
| [a-z]+ | T0 | 185.8 | 196.5 | 0.95 | 56.4 | 56.4 | 1.00 | 20 | 18 | 0.93 |
| [a-z]+ (z-regex: generic VM, no fast path) | T0 | 42.1 | 41.7 | 1.01 | 27.0 | 26.0 | 1.04 | 112 | 110 | 0.98 |
| [a-z]+ (z-regex: backtracker) | T0 | 30.1 | 29.6 | 1.02 | 20.3 | 20.2 | 1.00 | 158 | 164 | 1.04 |
| \d{3}-\d{4} (sparse) | T0 | 572.8 | 461.9 | 1.24 | 442.6 | 365.9 | 1.21 | 33 | 285 | 8.65 |
| \d{3}-\d{4} (dense) | T0 | 409.5 | 34.1 | 12.02 | 223.1 | 29.3 | 7.62 | 33 | 276 | 8.34 |
| email | T0 | 758.7 | 36.4 | 20.82 | 505.6 | 35.1 | 14.40 | 74 | 480 | 6.52 |
| (\d{3})-(\d{4}) (sparse) | T0 | 283.3 | 250.5 | 1.13 | 235.1 | 217.2 | 1.08 | 365 | 609 | 1.67 |
| (\d{3})-(\d{4}) (dense) | T0 | 74.5 | 25.0 | 2.98 | 58.3 | 22.7 | 2.57 | 393 | 617 | 1.57 |
| (?:(a)\|b)*c | T0 | 22.1 | 13.5 | 1.63 | 18.5 | 12.1 | 1.53 | 458 | 563 | 1.23 |
| book: Darcy | T0 | 13532.6 | 13355.8 | 1.01 | 7172.4 | 5759.5 | 1.25 | 25 | 28 | 1.10 |
| book: [A-Z][a-z]+ | T0 | 599.3 | 324.6 | 1.85 | 335.5 | 228.3 | 1.47 | 57 | 181 | 3.16 |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) | T0 | 725.5 | 534.6 | 1.36 | 622.4 | 478.9 | 1.30 | 604 | 828 | 1.37 |
| \p{L}+ /u | T1 | 76.7 | 40.7 | 1.88 | 41.5 | 27.8 | 1.49 | 135 | 251 | 1.87 |
| \p{Script=Greek}+ /u | T1 | 169.8 | 56.1 | 3.03 | 132.8 | 49.9 | 2.66 | 107 | 268 | 2.51 |
| \p{General_Category=Lu} /u | T1 | 134.5 | 47.8 | 2.81 | 81.2 | 37.8 | 2.15 | 62 | 141 | 2.28 |
| [\p{L}--[a-z]] /v | T1 | 20.1 | 20.2 | 1.00 | 12.6 | 12.7 | 0.99 | 275 | 275 | 1.00 |
| book: \p{L}+ /u | T1 | 90.2 | 38.7 | 2.33 | 39.5 | 24.0 | 1.64 | 37 | 95 | 2.59 |
| <(\w+)>.*?<\/\1> | T2 | 27.3 | 28.6 | 0.95 | 23.9 | 25.1 | 0.95 | 444 | 427 | 0.96 |
| (?=.*[a-z])(?=.*[A-Z]).{8,} | T2 | 7.7 | 7.6 | 1.01 | 7.4 | 7.2 | 1.02 | 423 | 402 | 0.95 |
| (?<=\$)\d+ | T2 | 14.5 | 15.2 | 0.96 | 14.1 | 14.4 | 0.98 | 570 | 560 | 0.98 |
| book: \b(\w+) \1\b | T2 | 9.1 | 9.0 | 1.01 | 9.1 | 9.0 | 1.01 | 333 | 335 | 1.01 |

| Adversarial | n | now | 0.7.0 |
|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.001 (no match) | 0.003 (no match) |
| (a+)+b on a^n c | 25 | 0.002 (no match) | 0.004 (no match) |
| (a+)+b on a^n c | 30 | 0.002 (no match) | 0.004 (no match) |
| (a+)+b on a^n c | 40 | 0.002 (no match) | 0.004 (no match) |
| (a+)+b on a^n cb | 20 | 0.001 (no match) | 0.004 (no match) |
| (a+)+b on a^n cb | 25 | 0.002 (no match) | 0.004 (no match) |
| (a+)+b on a^n cb | 30 | 0.002 (no match) | 0.004 (no match) |
| (a+)+b on a^n cb | 40 | 0.001 (no match) | 0.004 (no match) |
| (?=(a+)+b) on a^n c | 20 | 31.951 (StepLimitExceeded) | 31.363 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 25 | 32.102 (StepLimitExceeded) | 31.180 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 30 | 32.367 (StepLimitExceeded) | 31.293 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 40 | 32.127 (StepLimitExceeded) | 31.528 (StepLimitExceeded) |

- **Better:** every case that runs on T0's DFA or a T0 fast path: the e-mail 20.8× (J and B
  in 0.7.1, then the DFA), `\d{3}-\d{4}` dense 12.0× (C, Shift-And), `(\d{3})-(\d{4})`
  dense 2.98×, the book's `[A-Z][a-z]+` 1.85× and title pattern 1.36×, `(?:(a)|b)*c` 1.63×,
  T1 1.9–3.0× (the DFA in code-point mode). Short inputs: `\d{3}-\d{4}` 276 → 33 ns, the
  e-mail 480 → 74 ns.
- **Within ±10%:** the literals, `[a-z]+` (0.95×), the backtracker cases (T2, `v`), and
  the adversarial runs.
- **Worse by more than 10%:** none.

### `u`/`v` on the DFA: four patterns of T0-A's phase 3

Not in the harness: a separate probe (the `execAt` loop over the whole input, the best of 10
interleaved rounds, MB/s, the same matches) of z-regex alone, before (`fbdac3a`: `u`/`v` on
T0's VM, as in 0.7.1) and after (0.8.0's code), on this machine. The corpora: the book; a
deterministic Greek text of 1 MiB; the `.zig` files of `src/` concatenated (1.1 MB).

| Pattern | Before (VM) | 0.8.0 (DFA) | Factor |
|---|---|---|---|
| `\p{L}+` (book) | 45.2 | 96.8 | 2.14× |
| `\p{Script=Greek}+` (Greek) | 46.4 | 88.7 | 1.91× |
| `[\p{L}\p{N}_]+` (code) | 51.0 | 123.4 | 2.42× |
| `\b\p{L}+\b` (book) | 17.4 | 82.6 | 4.75× |

### zig-regex: findAll growth (characterization, not a performance number)

Measured in the 0.3.0 run (previous host) with `run.mjs --scaling`; zig-regex and its
harness haven't changed, so it wasn't re-run.

zig-regex's `findAll` restarts its VM at every start position, so its cost grows with the
square of the input: a 1 MiB pass would take on the order of an hour, and it has no MB/s in
the tables above. Measured once on prefixes of the same corpora (MB/s at 16 / 32 / 64 KiB):
literal `hello` 0.014 / 0.007 / 0.003; `[a-z]+` 0.046 / 0.022 / 0.011. Each doubling of the input
halves the throughput. zig-regex also rejects `\w` inside a class (`InvalidCharacterClass`),
so the e-mail pattern doesn't compile.

### z-regex: findAll against the iterator

`Regex.iterator` gives every match `findAll` gives, one at a time, over the caller's
`Scratch` and `MatchSlots`: no allocation once the scratch is warm. Its column is in the
tables above ("iterator MB/s"): on every case it is within the band of the execAt loop, and
1.0–3.2× findAll (the most where matches are many: `[a-z]+` 179 against 56 MB/s).

Where findAll's time goes (a separate probe on 0.3.1, on the previous host, µs per call, `smp_allocator` as in the bench):
findAll allocates one `captures` slice per match and grows its list of 72-byte `MatchResult`s.
On Darcy (417 matches) that's 426 allocations and 8 page faults per call; on `[a-z]+` (158,795
matches), 158,804 allocations and ~2,800 page faults. About 43% of findAll's time on Darcy and
63% on `[a-z]+` is outside the search. Most of it is fresh memory (the large list goes back to
the OS on free, so every call faults its pages in again): run over reused memory, findAll on
Darcy drops from ~79 to ~55 µs (execAt: ~44). The rest, ~25–30 ns per match, is building and
freeing the results. Putting every `captures` slice in one block (an arena) measured no faster.
In the `literal hello` row the findAll/execAt gap (1.2–1.3× in these tables) is mostly noise:
a pass takes ~60 µs and each timed sample is one pass; timed over ≥ 150 ms per sample the gap
is ~1.05×.

## Analysis

Reference: V8 warm and Rust regex, `execAt` column, best round; "×" is a ratio of best
rounds. Even: within ±10%.

**T0 (z-regex: T0's DFA, its fast paths, and the tagged VM for groups)**

| Case | Route | vs V8 | vs Rust regex |
|---|---|---|---|
| literal `hello` | literal | **7.5× ahead** | 1.48× behind |
| `[a-z]+` | class run | **2.35× ahead** | **3.2× ahead** |
| `\d{3}-\d{4}` sparse | Shift-And | 1.67× behind | 3.1× behind |
| `\d{3}-\d{4}` dense | Shift-And | **2.36× ahead** | **4.85× ahead** |
| e-mail | DFA | **9.5× ahead** | even (1.06× ahead) |
| `(\d{3})-(\d{4})` sparse | Shift-And, tagged VM | 3.7× behind | 4.1× behind |
| `(\d{3})-(\d{4})` dense | Shift-And, tagged VM | 1.96× behind | even (1.04×) |
| `(?:(a)\|b)*c` | DFA, tagged VM | 1.35× behind | 2.3× behind |
| book: `Darcy` | literal | **1.56× ahead** | 1.43× behind |
| book: `[A-Z][a-z]+` | DFA | **1.19× ahead** | **1.98× ahead** |
| book: `(Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` | DFA, tagged VM | **1.55× ahead** | 2.9× behind |

**T1 (`u`/`v`: T0's DFA in code-point mode; `v` on the backtracker)**

| Case | vs V8 | vs Rust regex |
|---|---|---|
| `\p{L}+ /u` | **2.0× ahead** | **1.14× ahead** |
| `\p{Script=Greek}+ /u` | **1.8× ahead** | 1.36× behind |
| `\p{General_Category=Lu} /u` | **2.5× ahead** | 1.40× behind |
| `[\p{L}--[a-z]] /v` | 1.35× behind | n/a |
| book: `\p{L}+ /u` | **3.4× ahead** | **1.69× ahead** |

**T2 (the explicit-stack backtracker; Rust regex has no backreferences or lookaround)**

| Case | vs V8 | vs PCRE2 JIT | vs PCRE2 interp. |
|---|---|---|---|
| `<(\w+)>.*?<\/\1>` | 6.5× behind | 7.7× behind | 2.4× behind |
| `(?=.*[a-z])(?=.*[A-Z]).{8,}` | 5.4× behind | 7.5× behind | 1.18× behind |
| `(?<=\$)\d+` | 14× behind | 61× behind | 30× behind |
| book: `\b(\w+) \1\b` | 14× behind | 9.7× behind | 2.4× behind |

**Where z-regex is ahead**
- **T0's DFA** (0.8.0): the e-mail 9.5× V8, the book's `[A-Z][a-z]+` 1.19× V8 and 1.98× Rust,
  the book's title pattern 1.55× V8. On T1 every `u` case is ahead of V8 (1.8–3.4×), and
  `\p{L}+` is ahead of Rust (1.14× on the mixed corpus, 1.69× on the book).
- **Fast paths:** `[a-z]+` (class run) 2.35× V8 and 3.2× Rust; `\d{3}-\d{4}` on dense digits
  (Shift-And) 2.36× V8 and 4.85× Rust; the literal `hello` 7.5× V8.
- **Short inputs** without groups: 20–74 ns on T0, ahead of V8 on every such case (1.4–3.2×)
  and of Rust on most (`[a-z]+` 20 ns against 83, the e-mail 74 against 85).
- **Compile time:** 1.4–25 µs on T0 (the e-mail 12.4 µs, the DFA included) against 2.6–198 µs
  for Rust regex; 6–42 µs on T1 against Rust's 56–325.
- **Adversarial:** `(a+)+b` runs on T0 (the DFA gives the bounds), a few µs at any n. V8 is exponential (seconds at n = 25–30, killed after 5 s). PCRE2 answers at once when
  a required character is absent, and on `(a+)+b` over `a^n cb` stops at its match limit
  (~29 ms JIT, ~190 ms interpreter) with an error instead of an answer.

**Even (±10%):** the e-mail and `(\d{3})-(\d{4})` dense against Rust regex; `[a-z]+` findAll
against Rust (1.01×).

**The e-mail case.** No longer the worst T0 case: on the DFA (with J and B of 0.7.1 before
it) the e-mail runs at 758.7 MB/s, 1.06× Rust regex (within the ±10% band, so even) and 9.5×
V8; it was 19× behind Rust in 0.7.0. Against V8 the worst T0 case is now
`(\d{3})-(\d{4})` on sparse digits, 3.7× behind (the tagged VM over each match, after
Shift-And); the worst case of the whole benchmark is T2's lookbehind `(?<=\$)\d+`, 14× behind
V8 and 61× behind PCRE2 JIT.

**Where it's behind, and why**
- **Groups on T0** (`(\d{3})-(\d{4})`, `(?:(a)|b)*c`, the title pattern against Rust):
  1.35–3.7× behind V8, 2.3–4.1× behind Rust. The DFA (or Shift-And) gives the match bounds, and
  the tagged VM then fills the groups over the span: a second pass, on the Pike VM.
- **Literals against Rust:** 1.43–1.48× behind (`hello`, `Darcy`). Rust's `memchr` picks the
  rarest bytes of each needle and the vector width at run time; z-regex searches the first
  and last bytes in pairs of vectors of a width fixed at build time (AVX2 here).
- **Sparse `\d{3}-\d{4}`:** 1.67× behind V8 and 3.1× behind Rust: Shift-And steps every
  byte, where Rust's prefilter skips to the digits.
- **Short inputs with groups:** 3.4–6.1× behind V8 (e.g. `(\d{3})-(\d{4})` 365 ns against
  108): the tagged VM's fixed cost per search.
- **T1 against Rust:** `\p{Script=Greek}+` and `\p{General_Category=Lu}` 1.36–1.40× behind.
  The DFA decodes UTF-8 one character at a time and looks non-ASCII classes up by binary
  search over the cuts; Rust's DFA steps bytes. `v` (`[\p{L}--[a-z]]`) still runs on the
  backtracker.
- **findAll:** z-regex's facade allocates per match; on dense cases it gives up most of the
  execAt speed (`[a-z]+` 186 → 56 MB/s, the e-mail 759 → 506). `Regex.iterator` doesn't.
- **T2:** 5.4–14× behind V8 and 7.5–61× behind PCRE2 JIT, 1.18–30× behind PCRE2's interpreter;
  unchanged since 0.7.0. The lookbehind case is the worst (14× behind V8): the backward body
  runs at every position with no prefilter on `$`.
- **`(?=(a+)+b)`** (a genuine T2 adversarial): z-regex stops at its step budget after ~32 ms
  with `StepLimitExceeded`: bounded, but not an answer. V8 is exponential; PCRE2 answers at
  once (required-character shortcut).

## Notes

- V8 has a JIT; z-regex doesn't. Both are real.
- Rust regex doesn't support backreferences; the T2 cases are not compared against it.
- Absolute numbers vary with LLVM's code layout between builds; the best of 10 rounds is
  within ~4% (p90) between two series (F7-0).
- Match counts are identical across every engine, z-regex 0.7.0 included, on every case.
- Everything here is one machine, a shared container: compare engines within a table, not
  numbers across machines.
