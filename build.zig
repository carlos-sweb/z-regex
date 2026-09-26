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
    .{ .name = "subject", .root = "src/subject/root.zig", .deps = &.{} },
    .{ .name = "frontend", .root = "src/frontend/root.zig", .deps = &.{ "ir", "unicode" } },
    .{ .name = "tier0", .root = "src/tier0/root.zig", .deps = &.{ "ir", "utils", "subject" } },
    .{ .name = "tier1", .root = "src/tier1/root.zig", .deps = &.{ "ir", "unicode", "utils", "subject", "tier0" } },
    .{ .name = "tier2", .root = "src/tier2/root.zig", .deps = &.{ "ir", "unicode", "utils", "subject" } },
    .{ .name = "zregex", .root = "src/main.zig", .deps = &.{ "ir", "unicode", "utils", "subject", "frontend", "tier0", "tier1", "tier2" } },
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

/// A layer's declared deps, from the table.
fn depsOf(name: []const u8) []const []const u8 {
    for (layers) |layer| if (std.mem.eql(u8, layer.name, name)) return layer.deps;
    unreachable;
}

const Canary = struct {
    /// The layer the canary pretends to be (it gets that layer's deps).
    layer: []const u8,
    /// Its root file: `bad` must fail with `expect`; `good` must compile.
    bad: []const u8,
    good: []const u8,
    expect: []const u8,
    /// Extra files next to it (for the relative-path canary).
    extra: []const [2][]const u8 = &.{},
};

const canaries = [_]Canary{
    .{
        .layer = "tier0",
        .bad = "pub fn f() usize {\n    return @import(\"unicode\").tables.RANGES_L.len;\n}\n",
        .good = "pub fn f() usize {\n    return @sizeOf(@import(\"ir\").hir.Flags);\n}\n",
        .expect = "no module named 'unicode' available within module 'tier0'",
    },
    .{
        .layer = "tier1",
        .bad = "pub fn f() usize {\n    return @sizeOf(@import(\"tier2\").ExecOptions);\n}\n",
        .good = "pub fn f() usize {\n    return @sizeOf(@import(\"tier0\").hir.Flags);\n}\n",
        .expect = "no module named 'tier2' available within module 'tier1'",
    },
    .{
        .layer = "tier0",
        .bad = "pub fn f() usize {\n    return @import(\"../unicode/properties.zig\").x;\n}\n",
        .good = "pub fn f() usize {\n    return @import(\"helper.zig\").x;\n}\n",
        .expect = "import of file outside module path",
        .extra = &.{ .{ "unicode/properties.zig", "pub const x: usize = 1;\n" }, .{ "helper.zig", "pub const x: usize = 1;\n" } },
    },
};

/// Each canary is compiled twice as a module named after its layer, with that
/// layer's deps from the table: `bad` must fail with exactly `expect` (so a
/// typo, which fails differently, doesn't pass), `good` must compile (so the
/// file is otherwise sound). Granting the forbidden edge in the table makes
/// `bad` compile, and the step fails. The sources are generated into the
/// build cache, never committed.
fn addCanaries(b: *std.Build, mods: Modules, target: std.Build.ResolvedTarget, step: *std.Build.Step) void {
    for (canaries, 0..) |canary, i| {
        for ([_]bool{ true, false }) |bad| {
            const files = b.addWriteFiles();
            const dir = b.fmt("canary{d}/{s}", .{ i, if (bad) "bad" else "good" });
            const root = files.add(b.fmt("{s}/{s}/root.zig", .{ dir, canary.layer }), if (bad) canary.bad else canary.good);
            for (canary.extra) |e| {
                // `extra` paths are relative to the layer directory's parent
                // (unicode/...) or to the layer directory itself (helper.zig).
                const sub = if (std.mem.indexOfScalar(u8, e[0], '/') != null) b.fmt("{s}/{s}", .{ dir, e[0] }) else b.fmt("{s}/{s}/{s}", .{ dir, canary.layer, e[0] });
                _ = files.add(sub, e[1]);
            }
            const main = files.add(b.fmt("{s}/main.zig", .{dir}), b.fmt("test {{\n    _ = &@import(\"{s}\").f;\n}}\n", .{canary.layer}));
            const layer_mod = b.createModule(.{ .root_source_file = root, .target = target, .optimize = .Debug });
            for (depsOf(canary.layer)) |dep| layer_mod.addImport(dep, mods.get(dep));
            const main_mod = b.createModule(.{ .root_source_file = main, .target = target, .optimize = .Debug });
            main_mod.addImport(canary.layer, layer_mod);
            const t = b.addTest(.{ .name = b.fmt("canary{d}-{s}", .{ i, if (bad) "bad" else "good" }), .root_module = main_mod });
            if (bad) t.expect_errors = .{ .contains = canary.expect };
            step.dependOn(&t.step);
        }
    }
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

    // Layer check (docs/REGEX_TIERS_PLAN.md, F2e), its own step: a textual
    // lint of every @import against the layer table, plus canaries that must
    // fail to compile with the exact error the layering produces, each next
    // to a control that must compile.
    const check_layers_step = b.step("check-layers", "Check the module layering: import lint and compile-error canaries");
    const lint_exe = b.addExecutable(.{
        .name = "check_layers",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/check_layers.zig"), .target = b.graph.host, .optimize = .Debug }),
    });
    const run_lint = b.addRunArtifact(lint_exe);
    run_lint.setCwd(b.path("."));
    run_lint.addArg("src");
    for (layers) |layer| {
        const deps = std.mem.join(b.allocator, ",", layer.deps) catch @panic("OOM");
        run_lint.addArg(b.fmt("{s}={s}={s}", .{ layer.name, layer.root, deps }));
    }
    run_lint.addArg("c_api=src/c_api.zig=zregex");
    run_lint.has_side_effects = true;
    check_layers_step.dependOn(&run_lint.step);
    addCanaries(b, mods, target, check_layers_step);

    // Forced analysis (tests/layers/ref_all.zig): each layer's public API is
    // walked recursively in a test binary whose only import is that layer, so
    // a forbidden import anywhere reachable fails to compile. Part of
    // check-layers, not `test`: it added 77 % to `zig build test` in
    // ReleaseSafe (F2e measurement); compiling is the check, nothing runs.
    const ref_all = b.createModule(.{ .root_source_file = b.path("tests/layers/ref_all.zig"), .target = target, .optimize = optimize });
    const layer_sources = b.addWriteFiles();
    for (layers) |layer| {
        const src = layer_sources.add(b.fmt("{s}.zig", .{layer.name}), b.fmt(
            \\test "forced analysis of the {s} module" {{
            \\    @import("ref_all").refAllDeclsRecursive(@import("{s}"));
            \\}}
            \\
        , .{ layer.name, layer.name }));
        const m = b.createModule(.{ .root_source_file = src, .target = target, .optimize = optimize });
        m.addImport("ref_all", ref_all);
        m.addImport(layer.name, mods.get(layer.name));
        const analysis_tests = b.addTest(.{ .name = b.fmt("analysis-{s}", .{layer.name}), .root_module = m });
        check_layers_step.dependOn(&analysis_tests.step);
    }

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
