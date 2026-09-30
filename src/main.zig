//! zregex - ECMAScript Regular Expression Engine in Zig
//!
//! ECMA-262 regular expressions for Zig and C, with no JS engine behind them.
//!
//! **API contract** (docs/API.md): the root of this module and the C API are
//! stable; `internal` is not. Valid syntax that isn't implemented is
//! `error.UnsupportedFeature`, never a wrong result, and a later release only
//! removes such cases: it never adds an error to `RegexError` or `ExecError`.
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

// =============================================================================
// Stable API: the 19 declarations below, and the C API (docs/API.md).
// `internal` is not stable. The freeze: valid syntax that isn't implemented
// is error.UnsupportedFeature, and a later release only removes such cases,
// never adds an error to RegexError or ExecError (docs/API.md, section 3).
// A test fixes this list, RegexError and ExecError (tests/regression_tests.zig).
// =============================================================================

/// The package version.
pub const version = "0.6.0";

/// A compiled pattern: compile once, match many times (`compile`,
/// `compileWithOptions`, `find`, `findAll`, `execAt`, `iterator`,
/// `replace`, ...). Owns its memory until `deinit`.
pub const Regex = @import("regex.zig").Regex;
/// The flags of a pattern (`i`, `m`, `s`, `y`, `u`, `v`, and the possessive
/// extension). The diagnostic fields are outside the stable API.
pub const CompileOptions = @import("compile.zig").CompileOptions;
/// What `Regex.compile`, the byte-offset methods and the one-shot functions
/// fail with. Fixed set: 35 errors, each with a C code (docs/API.md).
pub const RegexError = @import("regex.zig").RegexError;
/// A match of the byte-offset facade (`find`, `findAll`...): `start`, `end`
/// and the captures. Free it with `deinit`.
pub const MatchResult = @import("tier2").matcher.MatchResult;
/// Start and end of a capture (`MatchResult.getCaptureIndices`).
pub const CaptureIndices = @import("tier2").matcher.CaptureIndices;
/// The input of `execAt` and `iterator`: WTF-8 or UTF-16, indices in its own
/// units.
pub const Subject = @import("subject").Subject;
/// Reusable working memory for `execAt` and `iterator` (one per thread).
pub const Scratch = @import("regex.zig").Scratch;
/// Where `execAt` writes a match's slots: two per group, group 0 first.
pub const MatchSlots = @import("regex.zig").MatchSlots;
/// Every match of a subject in order, without allocating (`Regex.iterator`).
pub const MatchIterator = @import("regex.zig").MatchIterator;
/// Execution budgets: `max_steps` per start position, backtrack stack and
/// memo sizes. Exceeding one is an error, never a wrong result.
pub const ExecLimits = @import("regex.zig").ExecLimits;
/// What `execAt` and `MatchIterator.next` fail with. Fixed set: 8 errors.
pub const ExecError = @import("regex.zig").ExecError;

/// One-shot: compile `pattern`, test whether it matches all of `input`, free.
pub const test_ = @import("regex.zig").test_;
/// One-shot: compile `pattern`, return the first match in `input`, free.
pub const find = @import("regex.zig").find;
/// One-shot: compile `pattern`, return every match in `input`, free.
pub const findAll = @import("regex.zig").findAll;
/// One-shot: compile `pattern`, replace the first match (`$1`, `$<name>`,
/// `$&`...), free. The caller frees the result.
pub const replace = @import("regex.zig").replace;
/// One-shot: like `replace`, for every match.
pub const replaceAll = @import("regex.zig").replaceAll;

/// Unicode General_Category lookup, re-exported for reuse outside the regex
/// engine (e.g. ID_Start/ID_Continue in a lexer) without duplicating the
/// UCD-derived tables.
pub const unicode = struct {
    pub const UnicodeProperty = @import("unicode").properties.UnicodeProperty;
    pub const isInCategory = @import("unicode").properties.isInCategory;
};

/// API interna. Sin garantía de estabilidad.
/// Puede cambiar en cualquier release.
///
/// The engine's pieces, for this repository's tests, tools and bench.
pub const internal = struct {
    // Utils
    pub const DynBuf = @import("utils").dynbuf.DynBuf;
    pub const BitSet256 = @import("utils").bitset.BitSet256;
    pub const DynBitSet = @import("utils").bitset.DynBitSet;
    pub const Pool = @import("utils").pool.Pool;
    pub const Pooled = @import("utils").pool.Pooled;
    pub const debug = @import("utils").debug;
    pub const Budget = @import("utils").budget.Budget;

    // Bytecode
    pub const Opcode = @import("tier2").opcodes.Opcode;
    pub const OpcodeCategory = @import("tier2").opcodes.OpcodeCategory;
    pub const Instruction = @import("tier2").format.Instruction;
    pub const BytecodeWriter = @import("tier2").writer.BytecodeWriter;
    pub const BytecodeReader = @import("tier2").reader.BytecodeReader;
    pub const disassemble = @import("tier2").reader.disassemble;

    // Frontend
    pub const Token = @import("frontend").lexer.Token;
    pub const TokenType = @import("frontend").lexer.TokenType;
    pub const Lexer = @import("frontend").lexer.Lexer;
    pub const Node = @import("frontend").ast.Node;
    pub const NodeType = @import("frontend").ast.NodeType;
    pub const Parser = @import("frontend").parser.Parser;
    pub const ParseError = @import("frontend").parser.ParseError;
    pub const lower = @import("frontend").lower;

    // Compilation
    pub const CodeGenerator = @import("tier2").generator.CodeGenerator;
    pub const CodegenError = @import("tier2").generator.CodegenError;
    pub const MAX_PROGRAM_BYTES = @import("tier2").generator.MAX_PROGRAM_BYTES;
    pub const compile = @import("compile.zig").compile;
    pub const compileSimple = @import("compile.zig").compileSimple;
    pub const CompileResult = @import("compile.zig").CompileResult;
    pub const compileTiers = @import("compile.zig").compileTiers;
    pub const Compiled = @import("compile.zig").Compiled;
    /// Why `CompileOptions.force_tier` can't be honored (`tier_diagnostic`).
    pub const TierUnavailable = @import("compile.zig").TierUnavailable;
    pub const NamedGroup = @import("compile.zig").NamedGroup;
    /// Whether this build runs patterns without an explicit `force_tier` on
    /// the backtracker (`-Dforce-backtracker`-style builds; tests only, F4a(5)).
    pub const force_backtracker = @import("build_options").force_backtracker;

    // IR, subject, tiers
    pub const CharSet = @import("ir").charset.CharSet;
    pub const hir = @import("ir").hir;
    /// The subject module: `Subject`, its decoding modes and helpers.
    pub const subject = @import("subject");
    /// The backtracker (Tier 2): bytecode, code generator, matcher.
    pub const tier2 = @import("tier2");
    /// The linear-time VM (Tier 0, F4a).
    pub const tier0 = @import("tier0");
    pub const Capture = @import("tier2").thread.Capture;
    pub const Matcher = @import("tier2").matcher.Matcher;

    // Tier classification (docs/REGEX_TIERS_PLAN.md): the features a
    // pattern uses and the minimum execution tier they need.
    pub const analysis = @import("analysis/classify.zig");
    pub const analyze = analysis.analyze;

    /// D5 fallbacks of the tagged VM (F4b): must stay 0 (see there).
    pub const two_pass_fallbacks = &@import("regex.zig").two_pass_fallbacks;
};

// Test aggregation: this module's own files. Every other module (ir,
// unicode, utils, frontend, tier2, ...) has its own test binary, compiled
// with only the modules it may import (build.zig, F2e).
test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(internal);
    _ = @import("compile.zig");
    _ = @import("regex.zig");
    _ = @import("analysis/classify.zig");
}

test "version info" {
    try std.testing.expect(version.len > 0);
}
