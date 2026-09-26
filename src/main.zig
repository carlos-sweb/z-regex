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
pub const DynBuf = @import("utils").dynbuf.DynBuf;
pub const BitSet256 = @import("utils").bitset.BitSet256;
pub const DynBitSet = @import("utils").bitset.DynBitSet;
pub const Pool = @import("utils").pool.Pool;
pub const Pooled = @import("utils").pool.Pooled;
pub const debug = @import("utils").debug;

// Bytecode module exports
pub const Opcode = @import("tier2").opcodes.Opcode;
pub const OpcodeCategory = @import("tier2").opcodes.OpcodeCategory;
pub const Instruction = @import("tier2").format.Instruction;
pub const BytecodeWriter = @import("tier2").writer.BytecodeWriter;
pub const BytecodeReader = @import("tier2").reader.BytecodeReader;
pub const disassemble = @import("tier2").reader.disassemble;

// Parser module exports
pub const Token = @import("frontend").lexer.Token;
pub const TokenType = @import("frontend").lexer.TokenType;
pub const Lexer = @import("frontend").lexer.Lexer;
pub const Node = @import("frontend").ast.Node;
pub const NodeType = @import("frontend").ast.NodeType;
pub const Parser = @import("frontend").parser.Parser;
pub const ParseError = @import("frontend").parser.ParseError;

// Codegen module exports
pub const CodeGenerator = @import("tier2").generator.CodeGenerator;
pub const CodegenError = @import("tier2").generator.CodegenError;
pub const MAX_PROGRAM_BYTES = @import("tier2").generator.MAX_PROGRAM_BYTES;
pub const Optimizer = @import("tier2").optimizer.Optimizer;
pub const OptLevel = @import("tier2").optimizer.OptLevel;
pub const compile = @import("compile.zig").compile;
pub const compileSimple = @import("compile.zig").compileSimple;
pub const CompileOptions = @import("compile.zig").CompileOptions;
pub const CompileResult = @import("compile.zig").CompileResult;
pub const compileTiers = @import("compile.zig").compileTiers;
pub const Compiled = @import("compile.zig").Compiled;
pub const TierUnavailable = @import("compile.zig").TierUnavailable;
pub const CharSet = @import("ir").charset.CharSet;
/// The input a regex runs over: WTF-8 or UTF-16, indices in its own units (F3).
pub const subject = @import("subject");
pub const Subject = subject.Subject;
pub const hir = @import("ir").hir;
pub const lower = @import("frontend").lower;
/// The backtracker (Tier 2): bytecode, code generator, matcher.
pub const tier2 = @import("tier2");
/// The linear-time VM (Tier 0, F4a).
pub const tier0 = @import("tier0");
pub const NamedGroup = @import("compile.zig").NamedGroup;

// Executor module exports
pub const Capture = @import("tier2").thread.Capture;
pub const Matcher = @import("tier2").matcher.Matcher;
pub const MatchResult = @import("tier2").matcher.MatchResult;
pub const CaptureIndices = @import("tier2").matcher.CaptureIndices;

// Tier classification (docs/REGEX_TIERS_PLAN.md, F0a prototype): reports
// the features a pattern uses and the minimum execution tier they need.
// Classification only -- nothing dispatches on it yet.
pub const analysis = @import("analysis/classify.zig");
pub const analyze = analysis.analyze;

// High-level Regex API
pub const Regex = @import("regex.zig").Regex;
pub const Scratch = @import("regex.zig").Scratch;
pub const MatchSlots = @import("regex.zig").MatchSlots;
pub const ExecLimits = @import("regex.zig").ExecLimits;
pub const ExecError = @import("regex.zig").ExecError;
pub const test_ = @import("regex.zig").test_;
pub const find = @import("regex.zig").find;
pub const findAll = @import("regex.zig").findAll;

// Unicode General_Category lookup, re-exported for reuse outside the regex
// engine (e.g. z-lexer's ID_Start/ID_Continue identifier classification) --
// avoids duplicating the ~21k lines of UCD-derived tables in tables.zig.
pub const unicode = struct {
    pub const UnicodeProperty = @import("unicode").properties.UnicodeProperty;
    pub const isInCategory = @import("unicode").properties.isInCategory;
};

// Placeholder for development
pub fn placeholder() void {
    std.debug.print("zregex v{s} - Not yet implemented\n", .{version});
    std.debug.print("See ROADMAP.md for development timeline\n", .{});
}

// Test aggregation: this module's own files. Every other module (ir,
// unicode, utils, frontend, tier2, ...) has its own test binary, compiled
// with only the modules it may import (build.zig, F2e).
test {
    std.testing.refAllDecls(@This());
    _ = @import("compile.zig");
    _ = @import("regex.zig");
    _ = @import("analysis/classify.zig");
}

test "version info" {
    try std.testing.expect(version.len > 0);
    try std.testing.expectEqualStrings("0.16.0", zig_version_required);
}
