# Benchmarks: z-regex against V8, Rust regex, PCRE2, zig-regex and zoptia0regex

**v0.9.1: migrate Zig 0.16 to 0.17.** This publication measures the migration
without experimental performance workarounds. v0.9.0, compiled with Zig 0.16,
runs in the same rounds as the baseline. The public API and C ABI are unchanged.

The three investigated regressions remain open: literal `hello`, book `Darcy`,
and short execution of `\b\p{Lu}{5}\b /v`. See the
[upgrade-gap index](ZIG_0.17_UPGRADE_GAPS.md) for source and generated-code evidence.
This release accepts those known gaps; it does not claim performance parity.
Older release notes preserve their original measurements on other machines.

## Setup

Aggregated 2026-10-11T15:49:11.404Z; 10 complete, interleaved rounds.

| Item | Configuration |
|---|---|
| CPU | Intel(R) Core(TM) i3-10100F CPU @ 3.60GHz; 4 physical cores, 8 logical CPUs, SMT 2 threads/core |
| Frequency scaling | intel_pstate; governor powersave; configuration unchanged during measurement |
| RAM | 31.19 GiB usable reported memory (33,486,692,352 bytes; nominal 32 GB) |
| OS | Fedora Linux 44 (Workstation Edition); kernel 7.2.7-200.fc44.x86_64 |
| Execution | CPU affinity 0-7; no explicit core pinning; hypervisor: none reported; container marker present: false |
| z-regex | 0.9.1, Zig 0.17.0, ReleaseFast, x86_64_v3 (AVX2) |
| Baseline | 0.9.0, tag v0.9.0 (`1690c9f`), Zig 0.16.0, ReleaseFast, x86_64_v3 |
| V8 | 14.6.202.34-node.24, Node v26.5.0 |
| Rust regex | 1.13.1; rustc 1.98.1 (48a229cea 2026-09-01) (Fedora 1.98.1-1.fc44); release, LTO |
| PCRE2 | 10.47; 8-bit library, JIT and interpreter |
| zig-regex | 0.1.1 (zig-utils/zig-regex, 173b298); Zig 0.16, ReleaseFast, native |
| zoptia0regex | Commit `8e8f225`; Zig 0.16, ReleaseFast, x86_64_v3 |
| C compiler | cc (GCC) 16.2.1 20260819 (Red Hat 16.2.1-2) |

The full metadata, binary SHA-256 values and corpus SHA-256 values are in
[`bench/results.json`](../bench/results.json). The benchmark binary reports
0.9.1; it was built from the release working tree before the release commit.
`source_base_revision` identifies its parent and `source_dirty` records that fact.
No compilation or other test suite ran concurrently with timing.

## Method

The engine order rotates across ten rounds. Within a round, throughput uses
the median of up to five timed passes after warm-up. Tables show the **best
round**, with the **minimum–maximum range** in parentheses: highest throughput,
lowest latency, compile time or size. JSON also retains medians and sample counts.
Compare engines within the same case and metric; do not combine tiers or hosts.

The repository regression criterion is more than 10% additional time in the
best-round comparison, followed by a focused probe or profile to establish
whether it is reproducible. The precision study from F7-0 used a different,
shared VM: its approximately 4% p90 estimate is historical and has not been
recalibrated on this machine. A small timing difference alone is not evidence
of a regression. The three linked investigations supply confirmation for the
known migration gaps.

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
- Throughput is over the corpus's UTF-8 bytes, the same count for every engine.
  Tables retain the historical MB/s label; the harness divides by 1024², so
  these values are MiB/s.

**Semantics check.** Every engine that runs a case finds the same number of matches on it
(checked by `analyze.mjs` on every run). For T0, Rust regex runs with `regex::bytes` and
`unicode(false)`, so `\d`, `\w` and classes are ASCII as in ECMAScript without `u`.

## Corpora

- **Synthetic**: 1 MiB per input, from a fixed-seed xorshift32 generator
  (`bench/compare/gen_corpus.mjs`; seeds 1–11, one per input: prose, prose with rare
  "hello", sparse phone numbers, dense digits, e-mails, `a`/`b` runs, mixed-script Unicode,
  HTML, prices, password-like lines, and since 0.9.0 words with one RGI emoji in four, drawn
  from 12 of the six kinds: basic, keycap, modifier, flag, tag and ZWJ sequences). Byte-identical on every run and machine.
- **Realistic**: *Pride and Prejudice* (Project Gutenberg #1342, public domain, 724,725 bytes,
  UTF-8 with CRLF), from GITenberg's mirror at commit `81db45c`, sha256
  `48e0522844402a86a3ea98f0947ba85ea54838db3c59022299298ed968a5a163`
  (`bench/compare/fetch_book.sh` checks it).
- **Adversarial**: `a` × n followed by `c` (no match) or by `cb` (still no match, but it
  defeats PCRE2's required-character shortcut, which rejects `a^n c` without trying).
  Each run in its own process, killed after 5 s.

## Headline: warm execAt

Ratios use the best rounds in the tables below. “Even” means within ±10%.
The iterator and allocating findAll results remain separate metrics.

| Case | Tier | vs V8 | vs Rust regex | vs zoptia0regex |
|---|---|---|---|---|
| literal hello | T0 | 5.74× ahead | 1.69× behind | 8.44× ahead |
| [a-z]+ | T0 | 2.22× ahead | 2.78× ahead | 11.41× ahead |
| [a-z]+ (z-regex: generic VM, no fast path) | T0 | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) | T0 | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) | T0 | 1.62× behind | 2.24× behind | 2.77× ahead |
| \d{3}-\d{4} (dense) | T0 | 2.78× ahead | 6.60× ahead | 32.91× ahead |
| email | T0 | 9.19× ahead | even (0.92×) | 32.70× ahead |
| (\d{3})-(\d{4}) (sparse) | T0 | 3.34× behind | 3.43× behind | 1.44× ahead |
| (\d{3})-(\d{4}) (dense) | T0 | 1.89× behind | 1.26× ahead | 6.47× ahead |
| (?:(a)\|b)*c | T0 | 1.36× behind | 2.37× behind | 2.02× ahead |
| book: Darcy | T0 | even (1.00×) | 1.61× behind | 2.00× ahead |
| book: [A-Z][a-z]+ | T0 | 1.14× ahead | 2.02× ahead | 15.48× ahead |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) | T0 | 1.71× ahead | 2.52× behind | 1.39× ahead |
| \p{L}+ /u | T1 | 1.27× ahead | even (0.94×) | 3.34× ahead |
| \p{Script=Greek}+ /u | T1 | 1.14× ahead | 1.48× behind | 4.04× ahead |
| \p{General_Category=Lu} /u | T1 | 1.19× ahead | 1.37× behind | 3.79× ahead |
| [\p{L}--[a-z]] /v | T1 | 1.28× ahead | n/a | 3.10× ahead |
| book: \p{L}+ /u | T1 | 1.93× ahead | 1.30× ahead | 4.32× ahead |
| \p{Script=Greek}{3,} /v | T1 | 1.11× ahead | n/a | 4.36× ahead |
| [\p{L}--[a-z]]{4} /v | T1 | 2.33× ahead | n/a | 4.31× ahead |
| \b\p{Lu}{5}\b /v | T1 | 1.34× behind | n/a | 3.08× ahead |
| [\p{L}\p{N}_]+\u{1F600} /v | T1 | 13.56× ahead | n/a | 6.21× ahead |
| (\p{Lu})(\p{Ll}+)\.$ /v | T1 | 1.36× ahead | n/a | 6.22× ahead |
| \p{RGI_Emoji}+ /v | T1 | 42.40× behind | n/a | n/a |
| <(\w+)>.*?<\/\1> | T2 | 6.60× behind | n/a | n/a |
| (?=.*[a-z])(?=.*[A-Z]).{8,} | T2 | 5.55× behind | n/a | n/a |
| (?<=\$)\d+ | T2 | 62.95× behind | n/a | n/a |
| book: \b(\w+) \1\b | T2 | 11.22× behind | n/a | n/a |

## Known migration gaps in this run

Additional time is `baseline throughput / current throughput - 1` for
throughput metrics, and `current latency / baseline latency - 1` for latency.
These are fresh full-harness measurements; historical focused-study numbers
are retained unchanged in the investigation reports.

| Case | Metric | v0.9.0 / Zig 0.16 | v0.9.1 / Zig 0.17 | Additional time |
|---|---|---|---|---|
| t0_literal | execat_mbps | 17252.68 | 14625.44 | +17.96% |
| t0_literal | iter_mbps | 17291.76 | 14676.31 | +17.82% |
| t0_literal | findall_mbps | 16257.52 | 13556.57 | +19.92% |
| t0_book_name | execat_mbps | 16771.05 | 14293.28 | +17.34% |
| t0_book_name | iter_mbps | 16811.43 | 14300.08 | +17.56% |
| t0_book_name | findall_mbps | 11086.10 | 9704.60 | +14.24% |
| t1_v_lu5 | short_ns | 37.72 | 44.02 | +16.70% |

## Additional flags reviewed

Two additional best-round flags were checked with the **same binary hashes**
and the original corpus. An isolated probe used thirty alternating process
pairs per case on CPU 2. A second probe used ten alternating pairs without
core pinning and retained all sixteen cases preceding the set-subtraction case.

| Case and metric | Full ten-round flag | Isolated probe | Preceding-context probe |
|---|---|---|---|
| `[\p{L}--[a-z]] /v`, compile time | +39.39% | −3.19% best, −3.15% median | −5.34% best, −4.55% median |
| E-mail, short execAt | +10.16% | +6.82% best, +7.99% median | Not run |

Neither additional flag was confirmed above the 10% threshold in these probes.
The full-run compilation signal remains unexplained; it must not be described
as a proven compiler regression or as proven noise. Filtered probes change the
parsed cases document, so they do not establish universal performance parity.
A partial flag on `(\p{Lu})(\p{Ll}+)\.$ /v` fell below the threshold after all
ten rounds and did not require a probe.

[Regression review data](../bench/regression_review_v0.9.1.json) retains every
probe sample, medians, ranges, methods and binary hashes. The three previously
confirmed gaps remain open; no experimental performance patch is retained.

## Reproduction

```sh
# Main compiler: Zig 0.17.0. Pinned Zig competitors still need Zig 0.16.0.
ZIG016=/absolute/path/to/zig-0.16.0/zig bash bench/compare/prepare.sh
# Build v0.9.0 separately with Zig 0.16.0 and a separate cache, then copy
# its zregex_xbench to zig-out/xbench/bin/zregex_base_xbench.
XBENCH_ROUNDS=/tmp/z-regex-v091-rounds node bench/compare/run.mjs 10
XBENCH_BASE_ZIG=0.16.0 XBENCH_ROUNDS=/tmp/z-regex-v091-rounds node bench/compare/analyze.mjs
```

Use an empty rounds directory for a new publication. All engines must run on
the same machine and use the same corpus. No timing result is borrowed from
the historical VM publication. Match counts are checked for every completed
round, including V8's allocating and exec loops.

## Results

“n/a” means the engine does not run that case; “unsupported” means it rejects
the pattern. zig-regex's findAll is omitted because its repeated subject copies
have quadratic growth. zoptia0regex's execAt column uses `matchesScratch`, its
allocation-free iterator. Its RE2 pattern substitutions are described below.

Rounds: 10 interleaved; each cell: the best round (highest MB/s, lowest ns, µs or ms) and the min–max band over the rounds.

#### T0: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex | zig-regex | zoptia0regex |
|---|---|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 13556.6 (10677.3–13556.6) | 2505.8 (2126.7–2505.8) | 2163.7 (1994.2–2163.7) | 24256.5 (22131.2–24256.5) | — | 1728.2 (1626.3–1728.2) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 94.9 (86.9–94.9) | 108.8 (93.1–108.8) | 94.3 (48.7–94.3) | 91.7 (82.6–91.7) | — | 22.2 (18.5–22.2) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 42.2 (26.6–42.2) | n/a | n/a | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 33.1 (30.4–33.1) | n/a | n/a | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 917.0 (743.6–917.0) | 1786.0 (1583.4–1786.0) | 667.0 (201.6–667.0) | 2515.1 (2404.3–2515.1) | — | 412.8 (372.3–412.8) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 381.4 (218.2–381.4) | 250.0 (221.0–250.0) | 200.0 (107.8–200.0) | 113.1 (97.2–113.1) | — | 23.0 (21.6–23.0) |
| email <sub>(z-regex: DFA)</sub> | 729.6 (611.6–729.6) | 108.0 (73.9–108.0) | 94.0 (63.0–94.0) | 1041.5 (991.5–1041.5) | unsupported | 29.9 (27.5–29.9) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 434.9 (234.5–434.9) | 1521.5 (1405.1–1521.5) | 201.4 (182.8–201.4) | 1177.9 (1037.0–1177.9) | — | 416.4 (320.3–416.4) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 99.8 (87.6–99.8) | 216.3 (146.2–216.3) | 165.3 (101.0–165.3) | 84.2 (79.7–84.2) | — | 24.5 (22.1–24.5) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 27.9 (25.3–27.9) | 41.2 (38.9–41.2) | 38.2 (31.2–38.2) | 58.3 (48.5–58.3) | — | 17.2 (14.1–17.2) |
| book: Darcy <sub>(z-regex: VM)</sub> | 9704.6 (5473.9–9704.6) | 13502.5 (11400.3–13502.5) | 4181.5 (3386.3–4181.5) | 21973.4 (13994.3–21973.4) | — | 6954.1 (5186.3–6954.1) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 510.5 (455.1–510.5) | 670.6 (604.5–670.6) | 294.6 (121.3–294.6) | 396.9 (365.3–396.9) | — | 52.4 (44.0–52.4) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 1016.1 (923.9–1016.1) | 670.5 (555.7–670.5) | 517.4 (378.1–517.4) | 2251.8 (1967.6–2251.8) | — | 1043.4 (614.9–1043.4) |

#### T0: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex | zoptia0regex |
|---|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 14625.4 (11811.1–14625.4) | 2547.0 (1893.8–2547.0) | 24710.9 (22835.2–24710.9) | — | 1732.4 (1595.4–1732.4) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 270.0 (257.0–270.0) | 121.6 (108.0–121.6) | 97.3 (87.5–97.3) | — | 23.7 (21.8–23.7) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 60.1 (47.8–60.1) | n/a | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 43.9 (39.0–43.9) | n/a | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 1206.6 (1110.2–1206.6) | 1957.6 (1787.6–1957.6) | 2701.9 (2468.9–2701.9) | — | 435.3 (259.5–435.3) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 759.8 (705.8–759.8) | 272.9 (238.2–272.9) | 115.1 (94.4–115.1) | — | 23.1 (21.7–23.1) |
| email <sub>(z-regex: DFA)</sub> | 982.4 (914.8–982.4) | 106.9 (102.1–106.9) | 1066.7 (1013.9–1066.7) | unsupported | 30.0 (27.9–30.0) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 489.8 (445.7–489.8) | 1634.6 (1424.3–1634.6) | 1678.7 (1535.3–1678.7) | — | 339.6 (258.9–339.6) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 120.8 (112.8–120.8) | 228.3 (208.4–228.3) | 95.9 (91.2–95.9) | — | 18.7 (14.4–18.7) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 30.7 (28.2–30.7) | 41.8 (38.7–41.8) | 72.7 (62.1–72.7) | — | 15.2 (13.9–15.2) |
| book: Darcy <sub>(z-regex: VM)</sub> | 14293.3 (13308.5–14293.3) | 14295.9 (12237.1–14295.9) | 23059.9 (14205.2–23059.9) | — | 7135.8 (6291.1–7135.8) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 826.9 (755.4–826.9) | 727.6 (651.5–727.6) | 408.4 (375.6–408.4) | — | 53.4 (45.3–53.4) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 1133.3 (1048.0–1133.3) | 663.1 (620.2–663.1) | 2851.7 (2752.2–2851.7) | — | 817.4 (653.2–817.4) |

#### T0: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 14676.3 (10616.5–14676.3) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 270.4 (258.1–270.4) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 60.2 (49.4–60.2) |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 43.8 (40.7–43.8) |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 1205.7 (1126.9–1205.7) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 771.7 (716.8–771.7) |
| email <sub>(z-regex: DFA)</sub> | 983.7 (909.0–983.7) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 491.5 (455.4–491.5) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 121.3 (112.1–121.3) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 30.9 (24.5–30.9) |
| book: Darcy <sub>(z-regex: VM)</sub> | 14300.1 (13772.9–14300.1) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 807.1 (770.4–807.1) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 1128.1 (1048.9–1128.1) |

#### T0: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex | zoptia0regex |
|---|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 20 (20–21) | 48 (48–55) | 16 (16–17) | 318 (318–383) | 15 (15–16) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 15 (15–16) | 38 (38–43) | 53 (53–57) | 445 (445–507) | 101 (101–106) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 83 (83–89) | n/a | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 114 (114–124) | n/a | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 19 (19–20) | 47 (47–51) | 50 (50–57) | 1107 (1107–1246) | 96 (96–108) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 19 (19–20) | 47 (47–52) | 50 (50–54) | 1085 (1085–1244) | 97 (97–107) |
| email <sub>(z-regex: DFA)</sub> | 58 (58–65) | 90 (90–97) | 55 (55–59) | unsupported | 248 (248–271) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 237 (237–257) | 67 (67–73) | 88 (88–94) | 2699 (2699–2963) | 104 (104–116) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 234 (234–251) | 67 (67–73) | 87 (87–96) | 2710 (2710–2946) | 105 (105–116) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 317 (317–354) | 44 (44–48) | 99 (99–109) | 2610 (2610–2856) | 156 (156–166) |
| book: Darcy <sub>(z-regex: VM)</sub> | 20 (20–21) | 45 (45–49) | 16 (16–17) | 300 (300–344) | 14 (14–15) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 41 (41–44) | 41 (41–47) | 57 (57–67) | 1333 (1333–1481) | 181 (181–197) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 373 (373–413) | 61 (61–69) | 122 (122–131) | 6604 (6604–7281) | 151 (151–165) |

#### T0: µs per compile

| Case | z-regex | Rust regex | zig-regex | zoptia0regex |
|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 1.18 (1.18–1.25) | 1.97 (1.97–2.08) | 0.78 (0.78–0.83) | 0.81 (0.81–0.85) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 0.94 (0.94–1.01) | 5.35 (5.35–5.60) | 0.42 (0.42–0.45) | 0.56 (0.56–0.90) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 0.92 (0.92–1.21) | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 0.63 (0.63–0.68) | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 1.64 (1.64–2.58) | 128.60 (128.60–137.62) | 1.91 (1.91–2.11) | 1.22 (1.22–1.98) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 1.63 (1.63–2.48) | 126.19 (126.19–132.87) | 1.86 (1.86–2.02) | 1.22 (1.22–1.78) |
| email <sub>(z-regex: DFA)</sub> | 9.02 (9.02–15.54) | 13.84 (13.84–16.17) | unsupported | 1.75 (1.75–2.92) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 2.13 (2.13–3.27) | 128.31 (128.31–135.84) | 2.14 (2.14–3.19) | 1.60 (1.60–1.69) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 2.09 (2.09–3.75) | 129.05 (129.05–139.37) | 1.31 (1.31–1.38) | 1.59 (1.59–1.67) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 5.18 (5.18–5.42) | 8.92 (8.92–9.61) | 0.92 (0.92–0.96) | 1.31 (1.31–1.34) |
| book: Darcy <sub>(z-regex: VM)</sub> | 1.15 (1.15–1.43) | 1.76 (1.76–1.96) | 0.76 (0.76–0.82) | 0.80 (0.80–0.83) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 3.49 (3.49–3.71) | 6.56 (6.56–7.40) | 0.67 (0.67–0.71) | 0.78 (0.78–0.81) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 16.01 (16.01–17.05) | 18.13 (18.13–19.14) | 2.67 (2.67–2.80) | 3.22 (3.22–4.84) |

#### T0: bytes per compiled pattern

| Case | z-regex | zig-regex | zoptia0regex |
|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) | 3532 (3532–3532) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 135 (135–135) | 1016 (1016–1016) | 872 (872–872) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 135 (135–135) | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 19 (19–19) | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 1349 (1349–1349) | 3817 (3817–3817) | 3008 (3008–3008) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 1349 (1349–1349) | 3817 (3817–3817) | 3008 (3008–3008) |
| email <sub>(z-regex: DFA)</sub> | 2165 (2165–2165) | unsupported | 2854 (2854–2854) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 1457 (1457–1457) | 5365 (5365–5365) | 6030 (6030–6030) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 1457 (1457–1457) | 5365 (5365–5365) | 6030 (6030–6030) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 1393 (1393–1393) | 3227 (3227–3227) | 3050 (3050–3050) |
| book: Darcy <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) | 3532 (3532–3532) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 1176 (1176–1176) | 1751 (1751–1751) | 1298 (1298–1298) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 3284 (3284–3284) | 9370 (9370–9370) | 6866 (6866–6866) |

#### T1: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex | zoptia0regex |
|---|---|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 65.9 (60.5–65.9) | 74.7 (69.5–74.7) | 59.7 (45.9–59.7) | 105.6 (92.6–105.6) | 30.4 (26.1–30.4) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 189.8 (172.5–189.8) | 201.4 (186.8–201.4) | 136.1 (91.7–136.1) | 337.4 (310.8–337.4) | 57.2 (50.8–57.2) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 127.4 (116.0–127.4) | 150.7 (135.2–150.7) | 111.1 (75.4–111.1) | 238.0 (230.4–238.0) | 48.6 (43.4–48.6) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 35.8 (33.0–35.8) | 50.5 (44.5–50.5) | 42.9 (22.5–42.9) | n/a | 21.9 (19.3–21.9) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 59.8 (53.7–59.8) | 55.3 (49.4–55.3) | 36.7 (26.1–36.7) | 82.2 (71.5–82.2) | 25.9 (24.0–25.9) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 199.0 (172.5–199.0) | 212.4 (135.9–212.4) | 138.6 (87.3–138.6) | n/a | 53.2 (40.8–53.2) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 114.8 (103.0–114.8) | 65.6 (59.8–65.6) | 54.6 (37.2–54.6) | n/a | 34.9 (30.7–34.9) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 237.6 (224.4–237.6) | 326.4 (303.6–326.4) | 272.2 (259.9–272.2) | n/a | 79.6 (68.1–79.6) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 255.9 (234.0–255.9) | 19.1 (17.7–19.1) | 18.4 (16.6–18.4) | n/a | 41.0 (31.1–41.0) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 245.6 (230.5–245.6) | 178.6 (167.2–178.6) | 156.2 (141.6–156.2) | n/a | 47.2 (41.9–47.2) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 0.9 (0.8–0.9) | 37.6 (34.7–37.6) | 13.7 (10.3–13.7) | n/a | n/a |

#### T1: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex | zoptia0regex |
|---|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 104.3 (90.2–104.3) | 81.9 (74.6–81.9) | 110.6 (98.3–110.6) | 31.2 (25.9–31.2) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 236.1 (220.5–236.1) | 207.3 (191.8–207.3) | 349.4 (327.6–349.4) | 58.5 (53.5–58.5) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 190.8 (166.6–190.8) | 160.3 (138.3–160.3) | 261.2 (235.1–261.2) | 50.3 (44.8–50.3) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 71.9 (66.6–71.9) | 56.1 (48.4–56.1) | n/a | 23.2 (20.4–23.2) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 115.1 (109.4–115.1) | 59.6 (54.8–59.6) | 88.3 (80.7–88.3) | 26.6 (24.0–26.6) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 243.0 (215.3–243.0) | 218.5 (177.6–218.5) | n/a | 55.7 (47.5–55.7) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 153.8 (134.5–153.8) | 66.0 (61.7–66.0) | n/a | 35.7 (31.5–35.7) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 244.9 (228.5–244.9) | 327.4 (310.3–327.4) | n/a | 79.6 (70.4–79.6) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 256.1 (234.1–256.1) | 18.9 (17.4–18.9) | n/a | 41.2 (32.4–41.2) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 246.0 (231.4–246.0) | 180.6 (164.6–180.6) | n/a | 39.6 (36.0–39.6) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 0.9 (0.8–0.9) | 37.8 (34.8–37.8) | n/a | n/a |

#### T1: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 105.5 (99.4–105.5) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 236.2 (223.4–236.2) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 189.2 (152.3–189.2) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 71.9 (60.7–71.9) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 115.5 (104.1–115.5) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 239.1 (223.9–239.1) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 152.9 (139.0–152.9) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 246.4 (227.4–246.4) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 256.0 (238.8–256.0) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 247.6 (230.0–247.6) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 0.9 (0.8–0.9) |

#### T1: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex | zoptia0regex |
|---|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 107 (107–113) | 80 (80–88) | 66 (66–109) | 166 (166–180) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 84 (84–91) | 77 (77–99) | 68 (68–74) | 182 (182–198) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 48 (48–50) | 54 (54–59) | 37 (37–40) | 101 (101–111) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 46 (46–50) | 82 (82–93) | n/a | 100 (100–123) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 29 (29–33) | 36 (36–41) | 49 (49–53) | 88 (88–105) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 81 (81–92) | 74 (74–81) | n/a | 172 (172–194) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 94 (94–101) | 122 (122–131) | n/a | 155 (155–172) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 44 (44–47) | 47 (47–56) | n/a | 179 (179–207) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 52 (52–58) | 239 (239–272) | n/a | 187 (187–209) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 228 (228–248) | 55 (55–89) | n/a | 163 (163–178) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 11132 (11132–12308) | 212 (212–231) | n/a | n/a |

#### T1: µs per compile

| Case | z-regex | Rust regex | zoptia0regex |
|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 28.02 (28.02–30.00) | 220.86 (220.86–231.56) | 6.79 (6.79–6.99) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 4.01 (4.01–4.23) | 36.81 (36.81–53.23) | 0.97 (0.97–1.00) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 27.68 (27.68–28.73) | 130.25 (130.25–138.35) | 10.41 (10.41–10.77) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 45.15 (45.15–77.36) | n/a | 19.44 (19.44–20.42) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 28.13 (28.13–30.28) | 220.54 (220.54–231.54) | 6.83 (6.83–9.66) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 5.79 (5.79–6.13) | n/a | 1.22 (1.22–1.28) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 99.11 (99.11–107.21) | n/a | 14.13 (14.13–14.96) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 170.77 (170.77–179.66) | n/a | 5.21 (5.21–5.49) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 44.32 (44.32–47.75) | n/a | 17.28 (17.28–18.96) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 84.48 (84.48–96.13) | n/a | 15.33 (15.33–16.18) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 9326.87 (9326.87–10115.75) | n/a | n/a |

#### T1: bytes per compiled pattern

| Case | z-regex | zoptia0regex |
|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 22852 (22852–22852) | 15808 (15808–15808) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 2116 (2116–2116) | 1472 (1472–1472) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 21871 (21871–21871) | 15808 (15808–15808) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 28250 (28250–28250) | 15318 (15318–15318) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 22852 (22852–22852) | 15808 (15808–15808) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 2223 (2223–2223) | 5036 (5036–5036) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 28409 (28409–28409) | 15366 (15366–15366) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 24586 (24586–24586) | 15746 (15746–15746) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 32248 (32248–32248) | 15540 (15540–15540) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 30608 (30608–30608) | 42220 (42220–42220) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 528637 (528637–528637) | n/a |

#### T2: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 40.0 (35.4–40.0) | 272.8 (244.8–272.8) | 173.1 (101.9–173.1) | 300.6 (272.6–300.6) | 90.6 (82.7–90.6) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 11.1 (10.2–11.1) | 62.1 (53.5–62.1) | 53.3 (39.6–53.3) | 85.1 (80.2–85.1) | 13.7 (12.1–13.7) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 23.7 (19.3–23.7) | 1404.8 (1081.9–1404.8) | 472.7 (182.3–472.7) | 1154.4 (1044.6–1154.4) | 603.5 (526.0–603.5) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 15.8 (14.5–15.8) | 173.7 (153.2–173.7) | 161.8 (152.1–161.8) | 136.9 (124.9–136.9) | 36.3 (30.4–36.3) |

#### T2: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 44.1 (39.6–44.1) | 291.0 (258.1–291.0) | 313.5 (291.1–313.5) | 91.1 (81.1–91.1) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 11.4 (10.5–11.4) | 63.3 (58.8–63.3) | 85.8 (70.6–85.8) | 13.8 (12.4–13.8) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 24.2 (21.9–24.2) | 1521.3 (1329.4–1521.3) | 1176.5 (1095.6–1176.5) | 615.0 (537.5–615.0) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 15.6 (14.7–15.6) | 175.1 (157.2–175.1) | 138.8 (130.9–138.8) | 36.4 (28.4–36.4) |

#### T2: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 44.4 (40.8–44.4) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 11.4 (10.3–11.4) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 24.0 (19.8–24.0) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 15.6 (14.7–15.6) |

#### T2: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 291 (291–311) | 41 (41–46) | 43 (43–46) | 134 (134–145) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 275 (275–303) | 66 (66–72) | 51 (51–55) | 240 (240–269) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 370 (370–419) | 38 (38–42) | 37 (37–40) | 78 (78–94) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 240 (240–255) | 50 (50–128) | 44 (44–48) | 95 (95–109) |

#### T2: µs per compile

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 2.23 (2.23–2.35) | 6.09 (6.09–6.33) | 0.60 (0.60–0.61) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 3.12 (3.12–3.33) | 5.06 (5.06–5.25) | 0.81 (0.81–0.86) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 1.42 (1.42–2.34) | 3.20 (3.20–6.37) | 0.42 (0.42–0.43) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 1.52 (1.52–1.79) | 5.61 (5.61–5.84) | 0.53 (0.53–0.57) |

#### T2: bytes per compiled pattern

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 92 (92–92) | 1232 (1232–1232) | 184 (184–184) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 1820 (1820–1820) | 930 (930–930) | 247 (247–247) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 714 (714–714) | 650 (650–650) | 172 (172–172) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 59 (59–59) | 1168 (1168–1168) | 176 (176–176) |

#### Adversarial: ms until the engine answers or gives up (best round; outcome)

| Case | n | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) | zoptia0regex |
|---|---|---|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.001 (no match) | 108.042 (no match) | 0.003 (no match) | 0.002 (no match) | 0.003 (no match) |
| (a+)+b on a^n c | 25 | 0.001 (no match) | 3452.506 (no match) | 0.003 (no match) | 0.002 (no match) | 0.006 (no match) |
| (a+)+b on a^n c | 30 | 0.001 (no match) | 5001.000 (timeout (> 5 s, killed)) | 0.003 (no match) | 0.002 (no match) | 0.006 (no match) |
| (a+)+b on a^n c | 40 | 0.001 (no match) | 5001.000 (timeout (> 5 s, killed)) | 0.004 (no match) | 0.002 (no match) | 0.007 (no match) |
| (a+)+b on a^n cb | 20 | 0.001 (no match) | 109.324 (no match) | 8.167 (no match) | 76.879 (no match) | 0.003 (no match) |
| (a+)+b on a^n cb | 25 | 0.001 (no match) | 3450.493 (no match) | 19.192 (match limit) | 145.912 (match limit) | 0.006 (no match) |
| (a+)+b on a^n cb | 30 | 0.001 (no match) | 5001.000 (timeout (> 5 s, killed)) | 19.426 (match limit) | 145.318 (match limit) | 0.006 (no match) |
| (a+)+b on a^n cb | 40 | 0.001 (no match) | 5001.000 (timeout (> 5 s, killed)) | 19.229 (match limit) | 145.116 (match limit) | 0.007 (no match) |
| (?=(a+)+b) on a^n c | 20 | 20.779 (StepLimitExceeded) | 108.749 (no match) | 0.003 (no match) | 0.002 (no match) | — |
| (?=(a+)+b) on a^n c | 25 | 21.327 (StepLimitExceeded) | 3445.417 (no match) | 0.004 (no match) | 0.002 (no match) | — |
| (?=(a+)+b) on a^n c | 30 | 21.419 (StepLimitExceeded) | 5006.000 (timeout (> 5 s, killed)) | 0.003 (no match) | 0.002 (no match) | — |
| (?=(a+)+b) on a^n c | 40 | 21.194 (StepLimitExceeded) | 5007.000 (timeout (> 5 s, killed)) | 0.004 (no match) | 0.002 (no match) | — |

#### z-regex 0.9.1 against z-regex 0.9.0, same rounds (best round; ratio > 1: better now)

| Case | Tier | execAt MB/s now | 0.9.0 | ratio | findAll MB/s now | 0.9.0 | ratio | ns short now | 0.9.0 | ratio |
|---|---|---|---|---|---|---|---|---|---|---|
| literal hello | T0 | 14625.4 | 17252.7 | 0.85 | 13556.6 | 16257.5 | 0.83 | 20 | 20 | 0.99 |
| [a-z]+ | T0 | 270.0 | 263.8 | 1.02 | 94.9 | 95.0 | 1.00 | 15 | 16 | 1.05 |
| [a-z]+ (z-regex: generic VM, no fast path) | T0 | 60.1 | 64.4 | 0.93 | 42.2 | 44.0 | 0.96 | 83 | 80 | 0.96 |
| [a-z]+ (z-regex: backtracker) | T0 | 43.9 | 41.2 | 1.06 | 33.1 | 31.0 | 1.07 | 114 | 115 | 1.01 |
| \d{3}-\d{4} (sparse) | T0 | 1206.6 | 1181.9 | 1.02 | 917.0 | 896.1 | 1.02 | 19 | 21 | 1.09 |
| \d{3}-\d{4} (dense) | T0 | 759.8 | 720.2 | 1.05 | 381.4 | 381.9 | 1.00 | 19 | 21 | 1.10 |
| email | T0 | 982.4 | 1023.9 | 0.96 | 729.6 | 735.0 | 0.99 | 58 | 53 | 0.91 |
| (\d{3})-(\d{4}) (sparse) | T0 | 489.8 | 439.5 | 1.11 | 434.9 | 382.5 | 1.14 | 237 | 282 | 1.19 |
| (\d{3})-(\d{4}) (dense) | T0 | 120.8 | 102.3 | 1.18 | 99.8 | 85.5 | 1.17 | 234 | 285 | 1.22 |
| (?:(a)\|b)*c | T0 | 30.7 | 28.8 | 1.07 | 27.9 | 26.1 | 1.07 | 317 | 355 | 1.12 |
| book: Darcy | T0 | 14293.3 | 16771.0 | 0.85 | 9704.6 | 11086.1 | 0.88 | 20 | 19 | 0.98 |
| book: [A-Z][a-z]+ | T0 | 826.9 | 820.9 | 1.01 | 510.5 | 523.4 | 0.98 | 41 | 41 | 1.00 |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) | T0 | 1133.3 | 963.9 | 1.18 | 1016.1 | 834.7 | 1.22 | 373 | 456 | 1.22 |
| \p{L}+ /u | T1 | 104.3 | 109.1 | 0.96 | 65.9 | 67.2 | 0.98 | 107 | 101 | 0.94 |
| \p{Script=Greek}+ /u | T1 | 236.1 | 238.3 | 0.99 | 189.8 | 199.4 | 0.95 | 84 | 80 | 0.95 |
| \p{General_Category=Lu} /u | T1 | 190.8 | 191.2 | 1.00 | 127.4 | 128.3 | 0.99 | 48 | 48 | 1.00 |
| [\p{L}--[a-z]] /v | T1 | 71.9 | 72.1 | 1.00 | 35.8 | 36.2 | 0.99 | 46 | 47 | 1.02 |
| book: \p{L}+ /u | T1 | 115.1 | 118.6 | 0.97 | 59.8 | 61.5 | 0.97 | 29 | 28 | 0.95 |
| \p{Script=Greek}{3,} /v | T1 | 243.0 | 246.4 | 0.99 | 199.0 | 200.3 | 0.99 | 81 | 79 | 0.98 |
| [\p{L}--[a-z]]{4} /v | T1 | 153.8 | 157.4 | 0.98 | 114.8 | 115.9 | 0.99 | 94 | 91 | 0.97 |
| \b\p{Lu}{5}\b /v | T1 | 244.9 | 265.4 | 0.92 | 237.6 | 259.6 | 0.92 | 44 | 38 | 0.86 |
| [\p{L}\p{N}_]+\u{1F600} /v | T1 | 256.1 | 250.1 | 1.02 | 255.9 | 250.3 | 1.02 | 52 | 51 | 0.99 |
| (\p{Lu})(\p{Ll}+)\.$ /v | T1 | 246.0 | 268.7 | 0.92 | 245.6 | 267.2 | 0.92 | 228 | 268 | 1.17 |
| \p{RGI_Emoji}+ /v | T1 | 0.9 | 0.9 | 1.01 | 0.9 | 0.9 | 1.00 | 11132 | 11231 | 1.01 |
| <(\w+)>.*?<\/\1> | T2 | 44.1 | 40.1 | 1.10 | 40.0 | 36.6 | 1.09 | 291 | 318 | 1.09 |
| (?=.*[a-z])(?=.*[A-Z]).{8,} | T2 | 11.4 | 10.9 | 1.04 | 11.1 | 10.5 | 1.06 | 275 | 293 | 1.06 |
| (?<=\$)\d+ | T2 | 24.2 | 21.0 | 1.15 | 23.7 | 20.9 | 1.13 | 370 | 406 | 1.10 |
| book: \b(\w+) \1\b | T2 | 15.6 | 12.0 | 1.30 | 15.8 | 12.1 | 1.30 | 240 | 249 | 1.04 |

| Adversarial | n | now | 0.9.0 |
|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.001 (no match) | 0.001 (no match) |
| (a+)+b on a^n c | 25 | 0.001 (no match) | 0.001 (no match) |
| (a+)+b on a^n c | 30 | 0.001 (no match) | 0.001 (no match) |
| (a+)+b on a^n c | 40 | 0.001 (no match) | 0.001 (no match) |
| (a+)+b on a^n cb | 20 | 0.001 (no match) | 0.001 (no match) |
| (a+)+b on a^n cb | 25 | 0.001 (no match) | 0.001 (no match) |
| (a+)+b on a^n cb | 30 | 0.001 (no match) | 0.001 (no match) |
| (a+)+b on a^n cb | 40 | 0.001 (no match) | 0.001 (no match) |
| (?=(a+)+b) on a^n c | 20 | 20.779 (StepLimitExceeded) | 23.073 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 25 | 21.327 (StepLimitExceeded) | 22.923 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 30 | 21.419 (StepLimitExceeded) | 23.057 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 40 | 21.194 (StepLimitExceeded) | 23.189 (StepLimitExceeded) |

#### z-regex 0.9.1 against zoptia0regex 8e8f225, same rounds (best round; ratio > 1: z-regex ahead)

| Case | Tier | execAt MB/s z-regex | zoptia | ratio | findAll MB/s z-regex | zoptia | ratio | ns short z-regex | zoptia | ratio | µs compile z-regex | zoptia | ratio |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| literal hello | T0 | 14625.4 | 1732.4 | 8.44 | 13556.6 | 1728.2 | 7.84 | 20 | 15 | 0.73 | 1.18 | 0.81 | 0.69 |
| [a-z]+ | T0 | 270.0 | 23.7 | 11.41 | 94.9 | 22.2 | 4.27 | 15 | 101 | 6.80 | 0.94 | 0.56 | 0.59 |
| \d{3}-\d{4} (sparse) | T0 | 1206.6 | 435.3 | 2.77 | 917.0 | 412.8 | 2.22 | 19 | 96 | 5.09 | 1.64 | 1.22 | 0.74 |
| \d{3}-\d{4} (dense) | T0 | 759.8 | 23.1 | 32.91 | 381.4 | 23.0 | 16.57 | 19 | 97 | 5.16 | 1.63 | 1.22 | 0.75 |
| email | T0 | 982.4 | 30.0 | 32.70 | 729.6 | 29.9 | 24.39 | 58 | 248 | 4.25 | 9.02 | 1.75 | 0.19 |
| (\d{3})-(\d{4}) (sparse) | T0 | 489.8 | 339.6 | 1.44 | 434.9 | 416.4 | 1.04 | 237 | 104 | 0.44 | 2.13 | 1.60 | 0.75 |
| (\d{3})-(\d{4}) (dense) | T0 | 120.8 | 18.7 | 6.47 | 99.8 | 24.5 | 4.07 | 234 | 105 | 0.45 | 2.09 | 1.59 | 0.76 |
| (?:(a)\|b)*c | T0 | 30.7 | 15.2 | 2.02 | 27.9 | 17.2 | 1.62 | 317 | 156 | 0.49 | 5.18 | 1.31 | 0.25 |
| book: Darcy | T0 | 14293.3 | 7135.8 | 2.00 | 9704.6 | 6954.1 | 1.40 | 20 | 14 | 0.73 | 1.15 | 0.80 | 0.70 |
| book: [A-Z][a-z]+ | T0 | 826.9 | 53.4 | 15.48 | 510.5 | 52.4 | 9.75 | 41 | 181 | 4.40 | 3.49 | 0.78 | 0.22 |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) | T0 | 1133.3 | 817.4 | 1.39 | 1016.1 | 1043.4 | 0.97 | 373 | 151 | 0.41 | 16.01 | 3.22 | 0.20 |
| \p{L}+ /u | T1 | 104.3 | 31.2 | 3.34 | 65.9 | 30.4 | 2.17 | 107 | 166 | 1.55 | 28.02 | 6.79 | 0.24 |
| \p{Script=Greek}+ /u | T1 | 236.1 | 58.5 | 4.04 | 189.8 | 57.2 | 3.32 | 84 | 182 | 2.15 | 4.01 | 0.97 | 0.24 |
| \p{General_Category=Lu} /u | T1 | 190.8 | 50.3 | 3.79 | 127.4 | 48.6 | 2.62 | 48 | 101 | 2.11 | 27.68 | 10.41 | 0.38 |
| [\p{L}--[a-z]] /v | T1 | 71.9 | 23.2 | 3.10 | 35.8 | 21.9 | 1.63 | 46 | 100 | 2.16 | 45.15 | 19.44 | 0.43 |
| book: \p{L}+ /u | T1 | 115.1 | 26.6 | 4.32 | 59.8 | 25.9 | 2.31 | 29 | 88 | 3.01 | 28.13 | 6.83 | 0.24 |
| \p{Script=Greek}{3,} /v | T1 | 243.0 | 55.7 | 4.36 | 199.0 | 53.2 | 3.74 | 81 | 172 | 2.13 | 5.79 | 1.22 | 0.21 |
| [\p{L}--[a-z]]{4} /v | T1 | 153.8 | 35.7 | 4.31 | 114.8 | 34.9 | 3.29 | 94 | 155 | 1.64 | 99.11 | 14.13 | 0.14 |
| \b\p{Lu}{5}\b /v | T1 | 244.9 | 79.6 | 3.08 | 237.6 | 79.6 | 2.99 | 44 | 179 | 4.06 | 170.77 | 5.21 | 0.03 |
| [\p{L}\p{N}_]+\u{1F600} /v | T1 | 256.1 | 41.2 | 6.21 | 255.9 | 41.0 | 6.24 | 52 | 187 | 3.62 | 44.32 | 17.28 | 0.39 |
| (\p{Lu})(\p{Ll}+)\.$ /v | T1 | 246.0 | 39.6 | 6.22 | 245.6 | 47.2 | 5.20 | 228 | 163 | 0.72 | 84.48 | 15.33 | 0.18 |

Match counts: identical across every engine that runs a case.

### Against zoptia0regex

[zoptia0regex](https://github.com/zoptia/zoptia0regex) is a port of Go's `regexp` to Zig 0.16:
RE2 syntax, leftmost-first, linear time (one-pass, Pike VM and bitstate engines, a SIMD
first-byte prefilter). It has no backreferences, lookaround or properties of strings, so it
doesn't run T2, `\p{RGI_Emoji}` or `(?=(a+)+b)`. It runs in the same rounds as every other
engine.

**Metrics.** zoptia0regex has no search from an index, so its "execAt" column is its
`matchesScratch` iterator: every match with its groups, a warm `Scratch`, no allocation.
That is what z-regex's `execAt` loop does. Its findAll is `findAllIndex` (allocating, bounds
only), and its short input is one `findIndexScratch`.

**Patterns.** Six cases are given to zoptia in RE2 syntax (`zoptia_pattern` in `cases.json`),
the same language:
- `\p{Greek}` for `\p{Script=Greek}`;
- `\p{Lu}` for `\p{General_Category=Lu}`;
- `[^\P{L}a-z]` for `[\p{L}--[a-z]]`;
- `\x{1F600}` for `\u{1F600}`.

The match counts are identical on all 21 cases.


## Interpretation

V8's exec loop allocates JavaScript match arrays; z-regex uses caller-owned
slots and a reusable Scratch. findAll includes convenience-wrapper allocation.
Rust regex does not implement ECMAScript `v` or T2 features, so those cells
are not direct competitors. PCRE2 JIT and interpreter are separate modes.
A T2 step-limit outcome bounds the work but is not a successful match answer.

The migration gaps remain open. No candidate-verifier helper, sentinel
representation change or noinline DFA experiment is included in v0.9.1.
