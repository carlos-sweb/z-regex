//! Tier 1 (docs/REGEX_TIERS_PLAN.md): regular patterns that need Unicode
//! data or large counted repetition. Empty until its phase; it may import
//! `ir`, `unicode`, `utils`, `subject` and `tier0`, never `tier2` (build.zig's layer
//! table, checked by `zig build check-layers`).

const ir = @import("ir");
const tier0 = @import("tier0");

pub const hir = ir.hir;

test "tier1 sees the HIR and tier0" {
    _ = hir.Node;
    _ = tier0.hir;
}
