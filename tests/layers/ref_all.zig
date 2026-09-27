//! Forced analysis for the layer check (docs/REGEX_TIERS_PLAN.md, F2e).
//!
//! Zig analyzes lazily: an import a module isn't allowed to make, inside code
//! nobody references, compiles without error. `refAllDeclsRecursive` walks a
//! module's public declarations -- into every namespace it reaches, taking
//! the address of every non-generic function so its body is analyzed -- so
//! that, compiled in a module with only its allowed imports, any forbidden
//! import in reachable code fails the build. (`std.testing.refAllDecls` is
//! not recursive, and Zig 0.16 has no `refAllDeclsRecursive`.)

const std = @import("std");

pub fn refAllDeclsRecursive(comptime T: type) void {
    @setEvalBranchQuota(1_000_000);
    _ = comptime visit(T, &.{});
}

fn visit(comptime T: type, comptime seen: []const type) []const type {
    for (seen) |s| if (s == T) return seen;
    // The standard library is not ours to check.
    if (std.mem.startsWith(u8, @typeName(T), "std.")) return seen;
    var done: []const type = seen ++ &[_]type{T};
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return done,
    }
    for (std.meta.declarations(T)) |d| {
        const v = @field(T, d.name);
        const V = @TypeOf(v);
        if (V == type) {
            done = visit(v, done);
        } else switch (@typeInfo(V)) {
            .@"fn" => |f| if (!f.is_generic and f.calling_convention != .@"inline") {
                _ = &v;
            },
            else => {},
        }
    }
    return done;
}
