//! zoptia/zoptia0regex harness of z-regex's cross-engine benchmark
//! (docs/BENCHMARKS.md): a Zig port of Go's regexp (RE2 syntax, no
//! backreferences or lookaround). Built by setup_zoptia.sh at a pinned commit.
//!
//!   zoptia_xbench CORPUS_DIR CASES_JSON             every case with "zoptia"
//!   zoptia_xbench CORPUS_DIR CASES_JSON --adv ID N  one adversarial run
//!
//! The pattern is the case's `zoptia_pattern` when it has one (the same
//! language in RE2 syntax: `\p{Greek}` for `\p{Script=Greek}`, ...), else
//! `pattern`. zoptia0regex has no search from an index: its "execAt" is the
//! `matchesScratch` iterator over the whole input (every match, its groups
//! filled, a warm `Scratch`, no allocation). findAll: `findAllIndex`
//! (allocating, bounds only). short: ns per `findIndexScratch`, warm scratch.
//! compile: µs per `compile` (median of 21); bytes: live allocations of the
//! compiled `Regexp`.

const std = @import("std");
const zr = @import("regex");
const Allocator = std.mem.Allocator;

pub const commit = "8e8f2256e475ff62902586346640876871768a5d";

const Case = struct {
    id: []const u8,
    tier: []const u8,
    pattern: []const u8,
    zoptia_pattern: ?[]const u8 = null,
    corpus: []const u8 = "",
    short: []const u8 = "",
    engines: []const []const u8,
    adversarial: ?[]const u32 = null,
    adv_suffix: []const u8 = "c",

    fn expr(c: Case) []const u8 {
        return c.zoptia_pattern orelse c.pattern;
    }
};

const Tracking = struct {
    child: Allocator,
    live: usize = 0,
    fn allocator(self: *Tracking) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Tracking = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.live += len;
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Tracking = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, a, n, ra)) return false;
        self.live = self.live - m.len + n;
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Tracking = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(m, a, n, ra) orelse return null;
        self.live = self.live - m.len + n;
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Tracking = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.live -= m.len;
    }
};

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

const Timed = struct { mbps: f64, matches: usize };

/// One warm-up pass, then the median of up to 5 (5 s budget).
fn timed(io: std.Io, bytes: usize, ctx: anytype, comptime pass: fn (@TypeOf(ctx)) anyerror!usize) !Timed {
    var matches = try pass(ctx);
    var times: [5]i96 = undefined;
    var n: usize = 0;
    var spent: i96 = 0;
    while (n < 5) {
        const t0 = now(io);
        matches = try pass(ctx);
        const dt = now(io) - t0;
        times[n] = dt;
        n += 1;
        spent += dt;
        if (spent > 5 * std.time.ns_per_s) break;
    }
    std.mem.sort(i96, times[0..n], {}, std.sort.asc(i96));
    const secs = @as(f64, @floatFromInt(times[n / 2])) / 1e9;
    return .{ .mbps = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0) / secs, .matches = matches };
}

const FindAllCtx = struct { re: *const zr.Regexp, input: []const u8, gpa: Allocator };
fn findAllPass(c: FindAllCtx) anyerror!usize {
    const ms = (try c.re.findAllIndex(c.gpa, c.input, -1)) orelse return 0;
    defer c.gpa.free(ms);
    return ms.len;
}

const ExecCtx = struct { re: *const zr.Regexp, input: []const u8, scratch: *zr.Scratch };
fn execPass(c: ExecCtx) anyerror!usize {
    var it = try c.re.matchesScratch(c.scratch, c.input, -1);
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const corpus_dir = args.next() orelse return error.Usage;
    const cases_path = args.next() orelse return error.Usage;
    const mode = args.next();

    const src = try std.Io.Dir.cwd().readFileAlloc(io, cases_path, gpa, .limited(1 << 20));
    const parsed = try std.json.parseFromSlice(struct { comment: []const u8 = "", cases: []Case }, gpa, src, .{ .ignore_unknown_fields = true });
    const cases = parsed.value.cases;

    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;

    if (mode) |m| if (std.mem.eql(u8, m, "--adv")) {
        const id = args.next().?;
        const n = try std.fmt.parseInt(usize, args.next().?, 10);
        const c = for (cases) |c| {
            if (std.mem.eql(u8, c.id, id)) break c;
        } else return error.NoSuchCase;
        const input = try gpa.alloc(u8, n + c.adv_suffix.len);
        @memset(input[0..n], 'a');
        @memcpy(input[n..], c.adv_suffix);
        var re = try zr.compile(gpa, c.expr());
        defer re.deinit();
        var scratch = zr.Scratch.init(gpa);
        defer scratch.deinit();
        const t0 = now(io);
        const r = re.findIndexScratch(&scratch, input);
        const ms = @as(f64, @floatFromInt(now(io) - t0)) / 1e6;
        const outcome: []const u8 = if (r) |found| (if (found != null) "match" else "no match") else |err| @errorName(err);
        try w.print("{{\"engine\":\"zoptia\",\"id\":\"{s}\",\"n\":{d},\"ms\":{d:.4},\"outcome\":\"{s}\"}}\n", .{ id, n, ms, outcome });
        try std.Io.File.stdout().writeStreamingAll(io, out.written());
        return;
    };

    try w.print("{{\"engine\":\"zoptia\",\"version\":\"{s}\",\"cases\":[", .{commit[0..7]});
    var first = true;
    for (cases) |c| {
        const mine = for (c.engines) |e| {
            if (std.mem.eql(u8, e, "zoptia")) break true;
        } else false;
        if (!mine or c.adversarial != null) continue;
        if (!first) try w.writeAll(",");
        first = false;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ corpus_dir, c.corpus });
        const input = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
        defer gpa.free(input);

        var re = zr.compile(gpa, c.expr()) catch |err| {
            try w.print("{{\"id\":\"{s}\",\"error\":\"compile: {s}\"}}", .{ c.id, @errorName(err) });
            continue;
        };
        defer re.deinit();

        // Compile: µs (median of 21) and the live bytes of the result.
        var cs: [21]i96 = undefined;
        for (&cs) |*slot| {
            const t0 = now(io);
            var r = try zr.compile(gpa, c.expr());
            slot.* = now(io) - t0;
            r.deinit();
        }
        std.mem.sort(i96, &cs, {}, std.sort.asc(i96));
        var tracking: Tracking = .{ .child = gpa };
        var measured = try zr.compile(tracking.allocator(), c.expr());
        const bytes = tracking.live;
        measured.deinit();

        var scratch = zr.Scratch.init(gpa);
        defer scratch.deinit();
        const fa = try timed(io, input.len, FindAllCtx{ .re = &re, .input = input, .gpa = gpa }, findAllPass);
        const ex = try timed(io, input.len, ExecCtx{ .re = &re, .input = input, .scratch = &scratch }, execPass);
        if (ex.matches != fa.matches) return error.IteratorCountMismatch;

        // Short input: ns per search from 0, warm scratch.
        for (0..10000) |_| _ = try re.findIndexScratch(&scratch, c.short);
        var samples: [11]f64 = undefined;
        const iters: usize = 100000;
        for (&samples) |*slot| {
            const t0 = now(io);
            for (0..iters) |_| std.mem.doNotOptimizeAway(try re.findIndexScratch(&scratch, c.short));
            slot.* = @as(f64, @floatFromInt(now(io) - t0)) / @as(f64, @floatFromInt(iters));
        }
        std.mem.sort(f64, &samples, {}, std.sort.asc(f64));

        try w.print("{{\"id\":\"{s}\",\"findall_mbps\":{d:.3},\"execat_mbps\":{d:.3},\"matches\":{d},\"short_ns\":{d:.2},\"compile_us\":{d:.3},\"bytes\":{d}}}", .{
            c.id, fa.mbps, ex.mbps, fa.matches, samples[5], @as(f64, @floatFromInt(cs[10])) / 1e3, bytes,
        });
    }
    try w.writeAll("]}\n");
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
}
