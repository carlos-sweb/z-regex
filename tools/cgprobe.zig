//! E1 P3: fixed work per case for callgrind (forward path). `cgprobe N`.
const std = @import("std");
const zregex = @import("zregex");

const Case = struct { name: []const u8, pattern: []const u8, opts: zregex.CompileOptions, unit: []const u8 };
const expert: zregex.CompileOptions = .{ .force_tier = .expert };
const cases = [_]Case{
    .{ .name = "literal hello", .pattern = "hello", .opts = expert, .unit = "the quick brown fox says hello over the lazy dog. " },
    .{ .name = "[a-z]+", .pattern = "[a-z]+", .opts = expert, .unit = "the quick brown fox says hello over the lazy dog. " },
    .{ .name = "\\d{3}-\\d{4} sparse", .pattern = "\\d{3}-\\d{4}", .opts = expert, .unit = "call tel 555-1234 or write some words here then " },
    .{ .name = "\\d{3}-\\d{4} dense", .pattern = "\\d{3}-\\d{4}", .opts = expert, .unit = "0123456789-0123456789" },
    .{ .name = "email", .pattern = "[\\w.+-]+@[\\w-]+\\.[\\w.]+", .opts = expert, .unit = "mail joe@site.com, ann.b@x.org; nothing here " },
    .{ .name = "\\p{L}+ /u mixed", .pattern = "\\p{L}+", .opts = .{ .force_tier = .expert, .unicode = true }, .unit = "abc \u{3a9}\u{3bc}\u{3ad}\u{3b3}\u{3b1} Stra\u{df}e \u{1F600} 42 " },
    .{ .name = "\\p{L}+ /u ascii", .pattern = "\\p{L}+", .opts = .{ .force_tier = .expert, .unicode = true }, .unit = "the quick brown fox says hello over the lazy dog. " },
    .{ .name = "[\\p{L}--\\p{Lu}] /v", .pattern = "[\\p{L}--\\p{Lu}]", .opts = .{ .force_tier = .expert, .v = true }, .unit = "abc \u{3a9}\u{3bc}\u{3ad}\u{3b3}\u{3b1} Stra\u{df}e \u{1F600} 42 " },
    .{ .name = "<(\\w+)>.*?<\\/\\1>", .pattern = "<(\\w+)>.*?<\\/\\1>", .opts = .{}, .unit = "<b>bold</b> text <i>it</i> and <p>x" },
    .{ .name = "(?<=\\$)\\d+", .pattern = "(?<=\\$)\\d+", .opts = .{}, .unit = "cost $450 and $12 or 7 dollars " },
    .{ .name = "(\\d{3})-(\\d{4}) sparse", .pattern = "(\\d{3})-(\\d{4})", .opts = expert, .unit = "call tel 555-1234 or write some words here then " },
    .{ .name = "(\\d{3})-(\\d{4}) dense", .pattern = "(\\d{3})-(\\d{4})", .opts = expert, .unit = "0123456789-0123456789" },
    .{ .name = "(\\w+)@(\\w+)\\.com", .pattern = "(\\w+)@(\\w+)\\.com", .opts = expert, .unit = "mail joe@site.com, ann@x.org; nothing here " },
    .{ .name = "(?:(a)|b)*c", .pattern = "(?:(a)|b)*c", .opts = expert, .unit = "ababbabc aab c bbbbbbac " },
    .{ .name = "(a+)+b adversarial", .pattern = "(a+)+b", .opts = expert, .unit = "aaaaaaaaaaaaaaaaaac " },
    .{ .name = "(a|aa)*c adversarial", .pattern = "(a|aa)*c", .opts = expert, .unit = "aaaaaaaaaaaaaaaaaab " },
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const which = try std.fmt.parseInt(usize, args.next().?, 10);
    const c = cases[which];
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(gpa);
    const target: usize = if (std.mem.indexOf(u8, c.name, "adversarial") != null) 200 else 32 * 1024;
    while (input.items.len < target) try input.appendSlice(gpa, c.unit);
    var re = try zregex.Regex.compileWithOptions(gpa, c.pattern, c.opts);
    defer re.deinit();
    var scratch = zregex.Scratch.init(gpa);
    defer scratch.deinit();
    const slots = try gpa.alloc(?usize, re.slotCount());
    defer gpa.free(slots);
    var out: zregex.MatchSlots = .{ .slots = slots };
    var matches: usize = 0;
    for (0..3) |_| {
        var it = re.iterator(.{ .wtf8 = input.items }, &scratch, &out, .{});
        while (it.next() catch null) |_| matches += 1;
    }
    std.debug.print("{s}: {d}\n", .{ c.name, matches });
}
