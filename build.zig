const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_macos = target.result.os.tag == .macos;
    const is_native = target.result.os.tag == @import("builtin").os.tag;

    // Build options to pass compile-time config to source
    const build_options = b.addOptions();
    build_options.addOption(bool, "is_macos", is_macos);
    const build_options_module = build_options.createModule();

    // e_jerk_gpu library for GPU detection and auto-selection (also provides zigtrait)
    const e_jerk_gpu_dep = b.dependency("e_jerk_gpu", .{});
    const e_jerk_gpu_module = e_jerk_gpu_dep.module("e_jerk_gpu");
    const zigtrait_module = e_jerk_gpu_dep.module("zigtrait");

    // zig-metal dependency
    const zig_metal_dep = b.dependency("zig_metal", .{});
    const zig_metal_module = b.addModule("zig-metal", .{
        .root_source_file = zig_metal_dep.path("src/main.zig"),
        .imports = &.{
            .{ .name = "zigtrait", .module = zigtrait_module },
        },
    });

    // Vulkan dependencies
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan_dep = b.dependency("vulkan_zig", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    });
    const vulkan_module = vulkan_dep.module("vulkan-zig");

    // Regex engine
    const regex_dep = b.dependency("regex", .{});
    const regex_module = regex_dep.module("regex");

    // Shared shader library
    const shaders_common = b.dependency("shaders_common", .{});

    // Compile SPIR-V shader from GLSL for Vulkan (literal substitution)
    const spirv_compile = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-O",
    });
    // Add include path for shared GLSL headers
    spirv_compile.addArg("-I");
    spirv_compile.addDirectoryArg(shaders_common.path("glsl"));
    spirv_compile.addArg("-o");
    const spirv_output = spirv_compile.addOutputFileArg("substitute.spv");
    spirv_compile.addFileArg(b.path("src/shaders/substitute.comp"));

    // Compile SPIR-V shader from GLSL for Vulkan (regex substitution)
    const spirv_regex_compile = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-O",
    });
    spirv_regex_compile.addArg("-I");
    spirv_regex_compile.addDirectoryArg(shaders_common.path("glsl"));
    spirv_regex_compile.addArg("-o");
    const spirv_regex_output = spirv_regex_compile.addOutputFileArg("substitute_regex.spv");
    spirv_regex_compile.addFileArg(b.path("src/shaders/substitute_regex.comp"));

    // Create embedded SPIR-V module with both shaders
    const spirv_module = b.addModule("spirv", .{
        .root_source_file = b.addWriteFiles().add("spirv.zig",
            \\pub const EMBEDDED_SPIRV = @embedFile("substitute.spv");
            \\pub const EMBEDDED_SPIRV_REGEX = @embedFile("substitute_regex.spv");
        ),
    });
    spirv_module.addAnonymousImport("substitute.spv", .{ .root_source_file = spirv_output });
    spirv_module.addAnonymousImport("substitute_regex.spv", .{ .root_source_file = spirv_regex_output });

    // Preprocess Metal shader to inline the string_ops.h and regex_ops.h includes
    // Concatenates: headers + shader (with include lines removed)
    const metal_preprocess = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        \\cat "$1" "$2" && grep -v '#include "string_ops.h"' "$3" | grep -v '#include "regex_ops.h"'
        , "--",
    });
    metal_preprocess.addFileArg(shaders_common.path("metal/string_ops.h"));
    metal_preprocess.addFileArg(shaders_common.path("metal/regex_ops.h"));
    metal_preprocess.addFileArg(b.path("src/shaders/substitute.metal"));
    const preprocessed_metal = metal_preprocess.captureStdOut();

    // Create embedded Metal shader module
    const metal_module = b.addModule("metal_shader", .{
        .root_source_file = b.addWriteFiles().add("metal_shader.zig",
            \\pub const EMBEDDED_METAL_SHADER = @embedFile("substitute.metal");
        ),
    });
    metal_module.addAnonymousImport("substitute.metal", .{ .root_source_file = preprocessed_metal });

    // Create gpu module for reuse
    const gpu_module = b.addModule("gpu", .{
        .root_source_file = b.path("src/gpu/mod.zig"),
        .imports = &.{
            .{ .name = "zig-metal", .module = zig_metal_module },
            .{ .name = "build_options", .module = build_options_module },
            .{ .name = "vulkan", .module = vulkan_module },
            .{ .name = "spirv", .module = spirv_module },
            .{ .name = "metal_shader", .module = metal_module },
            .{ .name = "e_jerk_gpu", .module = e_jerk_gpu_module },
            .{ .name = "regex", .module = regex_module },
        },
    });

    // Create cpu module for reuse (optimized SIMD implementation)
    const cpu_module = b.addModule("cpu", .{
        .root_source_file = b.path("src/cpu_optimized.zig"),
        .imports = &.{
            .{ .name = "gpu", .module = gpu_module },
            .{ .name = "regex", .module = regex_module },
        },
    });

    // Create cpu_gnu module (GNU sed reference implementation)
    // Note: sed GNU backend delegates to optimized backend since GNU sed's pattern
    // matching is tightly integrated with its command processor
    const cpu_gnu_module = b.addModule("cpu_gnu", .{
        .root_source_file = b.path("src/cpu_gnu.zig"),
        .imports = &.{
            .{ .name = "gpu", .module = gpu_module },
            .{ .name = "cpu_optimized", .module = cpu_module },
        },
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "sed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "cpu_gnu", .module = cpu_gnu_module },
            },
        }),
    });

    // Platform-specific linking
    if (is_macos) {
        if (is_native) {
            exe.linkFramework("Foundation");
            exe.linkFramework("Metal");
            exe.linkFramework("QuartzCore");

            // MoltenVK from Homebrew for Vulkan on macOS
            exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
            exe.linkSystemLibrary("MoltenVK");
        }
    } else {
        if (is_native) {
            exe.linkSystemLibrary("vulkan");
        }
    }

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run sed");
    run_step.dependOn(&run_cmd.step);

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "sed-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "cpu_gnu", .module = cpu_gnu_module },
            },
        }),
    });

    if (is_macos) {
        if (is_native) {
            bench_exe.linkFramework("Foundation");
            bench_exe.linkFramework("Metal");
            bench_exe.linkFramework("QuartzCore");
            bench_exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
            bench_exe.linkSystemLibrary("MoltenVK");
        }
    } else {
        if (is_native) {
            bench_exe.linkSystemLibrary("vulkan");
        }
    }

    b.installArtifact(bench_exe);

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Smoke tests executable
    const smoke_exe = b.addExecutable(.{
        .name = "sed-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/smoke_tests.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });

    if (is_macos) {
        if (is_native) {
            smoke_exe.linkFramework("Foundation");
            smoke_exe.linkFramework("Metal");
            smoke_exe.linkFramework("QuartzCore");
            smoke_exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
            smoke_exe.linkSystemLibrary("MoltenVK");
        }
    } else {
        if (is_native) {
            smoke_exe.linkSystemLibrary("vulkan");
        }
    }

    b.installArtifact(smoke_exe);

    const smoke_cmd = b.addRunArtifact(smoke_exe);
    smoke_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        smoke_cmd.addArgs(args);
    }

    const smoke_step = b.step("smoke", "Run smoke tests");
    smoke_step.dependOn(&smoke_cmd.step);

    // Tests from src/main.zig
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });

    if (is_macos and is_native) {
        main_tests.linkFramework("Foundation");
        main_tests.linkFramework("Metal");
        main_tests.linkFramework("QuartzCore");
        main_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        main_tests.linkSystemLibrary("MoltenVK");
    }

    // Unit tests from tests/unit_tests.zig
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });

    if (is_macos and is_native) {
        unit_tests.linkFramework("Foundation");
        unit_tests.linkFramework("Metal");
        unit_tests.linkFramework("QuartzCore");
        unit_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        unit_tests.linkSystemLibrary("MoltenVK");
    }

    // Metal shader compilation check (macOS only)
    // This validates the shader compiles without warnings at build time
    if (is_macos) {
        // First write preprocessed shader to a file with .metal extension
        const write_shader = b.addWriteFiles();
        _ = write_shader.addCopyFile(preprocessed_metal, "substitute_check.metal");

        const metal_compile_check = b.addSystemCommand(&.{
            "xcrun", "-sdk", "macosx", "metal",
            "-Werror", // Treat warnings as errors
            "-c",
        });
        metal_compile_check.addFileArg(write_shader.getDirectory().path(b, "substitute_check.metal"));
        metal_compile_check.addArg("-o");
        _ = metal_compile_check.addOutputFileArg("substitute.air");

        // Make unit tests depend on shader compilation check
        unit_tests.step.dependOn(&metal_compile_check.step);
    }

    // Regex tests from tests/regex_tests.zig
    const regex_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/regex_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });

    if (is_macos and is_native) {
        regex_tests.linkFramework("Foundation");
        regex_tests.linkFramework("Metal");
        regex_tests.linkFramework("QuartzCore");
        regex_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        regex_tests.linkSystemLibrary("MoltenVK");
    }

    const run_main_tests = b.addRunArtifact(main_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_regex_tests = b.addRunArtifact(regex_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_regex_tests.step);
}
