//! Tier 0 (docs/REGEX_TIERS_PLAN.md): the linear-time VM for regular
//! patterns without Unicode data (F4a). It may import only `ir` (it reads
//! the HIR, and of a CharSet node only `set`), `utils` and `subject` (the
//! input it runs over): never `unicode`, the front end or `tier2`
//! (build.zig's layer table, checked by `zig build check-layers`).

const ir = @import("ir");

/// What T0 consumes: the HIR.
pub const hir = ir.hir;
pub const program = @import("program.zig");
pub const compile_mod = @import("compile.zig");

pub const Program = program.Program;
pub const Ineligible = compile_mod.Ineligible;
pub const check = compile_mod.check;
pub const compile = compile_mod.compile;

test {
    _ = program;
    _ = compile_mod;
}
