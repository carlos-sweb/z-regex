//! Backtracker (tier2) tests that need the whole pipeline -- parse, lower,
//! generate, then run. Moved here from `src/tier2/` in F2e: inside the tier2
//! module they would have to import the front end and the compile pipeline,
//! which are above it (docs/REGEX_TIERS_PLAN.md, F2e). Unchanged otherwise.

const std = @import("std");
const zregex = @import("zregex");

const Matcher = zregex.Matcher;
const RecursiveMatcher = zregex.tier2.RecursiveMatcher;
const ExecOptions = zregex.tier2.ExecOptions;
const CodeGenerator = zregex.CodeGenerator;
const BytecodeWriter = zregex.BytecodeWriter;
const Opcode = zregex.Opcode;
const Lexer = zregex.Lexer;
const Parser = zregex.Parser;
const lower = zregex.lower;
const hir = zregex.hir;
const format = zregex.tier2.format;

// --- from src/tier2/executor/matcher.zig ---

test "Matcher: matchFull success" {
    const compiler = zregex;

    const compiled = try compiler.compileSimple(std.testing.allocator, "hello");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.matchFull("hello");

    try std.testing.expect(result);
}

test "Matcher: CHAR_SET without its CharSet table is InvalidCharSet, not a panic" {
    const compiler = zregex;
    const compiled = try compiler.compileSimple(std.testing.allocator, "[\u{E9}]");
    defer compiled.deinit();

    // Bytecode alone (no table) isn't executable.
    const bare = Matcher.init(std.testing.allocator, compiled.bytecode);
    try std.testing.expectError(error.InvalidCharSet, bare.find("\u{E9}"));

    const full = Matcher.initCompiled(std.testing.allocator, compiled);
    const m = (try full.find("x\u{E9}")).?;
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.start);
}

test "Matcher: matchFull failure" {
    const compiler = zregex;

    const compiled = try compiler.compileSimple(std.testing.allocator, "hello");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.matchFull("world");

    try std.testing.expect(!result);
}

test "Matcher: find match" {
    const compiler = zregex;

    const compiled = try compiler.compileSimple(std.testing.allocator, "world");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.find("hello world");

    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "Matcher: find no match" {
    const compiler = zregex;

    const compiled = try compiler.compileSimple(std.testing.allocator, "xyz");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.find("hello world");

    try std.testing.expect(result == null);
}

test "Matcher: find with capture" {
    const compiler = zregex;

    const compiled = try compiler.compileSimple(std.testing.allocator, "(wo..)");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.find("hello world");

    try std.testing.expect(result != null);
    defer result.?.deinit();

    const captured = result.?.getCapture(1, "hello world");
    try std.testing.expect(captured != null);
    try std.testing.expectEqualStrings("worl", captured.?);
}

test "Matcher: findAll multiple matches" {
    const compiler = zregex;

    const compiled = try compiler.compileSimple(std.testing.allocator, "a");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    var matches = try matcher.findAll("banana", false);
    defer {
        for (matches.items) |match| {
            match.deinit();
        }
        matches.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 3), matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), matches.items[0].start);
    try std.testing.expectEqual(@as(usize, 3), matches.items[1].start);
    try std.testing.expectEqual(@as(usize, 5), matches.items[2].start);
}

test "Matcher: findAll no matches" {
    const compiler = zregex;

    const compiled = try compiler.compileSimple(std.testing.allocator, "x");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    var matches = try matcher.findAll("hello", false);
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "Matcher: test_ function" {
    const compiler = zregex;

    const compiled = try compiler.compileSimple(std.testing.allocator, "test");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);

    try std.testing.expect(try matcher.test_("test"));
    try std.testing.expect(!try matcher.test_("fail"));
}

// --- from src/tier2/executor/recursive_matcher.zig ---

test "RecursiveMatcher: question quantifier" {
    const compiler = zregex;

    const result = try compiler.compileSimple(std.testing.allocator, "a?");
    defer result.deinit();

    // Test with empty string (should match)
    {
        var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, "");
        defer matcher.deinit();
        const exec_result = try matcher.matchFrom(0, 0);
        try std.testing.expect(exec_result.matched);
        try std.testing.expectEqual(@as(usize, 0), exec_result.end_pos);
    }

    // Test with "a" (should match and consume)
    {
        var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, "a");
        defer matcher.deinit();
        const exec_result = try matcher.matchFrom(0, 0);
        try std.testing.expect(exec_result.matched);
        try std.testing.expectEqual(@as(usize, 1), exec_result.end_pos);
    }
}

test "RecursiveMatcher: simple star quantifier" {
    const compiler = zregex;

    const result = try compiler.compileSimple(std.testing.allocator, "a*");
    defer result.deinit();

    // Test with empty string (should match)
    {
        var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, "");
        defer matcher.deinit();
        const exec_result = try matcher.matchFrom(0, 0);
        try std.testing.expect(exec_result.matched);
        try std.testing.expectEqual(@as(usize, 0), exec_result.end_pos);
    }

    // Test with "aaa" (should match)
    {
        var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, "aaa");
        defer matcher.deinit();
        const exec_result = try matcher.matchFrom(0, 0);

        try std.testing.expect(exec_result.matched);
        try std.testing.expectEqual(@as(usize, 3), exec_result.end_pos);
    }
}

test "RecursiveMatcher: ReDoS protection - step limit" {
    const compiler = zregex;

    // Patrón que causa backtracking exponencial: (a+)+b
    const result = try compiler.compileSimple(std.testing.allocator, "(a+)+b");
    defer result.deinit();

    // Input malicioso: muchas 'a's sin 'b' al final
    const malicious_input = "aaaaaaaaaaaaaaaaaaaaX"; // 20 'a's + 'X'

    var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, malicious_input);
    defer matcher.deinit();

    // Debería alcanzar el límite de pasos y lanzar error
    const exec_result = matcher.matchFrom(0, 0);
    try std.testing.expectError(error.StepLimitExceeded, exec_result);
}

test "RecursiveMatcher: quantified backreference to an empty capture doesn't crash" {
    // Regression test for a real crash found via test262-derived conformance
    // testing (see docs/ECMASCRIPT_COMPATIBILITY_PLAN.md Phase 6): `\1+`
    // where group 1 can capture zero characters used to segfault (stack
    // overflow) with the DEFAULT recursion limit, because isStarConsumePath
    // didn't recognize BACK_REF as a quantifiable atom, so the loop fell
    // through to plain recursive alternation with no zero-width-progress
    // guard. Uses the real default ExecOptions (matching what every public
    // Regex.find/test_ call actually uses) -- previous versions of this
    // exact call crashed the whole test binary, not just failed a `try`.
    const compiler = zregex;
    const result = try compiler.compileSimple(std.testing.allocator, "(a*)b\\1+");
    defer result.deinit();

    var matcher = RecursiveMatcher.init(std.testing.allocator, result.bytecode, "baaac");
    defer matcher.deinit();
    const exec_result = try matcher.matchFrom(0, 0);
    try std.testing.expect(exec_result.matched);
    // Matches "b": group 1 captures "" (no leading 'a' at position 0), \1+
    // matches that empty capture once (satisfying "+") and stops repeating
    // since it makes no further progress. This matches real JS semantics --
    // this exact pattern/input is test262's S15.10.2.9_A1_T5.js, which
    // expects ["b", ""].
    try std.testing.expectEqual(@as(usize, 1), exec_result.end_pos);
}

test "RecursiveMatcher: ReDoS protection - recursion limit" {
    const compiler = zregex;

    // NOTE: a bare `a+` no longer exercises this -- isStarConsumePath now
    // recognizes single-atom `+` loops (see the "quantified backref"
    // crash fix) and routes them through the iterative matchStarGreedy
    // path, which doesn't consume recursion depth per repetition. A
    // group-wrapped repetition `(a)+` isn't eligible for that
    // optimization (the repeated "atom" is a multi-instruction group, not
    // a single opcode), so it still recurses once per repetition and is a
    // faithful test of the recursion-limit mechanism itself.
    const result = try compiler.compileSimple(std.testing.allocator, "(a)+");
    defer result.deinit();

    // Crear matcher con límites muy bajos
    const options = ExecOptions.withLimits(5, 50);
    var matcher = RecursiveMatcher.initWithOptions(
        std.testing.allocator,
        result.bytecode,
        "aaaaaaaaaa", // 10 'a's
        options,
    );
    defer matcher.deinit();

    // Debería alcanzar el límite de recursión
    const exec_result = matcher.matchFrom(0, 0);
    try std.testing.expectError(error.RecursionLimitExceeded, exec_result);
}

test "RecursiveMatcher: 1000 groups capture exactly, and \\1000 matches (D9)" {
    // Past the default recursion limit (3 levels per group), so the limit is
    // lifted and the match runs on a 64 MiB thread: this checks the capture
    // storage (heap slots, u16 indices), not the stack (F6a).
    const Ctx = struct {
        ok: bool = false,
        fn run(ctx: *@This()) void {
            ctx.ok = check() catch false;
        }
        fn check() !bool {
            const gpa = std.heap.page_allocator;
            var pattern: std.ArrayListUnmanaged(u8) = .empty;
            defer pattern.deinit(gpa);
            for (0..1000) |_| try pattern.appendSlice(gpa, "(.)");
            try pattern.appendSlice(gpa, "\\1000");
            var input: [1001]u8 = undefined;
            for (input[0..1000], 0..) |*c, i| c.* = @intCast('!' + (i % 94));
            input[1000] = input[999];

            const compiled = try zregex.compileSimple(gpa, pattern.items);
            defer compiled.deinit();
            var m = RecursiveMatcher.initWithOptions(gpa, compiled.bytecode, &input, ExecOptions.withLimits(0, 0));
            defer m.deinit();
            const r = try m.matchFrom(0, 0);
            if (!r.matched or r.end_pos != 1001) return false;
            const caps = m.captureSlice();
            if (caps.len != 1001) return false;
            for (1..1001) |g| {
                if (caps[g].start != g - 1 or caps[g].end != g) return false;
            }
            return true;
        }
    };
    var ctx: Ctx = .{};
    const t = try std.Thread.spawn(.{ .stack_size = 64 << 20 }, Ctx.run, .{&ctx});
    t.join();
    try std.testing.expect(ctx.ok);
}

// --- from src/tier2/codegen/generator.zig ---

const TestProgram = struct {
    writer: BytecodeWriter,
    code: []const u8,

    fn deinit(self: *TestProgram) void {
        self.writer.deinit();
    }
};

/// Parse, lower and generate `pattern` (`flags` as the root scope).
fn testProgram(pattern: []const u8, flags: hir.Flags) !TestProgram {
    const a = std.testing.allocator;

    var lexer = Lexer.init(pattern);
    var parser = try Parser.init(a, &lexer);
    defer parser.deinit();
    const ast_root = try parser.parse();
    defer ast_root.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const root = try lower.lower(arena.allocator(), ast_root, flags, &.{});

    var program: TestProgram = .{ .writer = BytecodeWriter.init(a), .code = &.{} };
    errdefer program.writer.deinit();
    var gen = CodeGenerator.init(a, &program.writer);
    defer gen.deinit();
    try gen.generate(root);
    program.code = try program.writer.finalize();
    return program;
}

test "CodeGenerator: simple character" {
    var p = try testProgram("a", .{});
    defer p.deinit();
    // CHAR32 'a', MATCH
    try std.testing.expectEqual(@intFromEnum(Opcode.CHAR32), p.code[0]);
    try std.testing.expectEqual(@intFromEnum(Opcode.MATCH), p.code[p.code.len - 1]);
}

test "CodeGenerator: a literal is one CHAR32 per character" {
    var p = try testProgram("abc", .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 3 * 5 + 1), p.code.len);
}

test "CodeGenerator: alternation starts with SPLIT" {
    var p = try testProgram("a|b", .{});
    defer p.deinit();
    try std.testing.expectEqual(@intFromEnum(Opcode.SPLIT), p.code[0]);
}

test "CodeGenerator: quantifiers" {
    for ([_][]const u8{ "a*", "a+", "a{2,4}", "a{2,}?" }) |pattern| {
        var p = try testProgram(pattern, .{});
        defer p.deinit();
        try std.testing.expect(p.code.len > 0);
    }
}

test "CodeGenerator: group" {
    var p = try testProgram("(ab)", .{});
    defer p.deinit();
    try std.testing.expectEqual(@intFromEnum(Opcode.SAVE_START), p.code[0]);
}

test "CodeGenerator: anchors follow the scope's m flag" {
    var p = try testProgram("^a$", .{});
    defer p.deinit();
    try std.testing.expectEqual(@intFromEnum(Opcode.STRING_START), p.code[0]);
    var m = try testProgram("^a$", .{ .multiline = true });
    defer m.deinit();
    try std.testing.expectEqual(@intFromEnum(Opcode.LINE_START), m.code[0]);
}

test "CodeGenerator: dot excludes newline by default" {
    var p = try testProgram(".", .{});
    defer p.deinit();
    // Without dot_all, '.' must exclude '\n' (matches JS default): CHAR now
    // means "any Unicode scalar value except newline" (decoded at match time).
    try std.testing.expectEqual(@intFromEnum(Opcode.CHAR), p.code[0]);
}

test "CodeGenerator: dot matches newline with dot_all" {
    var p = try testProgram(".", .{ .dot_all = true });
    defer p.deinit();
    // With dot_all, '.' matches newline too, so it compiles to the dedicated
    // CHAR_ANY opcode instead of the newline-excluding CHAR opcode.
    try std.testing.expectEqual(@intFromEnum(Opcode.CHAR_ANY), p.code[0]);
}

test "CodeGenerator: a?/a?? clear inner captures on skip, a{0,1} doesn't" {
    var q = try testProgram("(a)?", .{});
    defer q.deinit();
    var c = try testProgram("(a){0,1}", .{});
    defer c.deinit();
    try std.testing.expect(try hasOpcode(q.code, .CLEAR_CAPTURE));
    try std.testing.expect(!try hasOpcode(c.code, .CLEAR_CAPTURE));
}

fn hasOpcode(code: []const u8, op: Opcode) !bool {
    var pc: usize = 0;
    while (pc < code.len) {
        const inst = try format.decodeInstruction(code, pc);
        if (inst.opcode == op) return true;
        pc += inst.size;
    }
    return false;
}
