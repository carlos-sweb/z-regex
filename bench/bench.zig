//! Performance baseline of the current engine (docs/REGEX_TIERS_PLAN.md,
//! phase F0d, cases of §7.2). Run with `zig build bench` (always
//! ReleaseFast).
//!
//! Throughput cases run `Regex.findAll` over a deterministic 1 MiB input
//! (fixed-seed generator) and report the median of up to 5 timed runs after
//! one warm-up (fewer when a case needs more than ~20 s in total, noted in
//! the output). Adversarial cases run `find` once on a 41-byte input and
//! report the time until the engine gives up; a watchdog aborts the process
//! if any single measurement exceeds 30 s of wall time.
//!
//! Since F4a each throughput case is also run as a host runs it: a loop of
//! `execAt` + `advanceIndex` with a warm `Scratch` (no allocation), on the
//! executor the dispatcher picks, on T0's VM without prefilters
//! (`t0_prefilters = false`) and on the backtracker (`force_tier =
//! .expert`); §7.2's T0 targets are read in that table. Short overhead
//! cases (`/abc/` on 5 B and on 2 KB) give ns per `execAt` for each
//! executor, and compile cases give the dispatcher's compile time against
//! the backtracker's alone.
//!
//! Output: Markdown tables on stdout and JSON at the path given as the
//! first argument (default zig-out/bench/results.json).

const std = @import("std");
const zregex = @import("zregex");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const INPUT_SIZE: usize = 1 << 20;
const MAX_RUNS: usize = 5;
const RUN_BUDGET_NS: i96 = 20 * std.time.ns_per_s;
const WATCHDOG_NS: i96 = 30 * std.time.ns_per_s;

/// Counts allocations made through it.
const CountingAllocator = struct {
    child: Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }
};

// ------------------------------------------------------------------ inputs

const Gen = struct {
    rng: std.Random.DefaultPrng,
    out: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    fn init(gpa: Allocator, seed: u64) Gen {
        return .{ .rng = .init(seed), .gpa = gpa };
    }
    fn r(self: *Gen) std.Random {
        return self.rng.random();
    }
    fn put(self: *Gen, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }
    fn word(self: *Gen) !void {
        const n = 2 + self.r().uintLessThan(usize, 8);
        for (0..n) |_| try self.out.append(self.gpa, 'a' + self.r().uintLessThan(u8, 26));
    }
    fn digits(self: *Gen, n: usize) !void {
        for (0..n) |_| try self.out.append(self.gpa, '0' + self.r().uintLessThan(u8, 10));
    }
    fn done(self: *Gen) ![]u8 {
        self.out.shrinkRetainingCapacity(@min(self.out.items.len, INPUT_SIZE));
        return self.out.toOwnedSlice(self.gpa);
    }
};

const InputKind = enum { prose, prose_hello, phones_sparse, digits_dense, emails, unicode_mixed, unicode_ascii, html, prices, ab_runs };

fn makeInput(gpa: Allocator, kind: InputKind) ![]u8 {
    var g = Gen.init(gpa, 0x5eed_0000 + @as(u64, @intFromEnum(kind)));
    const greek = [_][]const u8{ "λόγος", "αλφα", "Ωμέγα", "κόσμε" };
    const cyr = [_][]const u8{ "привет", "Москва", "слово" };
    const cjk = [_][]const u8{ "漢字", "日本語", "中文" };
    while (g.out.items.len < INPUT_SIZE) {
        switch (kind) {
            .prose => {
                try g.word();
                try g.put(if (g.r().uintLessThan(u8, 10) == 0) ". " else " ");
            },
            .prose_hello => {
                if (g.r().uintLessThan(u16, 1500) == 0) try g.put("hello") else try g.word();
                try g.put(" ");
            },
            .phones_sparse => {
                if (g.r().uintLessThan(u8, 30) == 0) {
                    try g.digits(3);
                    try g.put("-");
                    try g.digits(4);
                } else try g.word();
                try g.put(" ");
            },
            .digits_dense => {
                try g.digits(1 + g.r().uintLessThan(usize, 6));
                try g.put(if (g.r().boolean()) "-" else " ");
            },
            .emails => {
                if (g.r().uintLessThan(u8, 20) == 0) {
                    try g.word();
                    try g.put(".");
                    try g.word();
                    try g.put("@");
                    try g.word();
                    try g.put(".com");
                } else try g.word();
                try g.put(" ");
            },
            .unicode_mixed, .unicode_ascii => {
                const non_ascii = if (kind == .unicode_mixed) g.r().uintLessThan(u8, 2) == 0 else g.r().uintLessThan(u8, 20) == 0;
                if (non_ascii) {
                    const pick = g.r().uintLessThan(u8, 3);
                    const list: []const []const u8 = if (pick == 0) &greek else if (pick == 1) &cyr else &cjk;
                    try g.put(list[g.r().uintLessThan(usize, list.len)]);
                } else try g.word();
                try g.put(" ");
            },
            .html => {
                const tags = [_][]const u8{ "p", "b", "div", "span", "em" };
                const t = tags[g.r().uintLessThan(usize, tags.len)];
                try g.put("<");
                try g.put(t);
                try g.put(">");
                try g.word();
                try g.put(" ");
                try g.word();
                try g.put("</");
                try g.put(t);
                try g.put(">\n");
            },
            .ab_runs => {
                // F4b: runs of `a`/`b`, half of them closed by `c`
                // (for `(?:(a)|b)*c`).
                for (0..1 + g.r().uintLessThan(usize, 12)) |_| try g.put(if (g.r().boolean()) "a" else "b");
                try g.put(if (g.r().boolean()) "c " else " ");
            },
            .prices => {
                if (g.r().uintLessThan(u8, 15) == 0) {
                    try g.put("$");
                    try g.digits(1 + g.r().uintLessThan(usize, 4));
                } else try g.word();
                try g.put(" ");
            },
        }
    }
    // Keep the input valid UTF-8: trim back to the last ASCII byte boundary.
    var len = @min(g.out.items.len, INPUT_SIZE);
    while (len > 0 and g.out.items[len - 1] >= 0x80) len -= 1;
    g.out.shrinkRetainingCapacity(len);
    return g.out.toOwnedSlice(gpa);
}

// ------------------------------------------------------------------- cases

const Case = struct {
    name: []const u8,
    pattern: []const u8,
    options: zregex.CompileOptions = .{},
    input: InputKind,
    /// F4b: the same pattern without groups, for §7.2's target (with
    /// captures, >= 50% of its `execAt` throughput).
    no_groups: ?[]const u8 = null,
};

const throughput_cases = [_]Case{
    .{ .name = "literal hello", .pattern = "hello", .input = .prose_hello },
    .{ .name = "[a-z]+", .pattern = "[a-z]+", .input = .prose },
    .{ .name = "\\d{3}-\\d{4} (sparse)", .pattern = "\\d{3}-\\d{4}", .input = .phones_sparse },
    .{ .name = "\\d{3}-\\d{4} (dense)", .pattern = "\\d{3}-\\d{4}", .input = .digits_dense },
    .{ .name = "email", .pattern = "[\\w.+-]+@[\\w-]+\\.[\\w.]+", .input = .emails },
    .{ .name = "\\p{L}+ /u (mixed)", .pattern = "\\p{L}+", .options = .{ .unicode = true }, .input = .unicode_mixed },
    .{ .name = "\\p{L}+ /u (mostly ASCII)", .pattern = "\\p{L}+", .options = .{ .unicode = true }, .input = .unicode_ascii },
    .{ .name = "[\\p{L}--\\p{Lu}] /v", .pattern = "[\\p{L}--\\p{Lu}]", .options = .{ .v = true }, .input = .unicode_mixed },
    .{ .name = "<(\\w+)>.*?<\\/\\1>", .pattern = "<(\\w+)>.*?<\\/\\1>", .input = .html },
    .{ .name = "(?<=\\$)\\d+", .pattern = "(?<=\\$)\\d+", .input = .prices },
    // F4b: groups, on the tagged VM (appended: the rows above keep their
    // index for the comparison with earlier runs).
    .{ .name = "(\\d{3})-(\\d{4}) (sparse)", .pattern = "(\\d{3})-(\\d{4})", .input = .phones_sparse, .no_groups = "\\d{3}-\\d{4}" },
    .{ .name = "(\\d{3})-(\\d{4}) (dense)", .pattern = "(\\d{3})-(\\d{4})", .input = .digits_dense, .no_groups = "\\d{3}-\\d{4}" },
    .{ .name = "(\\w+)@(\\w+)\\.com", .pattern = "(\\w+)@(\\w+)\\.com", .input = .emails, .no_groups = "\\w+@\\w+\\.com" },
    .{ .name = "(?:(a)|b)*c", .pattern = "(?:(a)|b)*c", .input = .ab_runs, .no_groups = "(?:a|b)*c" },
};

// ------------------------------------------------------------- F4a cases

/// The executors an `execAt` case runs on.
const Engine = enum { routed, vm_plain, backtracker };

fn engineOptions(base: zregex.CompileOptions, e: Engine) zregex.CompileOptions {
    var o = base;
    switch (e) {
        .routed => {},
        .vm_plain => o.t0_prefilters = false,
        .backtracker => o.force_tier = .expert,
    }
    return o;
}

/// §7.2's overhead cases (reviewer closure 6): per `execAt`, short and long.
const overhead_cases = [_]struct { name: []const u8, pattern: []const u8, input: []const u8 }{
    .{ .name = "/abc/ on \"xabc\" (5 B)", .pattern = "abc", .input = "xabc" },
    .{ .name = "/abc/ on 2 KB", .pattern = "abc", .input = "x" ** 1000 ++ "abc" ++ "y" ** 1000 },
    .{ .name = "/\\d{3}-\\d{4}/ on \"tel 555-1234\"", .pattern = "\\d{3}-\\d{4}", .input = "tel 555-1234" },
    .{ .name = "/[a-z]+@[a-z]+/ on 2 KB", .pattern = "[a-z]+@[a-z]+", .input = "1 " ** 500 ++ "ab@cd" ++ " 2" ** 500 },
    // F4b: groups, on the tagged VM.
    .{ .name = "/(\\d{3})-(\\d{4})/ on \"tel 555-1234\"", .pattern = "(\\d{3})-(\\d{4})", .input = "tel 555-1234" },
    .{ .name = "/(\\w+)@(\\w+)\\.com/ on 2 KB", .pattern = "(\\w+)@(\\w+)\\.com", .input = "1 " ** 500 ++ "ab@cd.com" ++ " 2" ** 500 },
    .{ .name = "/(?:(a)|b)*c/ on \"ababc\"", .pattern = "(?:(a)|b)*c", .input = "ababc" },
};

/// Compile cost of the dispatcher (reviewer's F4a(4) closure): eligible
/// with the literal prefilter, eligible with `first`, and T0 but not
/// eligible (it decides eligibility and compiles no T0 program).
const compile_cases = [_]struct { name: []const u8, pattern: []const u8 }{
    .{ .name = "eligible, literal: hello", .pattern = "hello" },
    .{ .name = "eligible, first: \\d{3}-\\d{4}", .pattern = "\\d{3}-\\d{4}" },
    .{ .name = "tagged: (\\d{3})-(\\d{4})", .pattern = "(\\d{3})-(\\d{4})" },
    .{ .name = "tagged: (\\w+)@(\\w+)\\.com", .pattern = "(\\w+)@(\\w+)\\.com" },
    .{ .name = "tagged, product: (?:(a)|b)*c", .pattern = "(?:(a)|b)*c" },
    .{ .name = "eligible, first: email", .pattern = "[\\w.+-]+@[\\w-]+\\.[\\w.]+" },
};

const Adversarial = struct { name: []const u8, pattern: []const u8, input: []const u8 };
const adversarial_cases = [_]Adversarial{
    .{ .name = "(a+)+b", .pattern = "(a+)+b", .input = "a" ** 40 ++ "c" },
    .{ .name = "(a|aa)*c", .pattern = "(a|aa)*c", .input = "a" ** 40 ++ "b" },
};

// ------------------------------------------------------------------ timing

var watchdog_deadline = std.atomic.Value(i64).init(0); // ns on the awake clock; 0 = idle
var watchdog_case: []const u8 = "";

fn watchdog(io: Io) void {
    while (true) {
        io.sleep(.fromMilliseconds(100), .awake) catch return;
        const deadline = watchdog_deadline.load(.acquire);
        if (deadline == 0) continue;
        if (now(io) > deadline) {
            std.debug.print("\nbench: '{s}' exceeded the {d} s wall-time cap; aborting\n", .{ watchdog_case, @divTrunc(WATCHDOG_NS, std.time.ns_per_s) });
            std.process.exit(3);
        }
    }
}

fn now(io: Io) i64 {
    return @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
}

fn arm(io: Io, name: []const u8) void {
    watchdog_case = name;
    watchdog_deadline.store(now(io) + @as(i64, @intCast(WATCHDOG_NS)), .release);
}

fn disarm() void {
    watchdog_deadline.store(0, .release);
}

fn median(xs: []i64) i64 {
    std.mem.sort(i64, xs, {}, std.sort.asc(i64));
    return xs[xs.len / 2];
}

const Row = struct {
    name: []const u8,
    mbps: f64,
    median_ms: f64,
    runs: usize,
    matches: usize,
    allocs_per_findall: usize,
    allocs_per_match: f64,
    compile_us: f64,
    input_bytes: usize,
};

const ExecRow = struct {
    name: []const u8,
    /// Where the dispatcher sends the pattern, and T0's prefilter.
    engine: []const u8,
    mbps: [3]f64,
    /// F4b: routed `execAt` of the same pattern without groups (0 when the
    /// case has none).
    no_groups_mbps: f64 = 0,
    matches: usize,
    compile_us: f64,
    compile_expert_us: f64,
};

const OverheadRow = struct {
    name: []const u8,
    bytes: usize,
    engine: []const u8,
    ns: [3]f64,
};

const CompileRow = struct {
    name: []const u8,
    engine: []const u8,
    us: f64,
    expert_us: f64,
};

const AdvRow = struct {
    name: []const u8,
    ms: f64,
    outcome: []const u8,
};

fn benchCase(gpa: Allocator, io: Io, c: Case, input: []const u8) !Row {
    // Compile time: median of 200 compiles.
    var compile_ns: [200]i64 = undefined;
    for (&compile_ns) |*slot| {
        const t0 = now(io);
        var re = try zregex.Regex.compileWithOptions(gpa, c.pattern, c.options);
        slot.* = now(io) - t0;
        re.deinit();
    }

    var counter = CountingAllocator{ .child = gpa };
    const ca = counter.allocator();
    var re = try zregex.Regex.compileWithOptions(ca, c.pattern, c.options);
    defer re.deinit();

    var times: [MAX_RUNS]i64 = undefined;
    var runs: usize = 0;
    var matches: usize = 0;
    var allocs: usize = 0;
    var spent: i64 = 0;
    // One warm-up run, then timed runs until MAX_RUNS or the time budget.
    var i: usize = 0;
    while (i < MAX_RUNS + 1) : (i += 1) {
        arm(io, c.name);
        const before = counter.count;
        const t0 = now(io);
        var list = try re.findAll(input);
        const dt = now(io) - t0;
        disarm();
        const n = list.items.len;
        for (list.items) |m| m.deinit();
        list.deinit(ca);
        if (i == 0) {
            matches = n;
            allocs = counter.count - before;
            if (dt * @as(i64, MAX_RUNS) > @as(i64, @intCast(RUN_BUDGET_NS))) {
                // Too slow for more runs within the budget: the warm-up is
                // the only measurement.
                times[0] = dt;
                runs = 1;
                break;
            }
            continue;
        }
        times[runs] = dt;
        runs += 1;
        spent += dt;
        if (spent > @as(i64, @intCast(RUN_BUDGET_NS))) break;
    }
    const med = median(times[0..runs]);
    const secs = @as(f64, @floatFromInt(med)) / 1e9;
    return .{
        .name = c.name,
        .mbps = @as(f64, @floatFromInt(input.len)) / (1024.0 * 1024.0) / secs,
        .median_ms = secs * 1e3,
        .runs = runs,
        .matches = matches,
        .allocs_per_findall = allocs,
        .allocs_per_match = if (matches == 0) 0 else @as(f64, @floatFromInt(allocs)) / @as(f64, @floatFromInt(matches)),
        .compile_us = @as(f64, @floatFromInt(median(&compile_ns))) / 1e3,
        .input_bytes = input.len,
    };
}

/// One pass of `execAt` + `advanceIndex` over `input`, as a host's
/// `matchAll` runs; returns the number of matches.
fn execAtPass(re: zregex.Regex, input: []const u8, scratch: *zregex.Scratch) !usize {
    var buf: [64]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = buf[0..re.slotCount()] };
    const s: zregex.Subject = .{ .wtf8 = input };
    var n: usize = 0;
    var i: usize = 0;
    while (i <= input.len) {
        if (!try re.execAt(s, i, scratch, &out, .{})) break;
        n += 1;
        const start = buf[0].?;
        const end = buf[1].?;
        i = if (end == start) re.advanceIndex(s, end) else end;
    }
    return n;
}

fn engineName(re: zregex.Regex) []const u8 {
    const p = re.t0 orelse return "backtracker";
    // F4b: a tagged program has groups, or a phase product (`fail`).
    const tagged = p.nslots > 2 or for (p.insts) |inst| {
        if (inst == .fail) break true;
    } else false;
    return switch (p.prefilter.kind) {
        .none => if (tagged) "tagged VM" else "VM",
        .literal => if (tagged) "tagged VM, literal" else "VM, literal",
        .class_run => if (tagged) "tagged VM, class_run" else "VM, class_run",
        .shift_and => if (tagged) "tagged VM, shift_and" else "VM, shift_and",
        .first => if (tagged) "tagged VM, first" else "VM, first",
        .inner => if (tagged) "tagged VM, inner" else "VM, inner",
    };
}

fn compileMedianUs(gpa: Allocator, io: Io, pattern: []const u8, options: zregex.CompileOptions) !f64 {
    var ns: [200]i64 = undefined;
    for (&ns) |*slot| {
        const t0 = now(io);
        var re = try zregex.Regex.compileWithOptions(gpa, pattern, options);
        slot.* = now(io) - t0;
        re.deinit();
    }
    return @as(f64, @floatFromInt(median(&ns))) / 1e3;
}

/// Median MB/s of an `execAt` pass over `input` (one warm-up), and the
/// warm-up's match count.
fn measureExecAt(gpa: Allocator, io: Io, name: []const u8, pattern: []const u8, options: zregex.CompileOptions, input: []const u8, engine: ?*[]const u8) !struct { mbps: f64, matches: usize } {
    var re = try zregex.Regex.compileWithOptions(gpa, pattern, options);
    defer re.deinit();
    if (engine) |e| e.* = engineName(re);
    var scratch = zregex.Scratch.init(gpa);
    defer scratch.deinit();
    var times: [MAX_RUNS]i64 = undefined;
    var runs: usize = 0;
    var spent: i64 = 0;
    var matches: usize = 0;
    var i: usize = 0;
    while (i < MAX_RUNS + 1) : (i += 1) {
        arm(io, name);
        const t0 = now(io);
        const n = try execAtPass(re, input, &scratch);
        const dt = now(io) - t0;
        disarm();
        if (i == 0) {
            matches = n;
            if (dt * @as(i64, MAX_RUNS) > @as(i64, @intCast(RUN_BUDGET_NS))) {
                times[0] = dt;
                runs = 1;
                break;
            }
            continue;
        }
        times[runs] = dt;
        runs += 1;
        spent += dt;
        if (spent > @as(i64, @intCast(RUN_BUDGET_NS))) break;
    }
    const secs = @as(f64, @floatFromInt(median(times[0..runs]))) / 1e9;
    return .{ .mbps = @as(f64, @floatFromInt(input.len)) / (1024.0 * 1024.0) / secs, .matches = matches };
}

fn benchExecAt(gpa: Allocator, io: Io, c: Case, input: []const u8) !ExecRow {
    var row: ExecRow = .{ .name = c.name, .engine = "", .mbps = undefined, .matches = 0, .compile_us = 0, .compile_expert_us = 0 };
    for (std.enums.values(Engine), 0..) |e, k| {
        const r = try measureExecAt(gpa, io, c.name, c.pattern, engineOptions(c.options, e), input, if (e == .routed) &row.engine else null);
        if (e == .routed) row.matches = r.matches;
        row.mbps[k] = r.mbps;
    }
    if (c.no_groups) |p| row.no_groups_mbps = (try measureExecAt(gpa, io, c.name, p, c.options, input, null)).mbps;
    row.compile_us = try compileMedianUs(gpa, io, c.pattern, c.options);
    row.compile_expert_us = try compileMedianUs(gpa, io, c.pattern, engineOptions(c.options, .backtracker));
    return row;
}

fn benchOverhead(gpa: Allocator, io: Io, name: []const u8, pattern: []const u8, input: []const u8) !OverheadRow {
    var row: OverheadRow = .{ .name = name, .bytes = input.len, .engine = "", .ns = undefined };
    // Enough executions per sample for ~1 ms at 1 ns per byte.
    const iters: usize = @max(1000, 1_000_000 / (input.len + 16));
    for (std.enums.values(Engine), 0..) |e, k| {
        var re = try zregex.Regex.compileWithOptions(gpa, pattern, engineOptions(.{}, e));
        defer re.deinit();
        if (e == .routed) row.engine = engineName(re);
        var scratch = zregex.Scratch.init(gpa);
        defer scratch.deinit();
        var buf: [64]?usize = undefined;
        var out: zregex.MatchSlots = .{ .slots = buf[0..re.slotCount()] };
        _ = try re.execAt(.{ .wtf8 = input }, 0, &scratch, &out, .{});
        var samples: [11]i64 = undefined;
        for (&samples) |*slot| {
            const t0 = now(io);
            var n: usize = 0;
            for (0..iters) |_| {
                if (try re.execAt(.{ .wtf8 = input }, 0, &scratch, &out, .{})) n += 1;
            }
            std.mem.doNotOptimizeAway(n);
            slot.* = now(io) - t0;
        }
        row.ns[k] = @as(f64, @floatFromInt(median(&samples))) / @as(f64, @floatFromInt(iters));
    }
    return row;
}

fn benchAdversarial(gpa: Allocator, io: Io, c: Adversarial) !AdvRow {
    var re = try zregex.Regex.compile(gpa, c.pattern);
    defer re.deinit();
    arm(io, c.name);
    const t0 = now(io);
    const res = re.find(c.input);
    const dt = now(io) - t0;
    disarm();
    const outcome: []const u8 = if (res) |m| blk: {
        if (m) |mm| {
            mm.deinit();
            break :blk "match (unexpected)";
        }
        break :blk "no match (within budget)";
    } else |err| @errorName(err);
    return .{ .name = c.name, .ms = @as(f64, @floatFromInt(dt)) / 1e6, .outcome = outcome };
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const out_path = args.next() orelse "zig-out/bench/results.json";
    // Optional: run only the cases whose name contains this (running the
    // binary by hand; `zig build bench` runs everything).
    const filter = args.next() orelse "";

    _ = try std.Thread.spawn(.{}, watchdog, .{io});

    var rows: [throughput_cases.len]Row = undefined;
    for (throughput_cases, 0..) |c, i| {
        if (std.mem.indexOf(u8, c.name, filter) == null) {
            rows[i] = std.mem.zeroes(Row);
            rows[i].name = c.name;
            continue;
        }
        const input = try makeInput(gpa, c.input);
        defer gpa.free(input);
        rows[i] = try benchCase(gpa, io, c, input);
        std.debug.print("  {s}: {d:.2} MB/s\n", .{ c.name, rows[i].mbps });
    }
    var exec_rows: [throughput_cases.len]ExecRow = undefined;
    for (throughput_cases, 0..) |c, i| {
        if (std.mem.indexOf(u8, c.name, filter) == null) {
            exec_rows[i] = .{ .name = c.name, .engine = "", .mbps = .{ 0, 0, 0 }, .matches = 0, .compile_us = 0, .compile_expert_us = 0 };
            continue;
        }
        const input = try makeInput(gpa, c.input);
        defer gpa.free(input);
        exec_rows[i] = try benchExecAt(gpa, io, c, input);
        std.debug.print("  execAt {s}: {d:.2} MB/s ({s})\n", .{ c.name, exec_rows[i].mbps[0], exec_rows[i].engine });
    }
    var overhead: [overhead_cases.len]OverheadRow = undefined;
    for (overhead_cases, 0..) |c, i| overhead[i] = try benchOverhead(gpa, io, c.name, c.pattern, c.input);
    var compiles: [compile_cases.len]CompileRow = undefined;
    for (compile_cases, 0..) |c, i| {
        const re = try zregex.Regex.compile(gpa, c.pattern);
        defer re.deinit();
        compiles[i] = .{
            .name = c.name,
            .engine = engineName(re),
            .us = try compileMedianUs(gpa, io, c.pattern, .{}),
            .expert_us = try compileMedianUs(gpa, io, c.pattern, .{ .force_tier = .expert }),
        };
    }
    var adv: [adversarial_cases.len]AdvRow = undefined;
    for (adversarial_cases, 0..) |c, i| {
        adv[i] = try benchAdversarial(gpa, io, c);
        std.debug.print("  {s}: {d:.1} ms ({s})\n", .{ c.name, adv[i].ms, adv[i].outcome });
    }

    // Markdown on stdout.
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;
    try w.print("| Case | MB/s | Median (ms) | Runs | Matches | Allocs / findAll | Allocs / match | Compile (µs) |\n", .{});
    try w.print("|---|---|---|---|---|---|---|---|\n", .{});
    for (rows) |r| {
        try w.print("| `{s}` | {d:.2} | {d:.1} | {d} | {d} | {d} | {d:.1} | {d:.1} |\n", .{ r.name, r.mbps, r.median_ms, r.runs, r.matches, r.allocs_per_findall, r.allocs_per_match, r.compile_us });
    }
    try w.print("\n| Adversarial case (41-byte input) | Time (ms) | Outcome |\n|---|---|---|\n", .{});
    for (adv) |a| try w.print("| `{s}` | {d:.1} | {s} |\n", .{ a.name, a.ms, a.outcome });
    try w.print("\n| execAt case | Routed to | Routed (MB/s) | VM, no prefilters (MB/s) | Backtracker (MB/s) | Without groups (MB/s) | Compile (µs) | Compile, backtracker only (µs) |\n|---|---|---|---|---|---|---|---|\n", .{});
    for (exec_rows) |r| try w.print("| {s} | {s} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.1} | {d:.1} |\n", .{ r.name, r.engine, r.mbps[0], r.mbps[1], r.mbps[2], r.no_groups_mbps, r.compile_us, r.compile_expert_us });
    try w.print("\n| Overhead case | Routed to | Routed (ns) | VM, no prefilters (ns) | Backtracker (ns) | Routed / backtracker |\n|---|---|---|---|---|---|\n", .{});
    for (overhead) |r| try w.print("| {s} | {s} | {d:.1} | {d:.1} | {d:.1} | {d:.2} |\n", .{ r.name, r.engine, r.ns[0], r.ns[1], r.ns[2], r.ns[0] / r.ns[2] });
    try w.print("\n| Compile case | Routed to | Dispatcher (µs) | Backtracker only (µs) | Ratio |\n|---|---|---|---|---|\n", .{});
    for (compiles) |r| try w.print("| {s} | {s} | {d:.2} | {d:.2} | {d:.2} |\n", .{ r.name, r.engine, r.us, r.expert_us, r.us / r.expert_us });
    // F4b: executions where the tagged VM's two passes disagreed (a VM bug,
    // answered by the backtracker in unsafe builds); must be 0.
    const fallbacks = zregex.internal.two_pass_fallbacks.load(.monotonic);
    try w.print("\nTagged VM, D5 two-pass fallbacks to the backtracker (must be 0): {d}\n", .{fallbacks});
    try std.Io.File.stdout().writeStreamingAll(io, buf.written());

    // JSON file.
    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try json.writer.print("{f}\n", .{std.json.fmt(.{ .input_bytes = INPUT_SIZE, .throughput = rows, .adversarial = adv, .exec_at = exec_rows, .overhead = overhead, .compile = compiles, .two_pass_fallbacks = fallbacks }, .{ .whitespace = .indent_1 })});
    if (std.fs.path.dirname(out_path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = json.written() });
}
