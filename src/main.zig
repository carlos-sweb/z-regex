//! zregex - ECMAScript Regular Expression Engine in Zig
//!
//! A modern, safe, and efficient regex engine inspired by QuickJS's libregexp.
//!
//! Example usage:
//! ```zig
//! const std = @import("std");
//! const regex = @import("zregex");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.DebugAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     // Compile and reuse (test_ requires the whole input to match)
//!     var re = try regex.Regex.compile(allocator, "hello");
//!     defer re.deinit();
//!
//!     if (try re.test_("hello")) {
//!         std.debug.print("Match found!\n", .{});
//!     }
//!
//!     // One-shot substring search
//!     if (try regex.find(allocator, "\\d+", "Price: 42")) |match| {
//!         defer match.deinit();
//!         std.debug.print("Contains numbers!\n", .{});
//!     }
//! }
//! ```

const std = @import("std");

// Version information
pub const version = "0.2.0";
pub const zig_version_required = "0.16.0";

// Utils module exports
pub const DynBuf = @import("utils/dynbuf.zig").DynBuf;
pub const BitSet256 = @import("utils/bitset.zig").BitSet256;
pub const DynBitSet = @import("utils/bitset.zig").DynBitSet;
pub const Pool = @import("utils/pool.zig").Pool;
pub const Pooled = @import("utils/pool.zig").Pooled;
pub const debug = @import("utils/debug.zig");

// Bytecode module exports
pub const Opcode = @import("tier2/bytecode/opcodes.zig").Opcode;
pub const OpcodeCategory = @import("tier2/bytecode/opcodes.zig").OpcodeCategory;
pub const Instruction = @import("tier2/bytecode/format.zig").Instruction;
pub const BytecodeWriter = @import("tier2/bytecode/writer.zig").BytecodeWriter;
pub const BytecodeReader = @import("tier2/bytecode/reader.zig").BytecodeReader;
pub const disassemble = @import("tier2/bytecode/reader.zig").disassemble;

// Parser module exports
pub const Token = @import("frontend/parser/lexer.zig").Token;
pub const TokenType = @import("frontend/parser/lexer.zig").TokenType;
pub const Lexer = @import("frontend/parser/lexer.zig").Lexer;
pub const Node = @import("frontend/parser/ast.zig").Node;
pub const NodeType = @import("frontend/parser/ast.zig").NodeType;
pub const Parser = @import("frontend/parser/parser.zig").Parser;
pub const ParseError = @import("frontend/parser/parser.zig").ParseError;

// Codegen module exports
pub const CodeGenerator = @import("tier2/codegen/generator.zig").CodeGenerator;
pub const CodegenError = @import("tier2/codegen/generator.zig").CodegenError;
pub const MAX_PROGRAM_BYTES = @import("tier2/codegen/generator.zig").MAX_PROGRAM_BYTES;
pub const Optimizer = @import("tier2/codegen/optimizer.zig").Optimizer;
pub const OptLevel = @import("tier2/codegen/optimizer.zig").OptLevel;
pub const compile = @import("compile.zig").compile;
pub const compileSimple = @import("compile.zig").compileSimple;
pub const CompileOptions = @import("compile.zig").CompileOptions;
pub const CompileResult = @import("compile.zig").CompileResult;
pub const CharSet = @import("ir/charset.zig").CharSet;
pub const hir = @import("ir/hir.zig");
pub const lower = @import("frontend/lower/lower.zig");
/// The backtracker (Tier 2): bytecode, code generator, matcher.
pub const tier2 = @import("tier2/root.zig");
pub const NamedGroup = @import("compile.zig").NamedGroup;

// Executor module exports
pub const Capture = @import("tier2/executor/thread.zig").Capture;
pub const Matcher = @import("tier2/executor/matcher.zig").Matcher;
pub const MatchResult = @import("tier2/executor/matcher.zig").MatchResult;
pub const CaptureIndices = @import("tier2/executor/matcher.zig").CaptureIndices;

// Tier classification (docs/REGEX_TIERS_PLAN.md, F0a prototype): reports
// the features a pattern uses and the minimum execution tier they need.
// Classification only -- nothing dispatches on it yet.
pub const analysis = @import("analysis/classify.zig");
pub const analyze = analysis.analyze;

// High-level Regex API
pub const Regex = @import("regex.zig").Regex;
pub const test_ = @import("regex.zig").test_;
pub const find = @import("regex.zig").find;
pub const findAll = @import("regex.zig").findAll;

// Unicode General_Category lookup, re-exported for reuse outside the regex
// engine (e.g. z-lexer's ID_Start/ID_Continue identifier classification) --
// avoids duplicating the ~21k lines of UCD-derived tables in tables.zig.
pub const unicode = struct {
    pub const UnicodeProperty = @import("unicode/properties.zig").UnicodeProperty;
    pub const isInCategory = @import("unicode/properties.zig").isInCategory;
};

// Placeholder for development
pub fn placeholder() void {
    std.debug.print("zregex v{s} - Not yet implemented\n", .{version});
    std.debug.print("See ROADMAP.md for development timeline\n", .{});
}

// Test aggregation
test {
    std.testing.refAllDecls(@This());

    // IR (F2b: CharSet)
    _ = @import("ir/charset.zig");
    _ = @import("ir/hir.zig");
    _ = @import("frontend/lower/lower.zig");

    // Utils module tests (implemented)
    _ = @import("utils/utils_tests.zig");

    // Bytecode module tests (implemented)
    _ = @import("tier2/bytecode/bytecode_tests.zig");

    // Parser module tests (implemented)
    _ = @import("frontend/parser/parser_tests.zig");

    // Codegen module tests (implemented)
    _ = @import("tier2/codegen/codegen_tests.zig");

    // The compile pipeline (parse -> lower -> tier2 codegen)
    _ = @import("compile.zig");

    // Executor module tests (implemented)
    _ = @import("tier2/executor/executor_tests.zig");

    // Regex API tests (implemented)
    _ = @import("regex.zig");

    // Unicode module tests (General_Category properties + simple case folding)
    _ = @import("unicode/unicode_tests.zig");

    // Tier classifier (F0a)
    _ = @import("analysis/classify.zig");
}

test "version info" {
    try std.testing.expect(version.len > 0);
    try std.testing.expectEqualStrings("0.16.0", zig_version_required);
}
