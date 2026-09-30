# z-regex v0.5.1

E0, the first stage of the road to 1.0 (`docs/plans/ROADMAP_1.0.md`). Details in
`docs/LIMITATIONS.md`, "The rule: honest errors", and `docs/HISTORY.md`, "E0: honest errors (0.5.1), measurements".

## Honest errors

**Rule:** valid syntax that zregex doesn't implement is `error.UnsupportedFeature` (C API
`ZREGEXP_ERROR_UNSUPPORTED`, code 9). It is never a wrong result and never a SyntaxError
name. The 1.0 freeze relies on it: what comes later only removes error cases.

- **`\q{…}` under `v` gave a wrong result.** It was read as the letter `q` followed by text:
  `/^[\q{abc|d}]$/v` matched "q", "|" and "a", and not "abc". It is now
  `UnsupportedFeature`.
- Also `UnsupportedFeature` under `v`:
  - a bare character or a shorthand as a set operand (`[\p{L}--a]`, `[\w--\d]`);
  - a union with a nested class (`[[a][b]]`, `[a[b]]`);
  - the same operator chained (`[A--B--C]`);
  - the 7 properties of strings (`\p{RGI_Emoji}`…).
- RegExp modifiers (`(?i:a)`, ES2025; pending until further notice) are `UnsupportedFeature`
  in any mode.
- `[A--B&&C]` (operators mixed) is a SyntaxError, now named `MixedClassSetOperators`.
  `ChainedClassSetOperatorNotSupported` is gone.
- **`v` applies `u`'s early errors.** They were applied under `u` only, so `\z`, `\q` or
  `\p` without braces compiled under `v`, and V8 rejects them.
  - Internal corpora (44,443 patterns): 340 changed status. 335 are now a SyntaxError, and
    V8 rejects every one. 4 are forms above that are now `UnsupportedFeature`. 1 is the
    limit case documented in LIMITATIONS.
  - The 3,667 `v` patterns that compile before and after give the same matches.
- **A backreference to a duplicated group name gave a wrong result.**
  `/^(?:(?<x>a)|(?<x>b))\k<x>$/` didn't match "bb": `\k<x>` only looked at the first `x`.
  It now refers to every group of that name, one `BACK_REF` each. At most one of them
  participates, and a group that didn't matches empty, which is BackreferenceMatcher's
  semantics in ES2025. `\1` still refers to group 1 only. It was found by running test262
  with Node 24.
- **A leak fixed on the way:** a lexer error right after a nested class under `v` didn't
  free that class. It already existed, but it became reachable once `v` applied `u`'s early
  errors. The fuzz stress found it; tests `[[a]\z]` and `[[a]--[b]\z]` cover it.

## test262

- **2968 of the 3017 entries that run, unchanged; 821 skipped.** The badge and the README
  now say both, with the skipped entries by reason:
  - `v`: 312;
  - modifiers: 377;
  - duplicate named groups: 24;
  - `RegExp.escape`: 40;
  - legacy RegExp: 52;
  - host: 16.
- **Measured with Node 24** (not the harness's Node, which stays 22):
  - 68 more entries pass before the backreference fix, and 72 after it. 40 of them are
    `RegExp.escape`, which exercises V8's own function, not zregex.
  - The 4 that failed (`named-groups/duplicate-names-exec.js` and `-match.js`) are the
    backreference bug above. They pass now in UTF-16 and WTF-8. Their assertions are
    ported to `tests/regression_tests.zig`.

## Unchanged

`differential-v8` is identical to `diff-F7a.json`. The internal differentials are at 0.
The `.so` exports 40 symbols.

Binary (`scripts/measure_binary.sh`):

| Build | v0.5.0 | v0.5.1 | Change |
|---|---|---|---|
| ReleaseFast | 1,096,512 B | 1,098,160 B | +1,648 |
| ReleaseSmall | 696,488 B | 697,864 B | +1,376 |
