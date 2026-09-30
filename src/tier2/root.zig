//! Tier 2: the current backtracker (docs/REGEX_TIERS_PLAN.md, F2e). Its
//! code generator turns the HIR into bytecode, which only this Tier reads
//! (T0/T1 generate their own programs from the HIR, F4a on). The
//! explicit-stack backtracker (`executor/backtrack.zig`, F6a) runs it, every
//! pattern since B′ (F6b step 1: lookbehind of fixed length).

pub const opcodes = @import("bytecode/opcodes.zig");
pub const format = @import("bytecode/format.zig");
pub const writer = @import("bytecode/writer.zig");
pub const reader = @import("bytecode/reader.zig");
pub const generator = @import("codegen/generator.zig");
pub const program = @import("program.zig");
pub const matcher = @import("executor/matcher.zig");
pub const core = @import("executor/core.zig");
pub const thread = @import("executor/thread.zig");

pub const backtrack = @import("executor/backtrack.zig");
pub const BacktrackerFor = backtrack.BacktrackerFor;
pub const ExecLimits = backtrack.ExecLimits;
pub const CompileResult = program.CompileResult;

test {
    _ = @import("bytecode/bytecode_tests.zig");
    _ = @import("codegen/codegen_tests.zig");
    _ = @import("executor/executor_tests.zig");
    _ = program;
}
