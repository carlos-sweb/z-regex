//! Backtracker (tier2) tests that need the whole pipeline -- parse, lower,
//! generate, then run. Moved here from `src/tier2/` in F2e: inside the tier2
//! module they would have to import the front end and the compile pipeline,
//! which are above it (docs/REGEX_TIERS_PLAN.md, F2e). Unchanged otherwise.

const std = @import("std");
const zregex = @import("zregex");

const Matcher = zregex.internal.Matcher;
const CodeGenerator = zregex.internal.CodeGenerator;
const BytecodeWriter = zregex.internal.BytecodeWriter;
const Opcode = zregex.internal.Opcode;
const Lexer = zregex.internal.Lexer;
const Parser = zregex.internal.Parser;
const lower = zregex.internal.lower;
const hir = zregex.internal.hir;
const format = zregex.internal.tier2.format;

// --- from src/tier2/executor/matcher.zig ---

test "Matcher: matchFull success" {
    const compiler = zregex.internal;

    const compiled = try compiler.compileSimple(std.testing.allocator, "hello");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.matchFull("hello");

    try std.testing.expect(result);
}

test "Matcher: CHAR_SET without its CharSet table is InvalidCharSet, not a panic" {
    const compiler = zregex.internal;
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
    const compiler = zregex.internal;

    const compiled = try compiler.compileSimple(std.testing.allocator, "hello");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.matchFull("world");

    try std.testing.expect(!result);
}

test "Matcher: find match" {
    const compiler = zregex.internal;

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
    const compiler = zregex.internal;

    const compiled = try compiler.compileSimple(std.testing.allocator, "xyz");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    const result = try matcher.find("hello world");

    try std.testing.expect(result == null);
}

test "Matcher: find with capture" {
    const compiler = zregex.internal;

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
    const compiler = zregex.internal;

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
    const compiler = zregex.internal;

    const compiled = try compiler.compileSimple(std.testing.allocator, "x");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);
    var matches = try matcher.findAll("hello", false);
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "Matcher: test_ function" {
    const compiler = zregex.internal;

    const compiled = try compiler.compileSimple(std.testing.allocator, "test");
    defer compiled.deinit();

    const matcher = Matcher.init(std.testing.allocator, compiled.bytecode);

    try std.testing.expect(try matcher.test_("test"));
    try std.testing.expect(!try matcher.test_("fail"));
}

// --- from src/tier2/executor/recursive_matcher.zig (on the explicit-stack
// backtracker since B′, which retired the recursive matcher) ---

/// One run of the backtracker anchored at `pos` (`Matcher.exec`, sticky):
/// the match's end, or null; the group slots in `slots[2..]`.
fn runAt(comptime Unit: type, compiled: zregex.internal.CompileResult, input: []const Unit, pos: usize, slots: []?usize, limits: zregex.ExecLimits) !?usize {
    const m = Matcher.initCompiled(std.testing.allocator, compiled);
    var scratch = zregex.internal.tier2.matcher.Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    if (!try m.exec(Unit, input, pos, true, &scratch, slots, limits)) return null;
    return slots[1].?;
}

test "backtracker: question quantifier" {
    const result = try zregex.internal.compileSimple(std.testing.allocator, "a?");
    defer result.deinit();
    var slots: [2]?usize = undefined;
    try std.testing.expectEqual(@as(?usize, 0), try runAt(u8, result, "", 0, &slots, .{}));
    try std.testing.expectEqual(@as(?usize, 1), try runAt(u8, result, "a", 0, &slots, .{}));
}

test "backtracker: simple star quantifier" {
    const result = try zregex.internal.compileSimple(std.testing.allocator, "a*");
    defer result.deinit();
    var slots: [2]?usize = undefined;
    try std.testing.expectEqual(@as(?usize, 0), try runAt(u8, result, "", 0, &slots, .{}));
    try std.testing.expectEqual(@as(?usize, 3), try runAt(u8, result, "aaa", 0, &slots, .{}));
}

test "backtracker: ReDoS protection - step limit" {
    // (a+)+b over 20 'a' and no 'b': exponential, stopped by the default
    // step budget.
    const result = try zregex.internal.compileSimple(std.testing.allocator, "(a+)+b");
    defer result.deinit();
    var slots: [4]?usize = undefined;
    try std.testing.expectError(error.StepLimitExceeded, runAt(u8, result, "aaaaaaaaaaaaaaaaaaaaX", 0, &slots, .{}));
}

test "backtracker: quantified backreference to an empty capture doesn't crash" {
    // A real crash found via test262-derived conformance testing (see
    // docs/ECMASCRIPT_COMPATIBILITY_PLAN.md Phase 6): `\1+` where group 1
    // can capture zero characters. Matches "b": group 1 captures "", \1+
    // matches it once and stops (test262's S15.10.2.9_A1_T5.js expects
    // ["b", ""]).
    const result = try zregex.internal.compileSimple(std.testing.allocator, "(a*)b\\1+");
    defer result.deinit();
    var slots: [4]?usize = undefined;
    try std.testing.expectEqual(@as(?usize, 1), try runAt(u8, result, "baaac", 0, &slots, .{}));
}

test "backtracker: 1000 groups capture exactly, and \\1000 matches (D9)" {
    // The capture storage (heap slots, u16 indices); no native stack in the
    // way since F6a.
    const gpa = std.testing.allocator;
    var pattern: std.ArrayListUnmanaged(u8) = .empty;
    defer pattern.deinit(gpa);
    for (0..1000) |_| try pattern.appendSlice(gpa, "(.)");
    try pattern.appendSlice(gpa, "\\1000");
    var input: [1001]u8 = undefined;
    for (input[0..1000], 0..) |*c, i| c.* = @intCast('!' + (i % 94));
    input[1000] = input[999];
    const compiled = try zregex.internal.compileSimple(gpa, pattern.items);
    defer compiled.deinit();
    const slots = try gpa.alloc(?usize, 2 * 1001);
    defer gpa.free(slots);
    try std.testing.expectEqual(@as(?usize, 1001), try runAt(u8, compiled, &input, 0, slots, .{ .max_steps = 0 }));
    for (1..1001) |g| {
        try std.testing.expectEqual(@as(?usize, g - 1), slots[2 * g]);
        try std.testing.expectEqual(@as(?usize, g), slots[2 * g + 1]);
    }
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
    const root = try lower.lower(arena.allocator(), ast_root, flags, &.{}, .{});

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

test "CodeGenerator: every iteration of a quantified group clears its captures, a? and a{0,1} alike (F7a(4))" {
    // RepeatMatcher step 4: `?` and `{0,1}` are the same quantifier. Before
    // F7a(4) only `?`/`??` cleared (on skip), a codegen artifact.
    var q = try testProgram("(a)?", .{});
    defer q.deinit();
    var c = try testProgram("(a){0,1}", .{});
    defer c.deinit();
    var n = try testProgram("a{0,1}", .{});
    defer n.deinit();
    try std.testing.expect(try hasOpcode(q.code, .CLEAR_CAPTURE));
    try std.testing.expect(try hasOpcode(c.code, .CLEAR_CAPTURE));
    try std.testing.expect(!try hasOpcode(n.code, .CLEAR_CAPTURE));
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

// --- F3c: the matcher over UTF-16 ---

test "backtracker: the u16 instance matches like the u8 one (code points, F3c)" {
    const a = std.testing.allocator;
    const subject = zregex.internal.subject;
    const patterns = [_][]const u8{ "a", "\\u00e9+", ".", "(.)(.)", "[^a]+", "[\\u00e0-\\u00ff]", "\\p{L}+", "\\bx\\b", "(\\w)\\1", "(?<=.)x", "(?<!\\u00e9)x", "^.$", "\\u{1F600}", "[\\u{1F600}a]" };
    const subjects = [_][]const u8{ "", "a", "\u{E9}\u{E9}x", "ax\u{E9}x", "\u{1F600}", "x\u{1F600}x", "\xED\xA0\x80x", "\u{2028}a\nb", "aa bb \u{E9}\u{E9}" };
    for (patterns) |p| {
        const c = try zregex.internal.compile(a, p, .{ .unicode = true });
        defer c.deinit();
        const n = 2 * (@as(usize, c.group_count) + 1);
        var s8slots: [8]?usize = undefined;
        var s16slots: [8]?usize = undefined;
        for (subjects) |s8| {
            const s16 = try subject.utf16FromWtf8(a, s8);
            defer a.free(s16);
            var p16: usize = 0;
            while (p16 <= s16.len) : (p16 += 1) {
                const p8 = try subject.utf16ToWtf8Index(s8, p16);
                // Only positions both encodings share outside a pair.
                if (p16 > 0 and p16 < s16.len and s16[p16] >= 0xDC00 and s16[p16] <= 0xDFFF and s16[p16 - 1] >= 0xD800 and s16[p16 - 1] <= 0xDBFF) continue;
                const r8 = try runAt(u8, c, s8, p8, s8slots[0..n], .{});
                const r16 = try runAt(u16, c, s16, p16, s16slots[0..n], .{});
                try std.testing.expectEqual(r8 == null, r16 == null);
                if (r8 == null) continue;
                for (s8slots[0..n], s16slots[0..n]) |g8, g16| {
                    try std.testing.expectEqual(g8 == null, g16 == null);
                    if (g8) |v| try std.testing.expectEqual(try subject.wtf8ToUtf16Index(s8, v), g16.?);
                }
            }
        }
    }
}
