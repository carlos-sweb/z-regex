const std = @import("std");

/// The module layers (docs/REGEX_TIERS_PLAN.md, F2e): each module may import
/// only the modules listed as its `deps`, so dependencies go downwards. This
/// table is the single source of truth: the module graph is built from it,
/// and `check-layers` checks the sources against it.
pub const Layer = struct {
    name: []const u8,
    /// The module's root file; the module owns that file's directory.
    root: []const u8,
    deps: []const []const u8,
};

pub const layers = [_]Layer{
    .{ .name = "ir", .root = "src/ir/root.zig", .deps = &.{} },
    .{ .name = "unicode", .root = "src/unicode/root.zig", .deps = &.{} },
    .{ .name = "utils", .root = "src/utils/root.zig", .deps = &.{} },
    .{ .name = "frontend", .root = "src/frontend/root.zig", .deps = &.{ "ir", "unicode" } },
    .{ .name = "tier2", .root = "src/tier2/root.zig", .deps = &.{ "ir", "unicode", "utils" } },
    .{ .name = "zregex", .root = "src/main.zig", .deps = &.{ "ir", "unicode", "utils", "frontend", "tier2" } },
};

/// One build of the whole module graph (per target/optimize mode).
const Modules = struct {
    by_name: std.StringArrayHashMapUnmanaged(*std.Build.Module),

    fn get(self: Modules, name: []const u8) *std.Build.Module {
        return self.by_name.get(name).?;
    }
};

/// Create every layer's module with exactly its declared imports. With
/// `public`, `zregex` is the package's exported module (`b.addModule`); the
/// others are always internal.
fn addModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, public: bool) Modules {
    var mods: Modules = .{ .by_name = .empty };
    for (layers) |layer| {
        const opts: std.Build.Module.CreateOptions = .{
            .root_source_file = b.path(layer.root),
            .target = target,
            .optimize = optimize,
        };
        const m = if (public and std.mem.eql(u8, layer.name, "zregex")) b.addModule("zregex", opts) else b.createModule(opts);
        for (layer.deps) |dep| m.addImport(dep, mods.get(dep));
        mods.by_name.put(b.allocator, layer.name, m) catch @panic("OOM");
    }
    return mods;
}

/// The C ABI module (src/c_api.zig), on top of `zregex` only.
fn addCApiModule(b: *std.Build, mods: Modules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    m.addImport("zregex", mods.get("zregex"));
    return m;
}

pub fn build(b: *std.Build) void {
    // Standard target and optimize options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module for the exported C ABI (src/c_api.zig). This is *not* a supported public
    // C/C++ API -- no headers or wrapper are shipped for it. It exists solely as the
    // FFI substrate the test262 conformance harness (docs/ECMASCRIPT_COMPATIBILITY_PLAN.md
    // Phase 8) drives zregex through from Node.js. Anyone else wanting to call zregex
    // from C/C++ can link against the shared library and write their own bindings
    // against these exported symbols.
    // Public module exposed to downstream consumers via the Zig package manager
    // (e.g. `b.dependency("zregex", .{}).module("zregex")`), with the
    // internal layer modules underneath it.
    const mods = addModules(b, target, optimize, true);
    const lib_module = mods.get("zregex");
    const c_api_module = addCApiModule(b, mods, target, optimize);

    // =============================================================================
    // Library Compilation
    // =============================================================================

    // Shared library (.so, .dylib, .dll) -- built purely as the FFI target the
    // conformance harness loads (see the comment on c_api_module above). No static
    // library and no headers are installed: there's no supported static-linking or
    // header-based C/C++ integration path anymore.
    const shared_lib = b.addLibrary(.{
        .name = "zregex",
        .root_module = c_api_module,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .linkage = .dynamic,
    });
    b.installArtifact(shared_lib);

    // =============================================================================
    // Testing
    // =============================================================================

    // Unit tests: one test binary per layer module, compiled with only the
    // modules that layer may import, so the tests obey the layering too.
    const test_step = b.step("test", "Run all tests");
    const unit_test_step = b.step("test-unit", "Run unit tests only");
    for (layers) |layer| {
        const layer_tests = b.addTest(.{ .name = b.fmt("test-{s}", .{layer.name}), .root_module = mods.get(layer.name) });
        const run_layer_tests = b.addRunArtifact(layer_tests);
        test_step.dependOn(&run_layer_tests.step);
        unit_test_step.dependOn(&run_layer_tests.step);
    }

    // Tests for the exported C ABI (src/c_api.zig), which has its own root.
    const c_api_tests = b.addTest(.{
        .root_module = c_api_module,
    });
    const run_c_api_tests = b.addRunArtifact(c_api_tests);

    // Create integration test executable
    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_module.addImport("zregex", lib_module);

    const integration_tests = b.addTest(.{
        .root_module = integration_module,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);

    test_step.dependOn(&run_c_api_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    unit_test_step.dependOn(&run_c_api_tests.step);

    const integration_test_step = b.step("test-integration", "Run integration tests only");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Bytecode snapshot (tests/snapshots/bytecode.txt, checked by
    // tests/bytecode_snapshot.zig inside `test`): rewrite its outcomes after
    // a justified bytecode change (docs/REGEX_TIERS_PLAN.md, F2c policy).
    const snapshot_update_module = b.createModule(.{
        .root_source_file = b.path("tests/snapshot_update.zig"),
        .target = target,
        .optimize = optimize,
    });
    snapshot_update_module.addImport("zregex", lib_module);
    const snapshot_update_exe = b.addExecutable(.{
        .name = "snapshot-update",
        .root_module = snapshot_update_module,
    });
    const run_snapshot_update = b.addRunArtifact(snapshot_update_exe);
    run_snapshot_update.addArg(b.pathFromRoot("tests/snapshots/bytecode.txt"));
    run_snapshot_update.has_side_effects = true;
    const snapshot_update_step = b.step("update-bytecode-snapshot", "Rewrite tests/snapshots/bytecode.txt for the current compiler");
    snapshot_update_step.dependOn(&run_snapshot_update.step);

    // Conformance sample against test262-derived cases (see
    // docs/ECMASCRIPT_COMPATIBILITY_PLAN.md Phase 6). Kept out of the
    // default `test` step deliberately: it's an informational pass-rate
    // report, not a pass/fail gate on 100% JS conformance.
    const conformance_module = b.createModule(.{
        .root_source_file = b.path("tests/test262_conformance.zig"),
        .target = target,
        .optimize = optimize,
    });
    conformance_module.addImport("zregex", lib_module);

    const conformance_tests = b.addTest(.{
        .root_module = conformance_module,
    });
    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    run_conformance_tests.has_side_effects = true; // always show the pass-rate summary

    const conformance_step = b.step("test-conformance", "Run test262-derived conformance sample");
    conformance_step.dependOn(&run_conformance_tests.step);

    // Parser fuzz stress (tests/fuzz_stress.zig, docs/REGEX_TIERS_PLAN.md
    // F0d): 20,000 generated patterns, ~16 s in Debug. Kept out of the
    // default `test` step deliberately (run by hand or in weekly CI); the
    // corpus part of the fuzzer stays in `test`.
    const fuzz_stress_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz_stress.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_stress_module.addImport("zregex", lib_module);

    const fuzz_stress_tests = b.addTest(.{
        .root_module = fuzz_stress_module,
    });
    const run_fuzz_stress_tests = b.addRunArtifact(fuzz_stress_tests);

    const fuzz_stress_step = b.step("test-fuzz-stress", "Parser fuzz stress: 20,000 generated patterns (manual or weekly CI)");
    fuzz_stress_step.dependOn(&run_fuzz_stress_tests.step);

    // test262 gate (scripts/test262, docs/REGEX_TIERS_PLAN.md F0b). Opt-in: it
    // needs Node, `npm ci --prefix scripts/test262` and the pinned test262
    // checkout from scripts/test262/fetch.sh. Always runs against a
    // ReleaseSafe build so engine bugs surface as crashes, not silent UB.
    const safe_mods = addModules(b, target, .ReleaseSafe, false);
    const test262_lib = b.addLibrary(.{
        .name = "zregex-test262",
        .root_module = addCApiModule(b, safe_mods, target, .ReleaseSafe),
        .linkage = .dynamic,
    });
    const run_test262 = b.addSystemCommand(&.{ "node", "scripts/test262/run.mjs", "--check-baseline", "scripts/test262/baseline.json", "--lib" });
    run_test262.addArtifactArg(test262_lib);
    run_test262.has_side_effects = true;
    const test262_step = b.step("test262", "Run test262 against the committed baseline (needs Node + scripts/test262/fetch.sh)");
    test262_step.dependOn(&run_test262.step);

    // Differential test against V8 (scripts/test262/differential.mjs,
    // docs/REGEX_TIERS_PLAN.md F1c): generated patterns with captures and
    // backreferences, compared with Node's own RegExp. A manual tool for
    // suspected capture regressions, not a gate: known deviations show up
    // too, so compare against a reference run.
    const run_differential = b.addSystemCommand(&.{ "node", "scripts/test262/differential.mjs", "--lib" });
    run_differential.addArtifactArg(test262_lib);
    run_differential.has_side_effects = true;
    const differential_step = b.step("differential-v8", "Compare zregex with V8 on generated patterns (needs Node + koffi)");
    differential_step.dependOn(&run_differential.step);

    // Performance baseline (bench/bench.zig, docs/REGEX_TIERS_PLAN.md F0d).
    // Always ReleaseFast, whatever -Doptimize says, so numbers are comparable.
    const bench_zregex = addModules(b, target, .ReleaseFast, false).get("zregex");
    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_module.addImport("zregex", bench_zregex);
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_module });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("."));
    run_bench.addArg("zig-out/bench/results.json");
    run_bench.has_side_effects = true;
    const bench_step = b.step("bench", "Run the performance baseline (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    // =============================================================================
    // Library-specific build steps
    // =============================================================================

    const shared_step = b.step("shared", "Build the shared library (FFI target for the conformance harness)");
    shared_step.dependOn(&shared_lib.step);

    // =============================================================================
    // Examples
    // =============================================================================
    // Wired into the build graph so a stale example (e.g. removed stdlib API)
    // fails `zig build examples` instead of rotting unnoticed.

    const examples_step = b.step("examples", "Build all examples");
    const example_names = [_][]const u8{
        "basic_usage",
        "capture_groups",
        "find_all",
        "validation",
    };
    for (example_names) |name| {
        const example_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        example_module.addImport("zregex", lib_module);

        const example_exe = b.addExecutable(.{
            .name = name,
            .root_module = example_module,
        });
        examples_step.dependOn(&b.addInstallArtifact(example_exe, .{}).step);
    }
}
