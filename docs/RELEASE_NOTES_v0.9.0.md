# z-regex v0.9.0

**API unchanged. F5c: the `v` flag on T0.**

The API is still the one frozen in 0.7.0 (`docs/API.md`): the same 40 C symbols, the same
`RegexError` and `ExecError`. What changes is the `v` flag (`unicodeSets`):
- it accepts the class set syntax ECMA-262 allows and rejects what it forbids;
- `\q{...}` and the 7 properties of strings compile;
- `v` patterns run on T0 (the Pike VMs and the code-point DFA) instead of the backtracker.

Without `v`, no match, capture, error or index changes.

## What changed

F5c, in five steps (each one its own commit, with its gate):

- **Laxity** (`25be7b3`). Under `v`, these are now `InvalidClassSetOperand`, an existing
  name:
  - an unescaped `(` `)` `{` `}` `/` `|`;
  - a doubled reserved punctuator (`!!`, `^^`, …);
  - a `-` that is neither a range nor `--`.

  The 13 reserved-punctuator escapes (`\&`, `\!`, `\#`, …) compile as the character. 105
  `v` patterns of the corpora stop compiling, all of them SyntaxErrors in V8.
- **Block 1.1** (`315450a`). These compile; they were `UnsupportedFeature`:
  - a bare character or shorthand as the right operand of `--`/`&&` (`[\p{L}--a]`,
    `[\w--\d]`);
  - one operator chained, left to right (`[A--B--C]`, `[A&&B&&C]`);
  - a union with nested classes (`[[a][b]]`, `[a[b]]`);
  - a nested operation as an operand (`[[[a]--[b]]--[c]]`).

  The set operation node is n-ary, so a long chain costs no recursion.
- **2a + 2b** (`cd7c368`). Under `v`:
  - `\q{...}` (ClassStringDisjunction) compiles with strings of any length, in unions and in
    set operations;
  - `\p{Emoji_Keycap_Sequence}` (12 strings, emoji 17.0) compiles alone, in a class and in set
    operations.

  A class with strings is lowered to an alternation of nodes the HIR already had, in
  ECMA-262's CompileAtom order: the strings longest first (a trie by prefix), then the
  single code points, then the empty string. A negated class that may contain strings
  (`[^\q{ab}]`) is `InvalidClassSetOperand` (MayContainStrings). Under `iv` the strings are
  simple-case-folded before the set operations.

  The two sorts of the string lists then moved to heap sort (`4597406`): −56 KB of
  ReleaseFast `.text`, the same results.
- **2c-a** (`c63a640`). These compile:
  - `Basic_Emoji`;
  - `RGI_Emoji_Modifier_Sequence`, `RGI_Emoji_Flag_Sequence`, `RGI_Emoji_Tag_Sequence` and
    `RGI_Emoji_ZWJ_Sequence`;
  - `RGI_Emoji` (3,953 strings).

  The 7 properties live in two compact tables (`KEYCAP_STRINGS`, `EMOJI_STRINGS`):
  - a dictionary of 436 code points;
  - the strings as u16 indices into it, with u16 offsets.

  `-Dproperties_of_strings=false` leaves the six new properties `UnsupportedFeature` and
  doesn't link `EMOJI_STRINGS`.
- **2c-b** (`b751bef`). `v` patterns route to T0 as `u` patterns do:
  - set operations, `\q{...}` and the properties of strings are HIR sets and alternations,
    which the VMs and the code-point DFA match like any other;
  - backreferences, lookarounds and counted repeats above the unroll budget stay on the
    backtracker, as with `u`;
  - over the corpora, 2,221 of the 2,551 `v` patterns that compile moved from the
    backtracker to T0 (1,909 plain, 312 with groups);
  - the DFA isn't attempted above 2,000 program instructions (`dfa.max_insts_for_dfa`). The
    corpora's largest program with a DFA has 1,079; `\p{RGI_Emoji}` programs run on the VM.

  The differentials on the new routing, with 0 differences:
  - `t1diff`: 8,857 patterns;
  - `dfadiff`: 31,874 programs, 7,665 code-point DFAs;
  - `pfdiff`: 5,378 tagged programs.

## Measured

**Against 0.8.0**, the previous publication: `bench/compare`, the same 10 interleaved rounds,
`-Dcpu=x86_64_v3`, `execAt` MB/s, best round (`docs/BENCHMARKS.md`, "Against 0.8.0"). The
mixed-script corpus, 1 MiB:

| `v` pattern | 0.8.0 | 0.9.0 | Factor | V8 |
|---|---|---|---|---|
| `[\p{L}--[a-z]]` | 24.8 | 61.6 | 2.5× | 34.8 |
| `\p{Script=Greek}{3,}` | 33.1 | 198.1 | 6.0× | 125.8 |
| `[\p{L}--[a-z]]{4}` | 29.0 | 126.8 | 4.4× | 41.3 |
| `\b\p{Lu}{5}\b` | 24.9 | 202.5 | 8.1× | 194.9 |
| `[\p{L}\p{N}_]+\u{1F600}` | 7.9 | 192.5 | 24.4× | 12.2 |
| `(\p{Lu})(\p{Ll}+)\.$` | 14.9 | 210.4 | 14.1× | 62.9 |

- Every `u`, T0 and T2 case is within ±10% of 0.8.0, except `\d{3}-\d{4}` (sparse 1.29×,
  dense 1.11×). Its route (Shift-And) didn't change, so that is the host, not 0.9.0.
- No case is worse by more than 10%.
- Match counts are identical across every engine.

**The 2c-b probe** (the node bridge, a 1 MB input with the match at the end):
- the `v` patterns are **10× to 57× faster** than on 0.8.0's backtracker (10.3×, 12.8×,
  14.7×, 57× and 32×);
- `^\p{RGI_Emoji}+$` over the 3,953 strings concatenated: 79.65 → 27.01 ms (**2.9×**), from
  5.3× to 1.8× behind V8.

**`\p{RGI_Emoji}+` in the bench** (a corpus of words with one emoji in four), where 0.8.0 has
no number because it rejects the property:
- 0.7 MB/s against V8's 1.8 (2.6× behind);
- 14.5 µs on a short input.

The program is above the DFA's limit, so the Pike VM carries the whole trie at every position.

**Compile time (accepted).** A `v` pattern now builds T0's program and its DFA where 0.8.0
built a backtracker program.
- In the bench: +6 to +169 µs per small pattern (`\b\p{Lu}{5}\b` 1.0 → 170 µs,
  `[\p{L}--[a-z]]{4}` 9.8 → 110 µs).
- In the 2c-b probe, through the node bridge: +0.2–0.3 ms (`[\p{L}--[a-z]]{4}` 0.36 →
  0.57 ms).
- `\p{RGI_Emoji}+` compiles in 10.4 ms (~13 ms through the bridge), without a DFA.

The cost is paid once per compiled pattern.

## Binary and conformance

- **Shared library** (`scripts/measure_binary.sh`, x86_64_v3, stripped):
  - ReleaseFast 1,266,112 B (+51,552 B against 0.8.0);
  - ReleaseSmall 796,360 B (+42,208 B);
  - 40 exported `zregex_*` symbols.

  Most of the growth is the tables of the properties of strings: with
  `-Dproperties_of_strings=false`, ReleaseFast is 1,233,696 B and ReleaseSmall 765,032 B
  (measured at 2c-a).
- **test262: 3305/3328**, in UTF-16 and in WTF-8 (0.8.0: 2994/3017). The `v` subset was
  activated before F5c, then each step added entries:

  | Step | test262 |
  |---|---|
  | `v` subset activated | 3087/3110 |
  | Laxity | 3113/3136 |
  | Block 1.1 | 3159/3182 |
  | 2a + 2b | 3281/3304 |
  | 2c-a | 3303/3326 |
  | 2c-b | 3305/3328 |

  Of the `v` flag's 314 entries, 311 run and pass.
- **`zregex_version()`:** `"0.9.0"`.

## What remains of ECMA-262

Each of these is `UnsupportedFeature` today, never a wrong result (`docs/LIMITATIONS.md`):

- **Lookbehind under `u`/`v` matched backward** (variable length, captures or backreferences
  inside): `/(?<=a+)b/u`. 1.x; 2 test262 entries.
- **B6, a lookaround inside a lookbehind matched backward:** `(?<=a(?=b)c+)`. 1.x; 2 test262
  entries.
- **RegExp modifiers (ES2025):** `(?i:a)`. Pending until further notice; their 377 test262
  entries are skipped.
- **`RegExp.escape` (ES2025):** a library function, not pattern syntax. zregex has no
  `escape` helper yet (1.x, additive).
- **`i` with `v`** on operands not closed under the folding (`/\p{Lu}/iv`, `/[^a-z]/iv`):
  1.x.

## What comes next

- **v0.9.0 → a pause: production use** (z-interpreter and other consumers), with the same
  API.
- **Then v1.0.0**, or the 1.x items above if production asks for them first.
