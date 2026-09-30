# Archive

Documents of closed phases, kept as they were written. None of them describes the engine
as it is: see [LIMITATIONS.md](../LIMITATIONS.md), [ARCHITECTURE.md](../ARCHITECTURE.md)
and [HISTORY.md](../HISTORY.md).

| Document | What it was | Replaced by |
|---|---|---|
| `ROADMAP.md` | The first roadmap, phases 0-8 by weeks | [plans/ROADMAP_1.0.md](../plans/ROADMAP_1.0.md) |
| `CONCEPTS.md` | Regex engine concepts, written before the tiers (a single backtracker, timeouts, 255 groups) | [ARCHITECTURE.md](../ARCHITECTURE.md) |
| `README.es.md` | The Spanish README, last updated before 0.3.0 (0.1.0, 402 tests) | [README.md](../../README.md) (English only) |
| `F0C_ANALYSIS.md`, `F0C_T1_BREAKDOWN.md` | F0c's corpus analysis: why the tiers, and what T1 patterns use | [REGEX_TIERS_PLAN.md](../REGEX_TIERS_PLAN.md) |
| `F5_PLAN.md` | The plan of F5 (T1) by stages | F5a and F5b in [HISTORY.md](../HISTORY.md) |
| `F5A_CLOSING.md` | The closing analysis of F5a, before F6a | F5a and F7a in [HISTORY.md](../HISTORY.md) |

Moved here in F7c-5. `F6A_PRECHECK.md` and `ECMASCRIPT_COMPATIBILITY_PLAN.md` are closed
too but stay in `docs/`, since the sources, tests and `build.zig` cite them by path.
