//! zig-utils/zig-regex harness of z-regex's cross-engine benchmark
//! (docs/BENCHMARKS.md). Built by setup_zigregex.sh against v0.1.1 (the last
//! release that builds with Zig 0.16).
//!
//!   zigregex_xbench CORPUS_DIR CASES_JSON [ID]
//!
//! With ID, only that case. With --no-findall instead of an ID, every case
//! without the findAll pass: zig-regex's findAll restarts its VM at every
//! start position (quadratic: a 1 MiB pass takes on the order of an hour),
//! so the runner measures its growth on prefixes apart (scaling mode).
//!
//! T0 cases only. zig-regex has no search-from-an-index API, so there is no
//! "execAt" column: findAll (`Regex.findAll`, allocating) is its throughput.
//! short: ns per `find` on the short input; compile: µs per `compile`;
//! bytes: live allocations of the compiled `Regex`.

const std = @import("std");
const zr = @import("regex");
const Allocator = std.mem.Allocator;

const Case = struct {
    id: []const u8,
    tier: []const u8,
    pattern: []const u8,
    corpus: []const u8 = "",
    short: []const u8 = "",
    engines: []const []const u8,
    adversarial: ?[]const u32 = null,
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

fn findAllPass(gpa: Allocator, re: *const zr.Regex, input: []const u8) !usize {
    const ms = try re.findAll(gpa, input);
    const n = ms.len;
    for (ms) |*m| @constCast(m).deinit(gpa);
    gpa.free(ms);
    return n;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const corpus_dir = args.next() orelse return error.Usage;
    const cases_path = args.next() orelse return error.Usage;
    var only = args.next();
    const no_findall = if (only) |o| std.mem.eql(u8, o, "--no-findall") else false;
    if (no_findall) only = null;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, cases_path, gpa, .limited(1 << 20));
    const parsed = try std.json.parseFromSlice(struct { comment: []const u8 = "", cases: []Case }, gpa, src, .{ .ignore_unknown_fields = true });

    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try w.writeAll("{\"engine\":\"zigregex\",\"version\":\"0.1.1\",\"cases\":[");
    var first = true;
    for (parsed.value.cases) |c| {
        const mine = for (c.engines) |e| {
            if (std.mem.eql(u8, e, "zigregex")) break true;
        } else false;
        if (!mine or c.adversarial != null) continue;
        if (only) |o| if (!std.mem.eql(u8, o, c.id)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ corpus_dir, c.corpus });
        const input = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
        defer gpa.free(input);
        var re = zr.Regex.compile(gpa, c.pattern) catch |err| {
            try w.print("{{\"id\":\"{s}\",\"error\":\"compile: {s}\"}}", .{ c.id, @errorName(err) });
            continue;
        };
        defer re.deinit();

        var cs: [21]i96 = undefined;
        for (&cs) |*slot| {
            const t0 = now(io);
            var r = try zr.Regex.compile(gpa, c.pattern);
            slot.* = now(io) - t0;
            r.deinit();
        }
        std.mem.sort(i96, &cs, {}, std.sort.asc(i96));
        var tracking: Tracking = .{ .child = gpa };
        var measured = try zr.Regex.compile(tracking.allocator(), c.pattern);
        const bytes = tracking.live;
        measured.deinit();

        // findAll: warm-up, then up to 5 timed passes within 5 s; a
        // warm-up over 20 s is the only sample.
        if (no_findall) {
            var samples0: [11]f64 = undefined;
            for (&samples0) |*slot| {
                const t0 = now(io);
                for (0..20000) |_| {
                    if (try re.find(c.short)) |m| {
                        var mm = m;
                        mm.deinit(gpa);
                    }
                }
                slot.* = @as(f64, @floatFromInt(now(io) - t0)) / 20000.0;
            }
            std.mem.sort(f64, &samples0, {}, std.sort.asc(f64));
            try w.print("{{\"id\":\"{s}\",\"short_ns\":{d:.2},\"compile_us\":{d:.3},\"bytes\":{d}}}", .{ c.id, samples0[5], @as(f64, @floatFromInt(cs[10])) / 1e3, bytes });
            continue;
        }
        const tw = now(io);
        var matches = findAllPass(gpa, &re, input) catch |err| {
            try w.print("{{\"id\":\"{s}\",\"error\":\"findAll: {s}\"}}", .{ c.id, @errorName(err) });
            continue;
        };
        const warm = now(io) - tw;
        var times: [5]i96 = undefined;
        var n: usize = 0;
        if (warm > 20 * std.time.ns_per_s) {
            times[0] = warm;
            n = 1;
        } else {
            var spent: i96 = 0;
            while (n < 5) {
                const t0 = now(io);
                matches = try findAllPass(gpa, &re, input);
                times[n] = now(io) - t0;
                spent += times[n];
                n += 1;
                if (spent > 5 * std.time.ns_per_s) break;
            }
        }
        std.mem.sort(i96, times[0..n], {}, std.sort.asc(i96));
        const mbps = @as(f64, @floatFromInt(input.len)) / (1024.0 * 1024.0) / (@as(f64, @floatFromInt(times[n / 2])) / 1e9);

        var samples: [11]f64 = undefined;
        const iters: usize = 20000;
        for (&samples) |*slot| {
            const t0 = now(io);
            for (0..iters) |_| {
                if (try re.find(c.short)) |m| {
                    var mm = m;
                    mm.deinit(gpa);
                }
            }
            slot.* = @as(f64, @floatFromInt(now(io) - t0)) / @as(f64, @floatFromInt(iters));
        }
        std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
        try w.print("{{\"id\":\"{s}\",\"findall_mbps\":{d:.3},\"matches\":{d},\"short_ns\":{d:.2},\"compile_us\":{d:.3},\"bytes\":{d}}}", .{ c.id, mbps, matches, samples[5], @as(f64, @floatFromInt(cs[10])) / 1e3, bytes });
    }
    try w.writeAll("]}\n");
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
}
