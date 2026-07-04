//! zregexp - ECMAScript Regular Expression Engine in Zig
//!
//! A modern, safe, and efficient regex engine inspired by QuickJS's libregexp.
//!
//! Example usage:
//! ```zig
//! const std = @import("std");
//! const regex = @import("zregexp");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     // Compile and reuse
//!     var re = try regex.Regex.compile(allocator, "hello");
//!     defer re.deinit();
//!
//!     if (try re.test_("hello world")) {
//!         std.debug.print("Match found!\n", .{});
//!     }
//!
//!     // One-shot matching
//!     if (try regex.test_(allocator, "\\d+", "Price: 42")) {
//!         std.debug.print("Contains numbers!\n", .{});
//!     }
//! }
//! ```

const std = @import("std");

// Version information
pub const version = "0.1.0";
pub const zig_version_required = "0.16.0";

// Utils module exports
pub const DynBuf = @import("utils/dynbuf.zig").DynBuf;
pub const BitSet256 = @import("utils/bitset.zig").BitSet256;
pub const DynBitSet = @import("utils/bitset.zig").DynBitSet;
pub const Pool = @import("utils/pool.zig").Pool;
pub const Pooled = @import("utils/pool.zig").Pooled;
pub const debug = @import("utils/debug.zig");

// Bytecode module exports
pub const Opcode = @import("bytecode/opcodes.zig").Opcode;
pub const OpcodeCategory = @import("bytecode/opcodes.zig").OpcodeCategory;
pub const Instruction = @import("bytecode/format.zig").Instruction;
pub const BytecodeWriter = @import("bytecode/writer.zig").BytecodeWriter;
pub const BytecodeReader = @import("bytecode/reader.zig").BytecodeReader;

// Parser module exports
pub const Token = @import("parser/lexer.zig").Token;
pub const TokenType = @import("parser/lexer.zig").TokenType;
pub const Lexer = @import("parser/lexer.zig").Lexer;
pub const Node = @import("parser/ast.zig").Node;
pub const NodeType = @import("parser/ast.zig").NodeType;
pub const Parser = @import("parser/parser.zig").Parser;
pub const ParseError = @import("parser/parser.zig").ParseError;

// Codegen module exports
pub const CodeGenerator = @import("codegen/generator.zig").CodeGenerator;
pub const CodegenError = @import("codegen/generator.zig").CodegenError;
pub const Optimizer = @import("codegen/optimizer.zig").Optimizer;
pub const OptLevel = @import("codegen/optimizer.zig").OptLevel;
pub const compile = @import("codegen/compiler.zig").compile;
pub const compileSimple = @import("codegen/compiler.zig").compileSimple;
pub const CompileOptions = @import("codegen/compiler.zig").CompileOptions;
pub const CompileResult = @import("codegen/compiler.zig").CompileResult;

// Executor module exports
pub const Thread = @import("executor/thread.zig").Thread;
pub const ThreadQueue = @import("executor/thread.zig").ThreadQueue;
pub const Capture = @import("executor/thread.zig").Capture;
pub const VM = @import("executor/vm.zig").VM;
pub const ExecResult = @import("executor/vm.zig").ExecResult;
pub const Matcher = @import("executor/matcher.zig").Matcher;
pub const MatchResult = @import("executor/matcher.zig").MatchResult;

// High-level Regex API
pub const Regex = @import("regex.zig").Regex;
pub const test_ = @import("regex.zig").test_;
pub const find = @import("regex.zig").find;
pub const findAll = @import("regex.zig").findAll;

// Placeholder for development
pub fn placeholder() void {
    std.debug.print("zregexp v{s} - Not yet implemented\n", .{version});
    std.debug.print("See ROADMAP.md for development timeline\n", .{});
}

// Test aggregation
test {
    std.testing.refAllDecls(@This());

    // Utils module tests (implemented)
    _ = @import("utils/utils_tests.zig");

    // Bytecode module tests (implemented)
    _ = @import("bytecode/bytecode_tests.zig");

    // Parser module tests (implemented)
    _ = @import("parser/parser_tests.zig");

    // Codegen module tests (implemented)
    _ = @import("codegen/codegen_tests.zig");

    // Executor module tests (implemented)
    _ = @import("executor/executor_tests.zig");

    // Regex API tests (implemented)
    _ = @import("regex.zig");

    // To be implemented:
    // _ = @import("unicode/unicode_tests.zig");
}

test "version info" {
    try std.testing.expect(version.len > 0);
    try std.testing.expectEqualStrings("0.16.0", zig_version_required);
}
