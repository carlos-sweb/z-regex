//! `ir`: the representation every Tier shares (docs/REGEX_TIERS_PLAN.md,
//! F2e). Depends on nothing but std, so T0 can use it without the Unicode
//! tables.

pub const charset = @import("charset.zig");
pub const hir = @import("hir.zig");
pub const CharSet = charset.CharSet;

test {
    _ = charset;
    _ = hir;
}
