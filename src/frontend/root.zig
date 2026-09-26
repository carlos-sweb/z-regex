//! `frontend`: pattern text -> AST -> HIR (lexer, parser, lowering). Shared
//! by `compile()` and `analyze()`; depends on `ir` and `unicode` (the parser
//! resolves `\p{...}` names, the lowering materializes CharSets), so T0 can't
//! depend on it: T0 reads the HIR only (F2e).

pub const lexer = @import("parser/lexer.zig");
pub const ast = @import("parser/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const lower = @import("lower/lower.zig");

test {
    _ = @import("parser/parser_tests.zig");
    _ = lower;
}
