//! Tier 0 (docs/REGEX_TIERS_PLAN.md): the linear-time VM for regular
//! patterns without Unicode data. Empty until F4a; this module exists so F4a
//! starts isolated. It may import only `ir` (it reads the HIR, and of a
//! CharSet node only `set`), `utils` and `subject` (the input it runs
//! over): never `unicode`, the front end or `tier2` (build.zig's layer
//! table, checked by `zig build check-layers`).

const ir = @import("ir");

/// What T0 consumes: the HIR.
pub const hir = ir.hir;

test "tier0 sees the HIR" {
    _ = hir.Node;
}
