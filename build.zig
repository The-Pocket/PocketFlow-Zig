const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create and export the PocketFlow module (public, accessible to dependents)
    const pocketflow_mod = b.addModule("pocketflow", .{
        .root_source_file = b.path("src/pocketflow.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create and export the Ollama module (public, accessible to dependents)
    const ollama_mod = b.addModule("ollama", .{
        .root_source_file = b.path("src/ollama.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build the PocketFlow library
    const lib = b.addLibrary(.{
        .name = "pocketflow",
        .root_module = pocketflow_mod,
    });

    b.installArtifact(lib);

    // Build the document generator example executable
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/document_generator.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add imports to the example module
    example_mod.addImport("pocketflow", pocketflow_mod);
    example_mod.addImport("ollama", ollama_mod);

    const example_exe = b.addExecutable(.{
        .name = "document_generator",
        .root_module = example_mod,
    });

    b.installArtifact(example_exe);

    const run_cmd = b.addRunArtifact(example_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the document generator example");
    run_step.dependOn(&run_cmd.step);

    // Unit tests for core modules
    const node_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/node.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const context_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/context.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const flow_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flow.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const ollama_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ollama.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_node_tests = b.addRunArtifact(node_tests);
    const run_context_tests = b.addRunArtifact(context_tests);
    const run_flow_tests = b.addRunArtifact(flow_tests);
    const run_ollama_tests = b.addRunArtifact(ollama_tests);

    // Test step to run all unit tests
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_node_tests.step);
    test_step.dependOn(&run_context_tests.step);
    test_step.dependOn(&run_flow_tests.step);
    test_step.dependOn(&run_ollama_tests.step);

    // Integration test step (requires Ollama server)
    const integration_test_step = b.step("test-integration", "Run integration tests (requires Ollama server)");
    integration_test_step.dependOn(&run_ollama_tests.step);
}
