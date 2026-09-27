//! Tier 2: the current backtracker (docs/REGEX_TIERS_PLAN.md, F2e). Its
//! code generator turns the HIR into bytecode, which only this Tier reads
//! (T0/T1 generate their own programs from the HIR, F4a on); the recursive
//! matcher runs it. Replaced by the explicit-stack backtracker in F6a.

pub const opcodes = @import("bytecode/opcodes.zig");
pub const format = @import("bytecode/format.zig");
pub const writer = @import("bytecode/writer.zig");
pub const reader = @import("bytecode/reader.zig");
pub const generator = @import("codegen/generator.zig");
pub const optimizer = @import("codegen/optimizer.zig");
pub const program = @import("program.zig");
pub const matcher = @import("executor/matcher.zig");
pub const recursive_matcher = @import("executor/recursive_matcher.zig");
pub const thread = @import("executor/thread.zig");

pub const RecursiveMatcher = recursive_matcher.RecursiveMatcher;
pub const RecursiveMatcherFor = recursive_matcher.RecursiveMatcherFor;
pub const ExecOptions = recursive_matcher.ExecOptions;
pub const CompileResult = program.CompileResult;

test {
    _ = @import("bytecode/bytecode_tests.zig");
    _ = @import("codegen/codegen_tests.zig");
    _ = @import("executor/executor_tests.zig");
    _ = program;
}
