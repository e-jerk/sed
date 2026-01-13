const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");

const SubstituteOptions = gpu.SubstituteOptions;

// ============================================================================
// Unit Tests for sed
// Tests basic functionality with small inputs to verify correctness
// ============================================================================

// ----------------------------------------------------------------------------
// CPU Tests
// ----------------------------------------------------------------------------

test "cpu: simple pattern match" {
    const allocator = std.testing.allocator;
    const text = "hello world hello";
    const pattern = "hello";

    // Use global=true to find all matches (not just first per line)
    var result = try cpu.findMatches(text, pattern, .{ .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
    try std.testing.expectEqual(@as(u32, 0), result.matches[0].start);
    try std.testing.expectEqual(@as(u32, 12), result.matches[1].start);
}

test "cpu: case insensitive match" {
    const allocator = std.testing.allocator;
    const text = "Hello HELLO hello HeLLo";
    const pattern = "hello";

    var result = try cpu.findMatches(text, pattern, .{ .case_insensitive = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 4), result.total_matches);
}

test "cpu: no matches" {
    const allocator = std.testing.allocator;
    const text = "hello world";
    const pattern = "xyz";

    var result = try cpu.findMatches(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 0), result.total_matches);
}

test "cpu: empty pattern" {
    const allocator = std.testing.allocator;
    const text = "hello";
    const pattern = "";

    var result = try cpu.findMatches(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 0), result.total_matches);
}

test "cpu: pattern longer than text" {
    const allocator = std.testing.allocator;
    const text = "hi";
    const pattern = "hello";

    var result = try cpu.findMatches(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 0), result.total_matches);
}

test "cpu: single character pattern" {
    const allocator = std.testing.allocator;
    const text = "aaa";
    const pattern = "a";

    var result = try cpu.findMatches(text, pattern, .{ .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "cpu: overlapping potential matches" {
    const allocator = std.testing.allocator;
    const text = "aaaa";
    const pattern = "aa";

    // Note: Boyer-Moore-Horspool doesn't find overlapping matches by default
    // Each match advances by at least 1, so we get positions 0, 1, 2
    var result = try cpu.findMatches(text, pattern, .{ .global = true }, allocator);
    defer result.deinit();

    try std.testing.expect(result.total_matches >= 2);
}

test "cpu: multiline text" {
    const allocator = std.testing.allocator;
    const text = "line1 the\nline2 the\nline3 the";
    const pattern = "the";

    var result = try cpu.findMatches(text, pattern, .{ .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "cpu: first_only mode" {
    const allocator = std.testing.allocator;
    const text = "the the the\nthe the";
    const pattern = "the";

    var result = try cpu.findMatches(text, pattern, .{ .first_only = true }, allocator);
    defer result.deinit();

    // Should get first match per line: 2 lines = 2 matches
    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "cpu: anchor start" {
    const allocator = std.testing.allocator;
    const text = "hello world\nhello there";
    const pattern = "hello";

    var result = try cpu.findMatches(text, pattern, .{ .anchor_start = true }, allocator);
    defer result.deinit();

    // Should only match at start of each line
    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

// ----------------------------------------------------------------------------
// Metal GPU Tests (macOS only)
// ----------------------------------------------------------------------------

test "metal: shader compilation" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // This tests that the shader compiles without errors
    const searcher = gpu.metal.MetalSubstituter.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    // If we get here, shader compiled successfully
}

test "metal: simple pattern match" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const searcher = gpu.metal.MetalSubstituter.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    const text = "hello world hello";
    const pattern = "hello";

    var result = try searcher.findMatches(text, pattern, .{ .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "metal: matches cpu results" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const searcher = gpu.metal.MetalSubstituter.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    // Test various patterns - all with global=true to find all matches
    const test_cases = [_]struct {
        text: []const u8,
        pattern: []const u8,
        options: SubstituteOptions,
    }{
        .{ .text = "the cat sat on the mat", .pattern = "the", .options = .{ .global = true } },
        .{ .text = "Hello HELLO hello", .pattern = "hello", .options = .{ .case_insensitive = true, .global = true } },
        .{ .text = "abcabc", .pattern = "abc", .options = .{ .global = true } },
        .{ .text = "line1\nline2\nline3", .pattern = "line", .options = .{ .global = true } },
    };

    for (test_cases) |tc| {
        var cpu_result = try cpu.findMatches(tc.text, tc.pattern, tc.options, allocator);
        defer cpu_result.deinit();

        var metal_result = try searcher.findMatches(tc.text, tc.pattern, tc.options, allocator);
        defer metal_result.deinit();

        if (cpu_result.total_matches != metal_result.total_matches) {
            std.debug.print("\nMismatch for pattern '{s}' in '{s}':\n", .{ tc.pattern, tc.text });
            std.debug.print("  CPU: {d}, Metal: {d}\n", .{ cpu_result.total_matches, metal_result.total_matches });
            return error.MatchCountMismatch;
        }
    }
}

// ----------------------------------------------------------------------------
// Vulkan GPU Tests
// ----------------------------------------------------------------------------

test "vulkan: shader compilation" {
    const allocator = std.testing.allocator;

    // This tests that the SPIR-V shader loads without errors
    const searcher = gpu.vulkan.VulkanSubstituter.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    // If we get here, shader loaded successfully
}

test "vulkan: simple pattern match" {
    const allocator = std.testing.allocator;

    const searcher = gpu.vulkan.VulkanSubstituter.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    const text = "hello world hello";
    const pattern = "hello";

    var result = try searcher.findMatches(text, pattern, .{ .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "vulkan: matches cpu results" {
    const allocator = std.testing.allocator;

    const searcher = gpu.vulkan.VulkanSubstituter.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    // Test various patterns - all with global=true to find all matches
    const test_cases = [_]struct {
        text: []const u8,
        pattern: []const u8,
        options: SubstituteOptions,
    }{
        .{ .text = "the cat sat on the mat", .pattern = "the", .options = .{ .global = true } },
        .{ .text = "Hello HELLO hello", .pattern = "hello", .options = .{ .case_insensitive = true, .global = true } },
        .{ .text = "abcabc", .pattern = "abc", .options = .{ .global = true } },
        .{ .text = "line1\nline2\nline3", .pattern = "line", .options = .{ .global = true } },
    };

    for (test_cases) |tc| {
        var cpu_result = try cpu.findMatches(tc.text, tc.pattern, tc.options, allocator);
        defer cpu_result.deinit();

        var vulkan_result = try searcher.findMatches(tc.text, tc.pattern, tc.options, allocator);
        defer vulkan_result.deinit();

        if (cpu_result.total_matches != vulkan_result.total_matches) {
            std.debug.print("\nMismatch for pattern '{s}' in '{s}':\n", .{ tc.pattern, tc.text });
            std.debug.print("  CPU: {d}, Vulkan: {d}\n", .{ cpu_result.total_matches, vulkan_result.total_matches });
            return error.MatchCountMismatch;
        }
    }
}
