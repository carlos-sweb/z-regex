//! z-regex harness of the cross-engine benchmark (docs/BENCHMARKS.md).
//!
//!   zig build xbench -- CORPUS_DIR              every z-regex case, JSON on stdout
//!   zregex_xbench CORPUS_DIR --adv ID N         one adversarial run ('a' x N + the case's adv_suffix)
//!
//! Per case: findAll MB/s (`Regex.findAll`, the allocating facade), execAt
//! MB/s (a loop of `execAt` + `advanceIndex` with a warm `Scratch`: 0
//! allocations), ns per `execAt` on the case's short input, µs per compile
//! and the bytes the compiled `Regex` keeps (live allocations after
//! `compileWithOptions`). Throughput: one warm-up pass, then the median of up
//! to 5 timed passes (5 s budget).

const std = @import("std");
const zregex = @import("zregex");
const Allocator = std.mem.Allocator;

const Case = struct {
    id: []const u8,
    tier: []const u8,
    pattern: []const u8,
    flags: []const u8 = "",
    corpus: []const u8 = "",
    short: []const u8 = "",
    engines: []const []const u8,
    zregex: []const u8 = "routed",
    adversarial: ?[]const u32 = null,
    adv_suffix: []const u8 = "c",
};

/// Tracks live bytes (the compiled program's footprint).
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
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Tracking = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, a, new_len, ra)) return false;
        self.live = self.live - m.len + new_len;
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Tracking = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(m, a, new_len, ra) orelse return null;
        self.live = self.live - m.len + new_len;
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Tracking = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.live -= m.len;
    }
};

fn has(s: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, s, c) != null;
}

fn options(c: Case) zregex.CompileOptions {
    var o: zregex.CompileOptions = .{
        .case_insensitive = has(c.flags, 'i'),
        .multiline = has(c.flags, 'm'),
        .dot_all = has(c.flags, 's'),
        .unicode = has(c.flags, 'u'),
        .v = has(c.flags, 'v'),
    };
    if (std.mem.eql(u8, c.zregex, "vm_plain")) o.t0_prefilters = false;
    if (std.mem.eql(u8, c.zregex, "backtracker")) o.force_tier = .expert;
    return o;
}

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

fn engineName(re: zregex.Regex) []const u8 {
    const p = re.t0 orelse return "backtracker";
    const tagged = p.nslots > 2 or for (p.insts) |inst| {
        if (inst == .fail) break true;
    } else false;
    return if (tagged) "tagged VM" else "VM";
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

const FindAllCtx = struct { re: *const zregex.Regex, input: []const u8, gpa: Allocator };
fn findAllPass(c: FindAllCtx) anyerror!usize {
    var list = try c.re.findAll(c.input);
    const n = list.items.len;
    for (list.items) |m| m.deinit();
    list.deinit(c.re.allocator);
    return n;
}

const ExecCtx = struct { re: *const zregex.Regex, input: []const u8, scratch: *zregex.Scratch };
fn execPass(c: ExecCtx) anyerror!usize {
    var buf: [64]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = buf[0..c.re.slotCount()] };
    const s: zregex.Subject = .{ .wtf8 = c.input };
    var n: usize = 0;
    var i: usize = 0;
    while (i <= c.input.len) {
        if (!try c.re.execAt(s, i, c.scratch, &out, .{})) break;
        n += 1;
        const start = buf[0].?;
        const end = buf[1].?;
        i = if (end == start) c.re.advanceIndex(s, end) else end;
    }
    return n;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const corpus_dir = args.next() orelse return error.Usage;
    const mode = args.next();

    const cases_src = try std.Io.Dir.cwd().readFileAlloc(io, "bench/compare/cases.json", gpa, .limited(1 << 20));
    const parsed = try std.json.parseFromSlice(struct { comment: []const u8 = "", cases: []Case }, gpa, cases_src, .{ .ignore_unknown_fields = true });
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
        var re = try zregex.Regex.compileWithOptions(gpa, c.pattern, options(c));
        defer re.deinit();
        var scratch = zregex.Scratch.init(gpa);
        defer scratch.deinit();
        var buf: [64]?usize = undefined;
        var slots: zregex.MatchSlots = .{ .slots = buf[0..re.slotCount()] };
        const t0 = now(io);
        const r = re.execAt(.{ .wtf8 = input }, 0, &scratch, &slots, .{});
        const ms = @as(f64, @floatFromInt(now(io) - t0)) / 1e6;
        const outcome: []const u8 = if (r) |found| (if (found) "match" else "no match") else |err| @errorName(err);
        try w.print("{{\"engine\":\"zregex\",\"id\":\"{s}\",\"n\":{d},\"ms\":{d:.4},\"outcome\":\"{s}\",\"route\":\"{s}\"}}\n", .{ id, n, ms, outcome, engineName(re) });
        try std.Io.File.stdout().writeStreamingAll(io, out.written());
        return;
    };

    try w.print("{{\"engine\":\"zregex\",\"version\":\"{s}\",\"cases\":[", .{zregex.version});
    var first = true;
    for (cases) |c| {
        const mine = for (c.engines) |e| {
            if (std.mem.eql(u8, e, "zregex")) break true;
        } else false;
        if (!mine or c.adversarial != null) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ corpus_dir, c.corpus });
        const input = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
        defer gpa.free(input);
        const o = options(c);

        // Compile: µs (median of 21) and the live bytes of the result.
        var cs: [21]i96 = undefined;
        for (&cs) |*slot| {
            const t0 = now(io);
            const r = try zregex.Regex.compileWithOptions(gpa, c.pattern, o);
            slot.* = now(io) - t0;
            r.deinit();
        }
        std.mem.sort(i96, &cs, {}, std.sort.asc(i96));
        var tracking: Tracking = .{ .child = gpa };
        const measured = try zregex.Regex.compileWithOptions(tracking.allocator(), c.pattern, o);
        const bytes = tracking.live;
        measured.deinit();

        var re = try zregex.Regex.compileWithOptions(gpa, c.pattern, o);
        defer re.deinit();
        var scratch = zregex.Scratch.init(gpa);
        defer scratch.deinit();
        const fa = try timed(io, input.len, FindAllCtx{ .re = &re, .input = input, .gpa = gpa }, findAllPass);
        const ex = try timed(io, input.len, ExecCtx{ .re = &re, .input = input, .scratch = &scratch }, execPass);

        // Short input: ns per execAt from 0 (search), warm scratch.
        var buf: [64]?usize = undefined;
        var slots: zregex.MatchSlots = .{ .slots = buf[0..re.slotCount()] };
        const s: zregex.Subject = .{ .wtf8 = c.short };
        for (0..10000) |_| _ = try re.execAt(s, 0, &scratch, &slots, .{});
        var samples: [11]f64 = undefined;
        const iters: usize = 100000;
        for (&samples) |*slot| {
            const t0 = now(io);
            for (0..iters) |_| std.mem.doNotOptimizeAway(try re.execAt(s, 0, &scratch, &slots, .{}));
            slot.* = @as(f64, @floatFromInt(now(io) - t0)) / @as(f64, @floatFromInt(iters));
        }
        std.mem.sort(f64, &samples, {}, std.sort.asc(f64));

        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"id\":\"{s}\",\"route\":\"{s}\",\"findall_mbps\":{d:.3},\"execat_mbps\":{d:.3},\"matches\":{d},\"exec_matches\":{d},\"short_ns\":{d:.2},\"compile_us\":{d:.3},\"bytes\":{d}}}", .{
            c.id, engineName(re), fa.mbps, ex.mbps, fa.matches, ex.matches, samples[5], @as(f64, @floatFromInt(cs[10])) / 1e3, bytes,
        });
    }
    try w.writeAll("]}\n");
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
}
