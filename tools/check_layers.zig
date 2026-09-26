//! `zig build check-layers` (docs/REGEX_TIERS_PLAN.md, F2e): a textual check
//! of every `@import` under `src/` against build.zig's layer table, which it
//! gets as arguments. It complements the compiler, which only sees live code:
//! this also catches a forbidden import in dead code or private declarations.
//!
//!   check_layers <src-dir> <name>=<root-file>=<dep,dep,...> ...
//!                          [+<name>=<file>=<leaf,leaf,...>]
//!
//! A file belongs to the layer whose root directory is the deepest one
//! containing it (a root may also name a single file, like `src/c_api.zig`,
//! which then belongs to that layer alone). Rules per `@import("x")`:
//! - `std`, `builtin` and `root` are always allowed;
//! - another module name must be one of the file's layer's deps;
//! - a relative `.zig` path must resolve to a file of the same layer.
//!
//! A `+` argument names a test aggregator (F4a step 0, src/leaves_tests.zig):
//! a single file that may import, by relative path, exactly the root files
//! of the listed layers, each of which must have no deps (a leaf), and
//! nothing else but `std`. The aggregator has to import every one of them.

const std = @import("std");

const Layer = struct {
    name: []const u8,
    /// Directory the layer owns ("" when the root is a single file).
    dir: []const u8,
    /// Single-file layers (c_api) own only this file.
    file: ?[]const u8,
    deps: []const []const u8,
    root: []const u8,
    /// A test aggregator: `deps` are the leaf layers it includes.
    aggregator: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const src_dir = args.next() orelse return error.MissingSrcDir;

    var layers: std.ArrayListUnmanaged(Layer) = .empty;
    while (args.next()) |raw_arg| {
        const aggregator = raw_arg.len > 0 and raw_arg[0] == '+';
        const arg = if (aggregator) raw_arg[1..] else raw_arg;
        var it = std.mem.splitScalar(u8, arg, '=');
        const name = it.next() orelse return error.BadLayerArg;
        const root = it.next() orelse return error.BadLayerArg;
        const deps_text = it.next() orelse "";
        var deps: std.ArrayListUnmanaged([]const u8) = .empty;
        var dit = std.mem.splitScalar(u8, deps_text, ',');
        while (dit.next()) |d| if (d.len > 0) try deps.append(gpa, d);
        const dir = std.fs.path.dirname(root) orelse "";
        const is_single_file = aggregator or (!std.mem.eql(u8, std.fs.path.basename(root), "root.zig") and !std.mem.eql(u8, std.fs.path.basename(root), "main.zig"));
        try layers.append(gpa, .{
            .name = name,
            .dir = if (is_single_file) "" else dir,
            .file = if (is_single_file) root else null,
            .deps = deps.items,
            .root = root,
            .aggregator = aggregator,
        });
    }

    var root_dir = try std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true });
    defer root_dir.close(io);
    var walker = try root_dir.walk(gpa);
    defer walker.deinit();

    var violations: usize = 0;
    var files: usize = 0;
    aggregated = .empty;
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fs.path.join(gpa, &.{ src_dir, entry.path });
        const owner = layerOf(layers.items, path) orelse {
            try w.print("{s}: belongs to no layer\n", .{path});
            violations += 1;
            continue;
        };
        files += 1;
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            const code = if (std.mem.indexOf(u8, line, "//")) |c| line[0..c] else line;
            var rest = code;
            while (std.mem.indexOf(u8, rest, "@import(\"")) |i| {
                rest = rest[i + "@import(\"".len ..];
                const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
                const target = rest[0..end];
                rest = rest[end..];
                if (try check(gpa, layers.items, owner, path, target)) |why| {
                    try w.print("{s}:{d}: @import(\"{s}\"): {s}\n", .{ path, line_no, target, why });
                    violations += 1;
                }
            }
        }
    }
    // An aggregator must include every layer it lists.
    for (layers.items) |*l| if (l.aggregator) for (l.deps) |d| {
        const leaf = findLayer(layers.items, d) orelse continue;
        var found = false;
        for (aggregated.items) |seen| if (seen == leaf) {
            found = true;
        };
        if (!found) {
            try w.print("{s}: test aggregator doesn't include leaf layer '{s}' ({s})\n", .{ l.root, d, leaf.root });
            violations += 1;
        }
    };
    try w.print("check-layers: {d} files, {d} violation(s)\n", .{ files, violations });
    try std.Io.File.stderr().writeStreamingAll(io, out.written());
    if (violations > 0) std.process.exit(1);
}

/// The layer that owns `path`: a single-file layer naming it, else the layer
/// with the deepest directory containing it.
fn layerOf(layers: []const Layer, path: []const u8) ?*const Layer {
    for (layers) |*l| if (l.file) |f| if (std.mem.eql(u8, f, path)) return l;
    var best: ?*const Layer = null;
    for (layers) |*l| {
        if (l.file != null) continue;
        if (!std.mem.startsWith(u8, path, l.dir) or path.len <= l.dir.len or path[l.dir.len] != '/') continue;
        if (best == null or l.dir.len > best.?.dir.len) best = l;
    }
    return best;
}

/// The leaf layers an aggregator was seen to include.
var aggregated: std.ArrayListUnmanaged(*const Layer) = .empty;

fn findLayer(layers: []const Layer, name: []const u8) ?*const Layer {
    for (layers) |*l| if (!l.aggregator and std.mem.eql(u8, l.name, name)) return l;
    return null;
}

/// Why `target`, imported from `path` in layer `owner`, is not allowed, or
/// null if it is.
fn check(gpa: std.mem.Allocator, layers: []const Layer, owner: *const Layer, path: []const u8, target: []const u8) !?[]const u8 {
    if (owner.aggregator) {
        if (std.mem.eql(u8, target, "std")) return null;
        if (!std.mem.endsWith(u8, target, ".zig")) return "a test aggregator imports only std and leaf roots";
        const resolved = try std.fs.path.resolve(gpa, &.{ std.fs.path.dirname(path) orelse ".", target });
        for (owner.deps) |d| {
            const leaf = findLayer(layers, d) orelse return try std.fmt.allocPrint(gpa, "unknown layer '{s}'", .{d});
            if (!std.mem.eql(u8, leaf.root, resolved)) continue;
            if (leaf.deps.len != 0) return try std.fmt.allocPrint(gpa, "layer '{s}' is not a leaf", .{d});
            try aggregated.append(gpa, leaf);
            return null;
        }
        return "a test aggregator imports only the roots of the leaf layers it lists";
    }
    if (std.mem.endsWith(u8, target, ".zig")) {
        const resolved = try std.fs.path.resolve(gpa, &.{ std.fs.path.dirname(path) orelse ".", target });
        const target_owner = layerOf(layers, resolved) orelse return "relative import outside every layer";
        if (target_owner != owner) return try std.fmt.allocPrint(gpa, "relative import into layer '{s}' from layer '{s}' (import the module by name)", .{ target_owner.name, owner.name });
        return null;
    }
    for ([_][]const u8{ "std", "builtin", "root" }) |ok| if (std.mem.eql(u8, target, ok)) return null;
    for (owner.deps) |d| if (std.mem.eql(u8, d, target)) return null;
    return try std.fmt.allocPrint(gpa, "layer '{s}' may not import module '{s}'", .{ owner.name, target });
}
