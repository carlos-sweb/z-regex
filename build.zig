const std = @import("std");

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
    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Public module exposed to downstream consumers via the Zig package manager
    // (e.g. `b.dependency("zregex", .{}).module("zregex")`).
    const lib_module = b.addModule("zregex", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // Create unit test executable
    const tests = b.addTest(.{
        .root_module = lib_module,
    });

    const run_tests = b.addRunArtifact(tests);

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

    // Test step (runs all tests)
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_c_api_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Individual test steps
    const unit_test_step = b.step("test-unit", "Run unit tests only");
    unit_test_step.dependOn(&run_tests.step);

    const integration_test_step = b.step("test-integration", "Run integration tests only");
    integration_test_step.dependOn(&run_integration_tests.step);

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
    const test262_lib = b.addLibrary(.{
        .name = "zregex-test262",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .linkage = .dynamic,
    });
    const run_test262 = b.addSystemCommand(&.{ "node", "scripts/test262/run.mjs", "--check-baseline", "scripts/test262/baseline.json", "--lib" });
    run_test262.addArtifactArg(test262_lib);
    run_test262.has_side_effects = true;
    const test262_step = b.step("test262", "Run test262 against the committed baseline (needs Node + scripts/test262/fetch.sh)");
    test262_step.dependOn(&run_test262.step);

    // Performance baseline (bench/bench.zig, docs/REGEX_TIERS_PLAN.md F0d).
    // Always ReleaseFast, whatever -Doptimize says, so numbers are comparable.
    const bench_zregex = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
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
