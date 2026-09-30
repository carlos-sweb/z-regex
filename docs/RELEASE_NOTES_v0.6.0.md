# z-regex v0.6.0

E1, the second stage of the road to 1.0 (`docs/plans/ROADMAP_1.0.md`): F6b, lookbehind
matched backward. Details in `docs/LIMITATIONS.md`, "Lookbehind", `docs/HISTORY.md`, "F6b (0.6.0): measurements", and
`docs/plans/E1.md`.

## Lookbehind

Up to v0.5.1 only a lookbehind of fixed length without captures ran (B′); any other was
`UnsupportedFeature`. Outside `u`/`v`, these now run too:

- **Variable length:** `(?<=a+)b`, `(?<=a|bc)d`, `(?<=^a*)b`.
- **Capture groups inside, fixed length or not**, saved as the spec's backward matching
  gives them: `/(?<=(\d+)(\d+))$/.exec("1053")` captures `"1"` and `"053"`.
- **Backreferences inside**, compared right to left against the text before the position:
  `/(?<=\1(a))b/.exec("aab")` matches at 2. Under `i` in WTF-8, characters that fold equal
  but take different byte lengths compare, for example U+2C65 and U+023A.

**Still `UnsupportedFeature`** (never a wrong result):
- **A lookaround inside a lookbehind matched backward**, for example `(?<=a(?=b)c+)`. This
  is a 1.x decision. A lookaround inside a fixed lookbehind already ran, and still does. A
  backward lookbehind inside a fixed one also runs, for example `(?<=a(?<=b+))`.
- **Under `u`/`v`, a lookbehind matched backward** (variable length, captures or
  backreferences inside). Only B′'s form runs under those flags.

## How it works

Architecture B, chosen by E1's spike (P3) out of four measured with callgrind:
- **Code generation:** the body of a backward lookbehind is emitted in reverse, and each
  of its atoms becomes its backward form. That form is the same opcode with the high bit
  set, from `CHAR_B` to `BYTE_B`, plus `BACK_REF_B` and `BACK_REF_I_B`.
- **New opcodes:** `LOOKBEHIND` and `NEGATIVE_LOOKBEHIND`.
- **Forward path:** no executor state holds the direction, so matching forward doesn't
  test it on each character.
  - Measured on 16 cases, B's worst case is +0.977 %.
  - Keeping the direction as executor state reached +1.84 %.
- **LookLinear** doesn't delegate backward bodies. Doing it is for 1.x.

## test262

- **2994 of the 3017 entries that run (99.2 %), up from 2968; 821 skipped**, the same as
  v0.5.1. UTF-16 and WTF-8 give the same results.
- **`lookBehind/`: 32 of 34, up from 6.** The 2 left are `nested-lookaround`, which is the
  1.x decision above. `named-groups/lookbehind.js` (2 entries, under `u`) also doesn't pass.

## Against V8

`lbdiff-v8` runs 5,580 patterns with a lookbehind, at every `lastIndex`, on UTF-16 subjects:
- **Fixed-length patterns:** the 1,279 didn't change.
- **The other 4,301:** 2,733 now agree with V8, up from 3. The 1,568 that don't are all
  `UnsupportedFeature`:
  - 724 under `u`/`v`;
  - 844 with a lookaround inside a backward body.
- **No pattern gave a different result.**

**Other checks, unchanged:**
- The lookbehind oracle (`zig build lbdiff`) gave 0 discrepancies on 13,142 pairs.
- `differential-v8` is identical to `diff-F7a.json`.
- The internal differentials are at 0.
- The `.so` exports 40 symbols.

## Binary

Measured with `scripts/measure_binary.sh`:

| Build | v0.5.1 | v0.6.0 | Change |
|---|---|---|---|
| ReleaseFast | 1,098,160 B | 1,111,536 B | +13,376 |
| ReleaseSmall | 697,864 B | 704,328 B | +6,464 |
