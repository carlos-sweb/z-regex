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
