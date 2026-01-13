const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");

const SubstituteOptions = gpu.SubstituteOptions;

/// Smoke test results
const TestResult = struct {
    name: []const u8,
    passed: bool,
    cpu_throughput_mbs: f64,
    metal_throughput_mbs: ?f64,
    vulkan_throughput_mbs: ?f64,
    expected_matches: u64,
    cpu_matches: u64,
    metal_matches: ?u64,
    vulkan_matches: ?u64,
};

/// Test case definition
const TestCase = struct {
    name: []const u8,
    pattern: []const u8,
    options: SubstituteOptions,
    data_generator: *const fn (std.mem.Allocator, usize) anyerror![]u8,
    expected_match_ratio: f64, // Expected ratio of matches to total positions
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Default test size: 50MB for thorough testing
    var test_size: usize = 50 * 1024 * 1024;
    var iterations: usize = 3;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--size") and i + 1 < args.len) {
            i += 1;
            test_size = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--iterations") and i + 1 < args.len) {
            i += 1;
            iterations = try std.fmt.parseInt(usize, args[i], 10);
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("                    SED SMOKE TESTS\n", .{});
    std.debug.print("        Testing GPU-accelerated sed substitute operations\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Test data size: {d:.1} MB\n", .{@as(f64, @floatFromInt(test_size)) / (1024 * 1024)});
    std.debug.print("  Iterations:     {d}\n\n", .{iterations});

    const test_cases = [_]TestCase{
        // Test 1: Common word substitution (like s/the/THE/g)
        .{
            .name = "common_word",
            .pattern = "the",
            .options = .{ .global = true },
            .data_generator = generateEnglishText,
            .expected_match_ratio = 0.005,
        },
        // Test 2: Case-insensitive substitution (s/ERROR/error/gi)
        .{
            .name = "case_insensitive",
            .pattern = "ERROR",
            .options = .{ .case_insensitive = true, .global = true },
            .data_generator = generateLogFile,
            .expected_match_ratio = 0.002,
        },
        // Test 3: First-only substitution (s/foo/bar/1)
        .{
            .name = "first_only",
            .pattern = "function",
            .options = .{ .first_only = true },
            .data_generator = generateCodeLikeText,
            .expected_match_ratio = 0.003,
        },
        // Test 4: Single character pattern (s/e/E/g - stress test)
        .{
            .name = "single_char",
            .pattern = "e",
            .options = .{ .global = true },
            .data_generator = generateEnglishText,
            .expected_match_ratio = 0.10,
        },
        // Test 5: Longer pattern (s/performance/PERFORMANCE/g)
        .{
            .name = "long_pattern",
            .pattern = "performance",
            .options = .{ .global = true },
            .data_generator = generateTechText,
            .expected_match_ratio = 0.001,
        },
        // Test 6: Log file pattern (s/WARNING/ALERT/g)
        .{
            .name = "log_warning",
            .pattern = "WARNING",
            .options = .{ .global = true },
            .data_generator = generateLogFile,
            .expected_match_ratio = 0.002,
        },
        // Test 7: Code identifier (s/test/spec/g)
        .{
            .name = "code_identifier",
            .pattern = "test",
            .options = .{ .global = true },
            .data_generator = generateCodeLikeText,
            .expected_match_ratio = 0.003,
        },
        // Test 8: Sparse matches (s/UNIQUE_MARKER_XYZ/REPLACED/g)
        .{
            .name = "sparse_matches",
            .pattern = "UNIQUE_MARKER_XYZ",
            .options = .{ .global = true },
            .data_generator = generateSparseMatchText,
            .expected_match_ratio = 0.0001,
        },
    };

    var results: [test_cases.len]TestResult = undefined;
    var all_passed = true;

    for (test_cases, 0..) |tc, test_idx| {
        std.debug.print("-" ** 70 ++ "\n", .{});
        std.debug.print("Test {d}/{d}: {s}\n", .{ test_idx + 1, test_cases.len, tc.name });
        std.debug.print("  Pattern: \"{s}\" | Options: case_i={}, global={}, first_only={}\n", .{
            tc.pattern,
            tc.options.case_insensitive,
            tc.options.global,
            tc.options.first_only,
        });
        std.debug.print("-" ** 70 ++ "\n", .{});

        const text = try tc.data_generator(allocator, test_size);
        defer allocator.free(text);

        results[test_idx] = try runTest(allocator, tc.name, text, tc.pattern, tc.options, iterations);

        if (!results[test_idx].passed) all_passed = false;

        std.debug.print("  Result: {s}\n\n", .{if (results[test_idx].passed) "PASS" else "FAIL"});
    }

    // Print summary
    std.debug.print("\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("                         RESULTS SUMMARY\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("{s:<20} {s:>10} {s:>12} {s:>12} {s:>12} {s:>8}\n", .{
        "Test Name",
        "Status",
        "CPU (MB/s)",
        "Metal (MB/s)",
        "Vulkan (MB/s)",
        "Speedup",
    });
    std.debug.print("{s:-<20} {s:->10} {s:->12} {s:->12} {s:->12} {s:->8}\n", .{ "", "", "", "", "", "" });

    var max_cpu: f64 = 0;
    var max_metal: f64 = 0;
    var max_vulkan: f64 = 0;

    for (results) |r| {
        const status = if (r.passed) "PASS" else "FAIL";

        if (r.metal_throughput_mbs) |m| max_metal = @max(max_metal, m);
        if (r.vulkan_throughput_mbs) |v| max_vulkan = @max(max_vulkan, v);
        max_cpu = @max(max_cpu, r.cpu_throughput_mbs);

        const best_gpu = @max(r.metal_throughput_mbs orelse 0, r.vulkan_throughput_mbs orelse 0);
        const speedup = if (best_gpu > 0) best_gpu / r.cpu_throughput_mbs else 1.0;

        var metal_buf: [16]u8 = undefined;
        var vulkan_buf: [16]u8 = undefined;
        const metal_formatted = if (r.metal_throughput_mbs) |m|
            std.fmt.bufPrint(&metal_buf, "{d:.1}", .{m}) catch "N/A"
        else
            "N/A";
        const vulkan_formatted = if (r.vulkan_throughput_mbs) |v|
            std.fmt.bufPrint(&vulkan_buf, "{d:.1}", .{v}) catch "N/A"
        else
            "N/A";

        std.debug.print("{s:<20} {s:>10} {d:>12.1} {s:>12} {s:>12} {d:>7.1}x\n", .{
            r.name,
            status,
            r.cpu_throughput_mbs,
            metal_formatted,
            vulkan_formatted,
            speedup,
        });
    }

    std.debug.print("\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("                      MAXIMUM THROUGHPUT\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  CPU:    {d:.1} MB/s ({d:.2} GB/s)\n", .{ max_cpu, max_cpu / 1024 });
    if (max_metal > 0) {
        std.debug.print("  Metal:  {d:.1} MB/s ({d:.2} GB/s) - {d:.1}x CPU\n", .{ max_metal, max_metal / 1024, max_metal / max_cpu });
    }
    if (max_vulkan > 0) {
        std.debug.print("  Vulkan: {d:.1} MB/s ({d:.2} GB/s) - {d:.1}x CPU\n", .{ max_vulkan, max_vulkan / 1024, max_vulkan / max_cpu });
    }
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    if (all_passed) {
        std.debug.print("All smoke tests PASSED!\n\n", .{});
    } else {
        std.debug.print("Some smoke tests FAILED!\n\n", .{});
        std.process.exit(1);
    }
}

fn runTest(allocator: std.mem.Allocator, name: []const u8, text: []const u8, pattern: []const u8, options: SubstituteOptions, iterations: usize) !TestResult {
    var result = TestResult{
        .name = name,
        .passed = true,
        .cpu_throughput_mbs = 0,
        .metal_throughput_mbs = null,
        .vulkan_throughput_mbs = null,
        .expected_matches = 0,
        .cpu_matches = 0,
        .metal_matches = null,
        .vulkan_matches = null,
    };

    // Run CPU benchmark
    std.debug.print("  CPU benchmark...\n", .{});
    const cpu_stats = try benchmarkCpu(allocator, text, pattern, options, iterations);
    result.cpu_throughput_mbs = cpu_stats.throughput_mbs;
    result.cpu_matches = cpu_stats.matches;
    result.expected_matches = cpu_stats.matches;
    std.debug.print("    Throughput: {d:.1} MB/s, Matches: {d}\n", .{ cpu_stats.throughput_mbs, cpu_stats.matches });

    // Run Metal benchmark (macOS only)
    if (build_options.is_macos) {
        std.debug.print("  Metal benchmark...\n", .{});
        if (benchmarkMetal(allocator, text, pattern, options, iterations)) |metal_stats| {
            result.metal_throughput_mbs = metal_stats.throughput_mbs;
            result.metal_matches = metal_stats.matches;
            std.debug.print("    Throughput: {d:.1} MB/s, Matches: {d}\n", .{ metal_stats.throughput_mbs, metal_stats.matches });

            // Verify correctness
            if (metal_stats.matches != result.expected_matches) {
                std.debug.print("    WARNING: Metal match count mismatch! Expected {d}, got {d}\n", .{ result.expected_matches, metal_stats.matches });
                result.passed = false;
            }
        } else |_| {
            std.debug.print("    Metal unavailable\n", .{});
        }
    }

    // Run Vulkan benchmark
    std.debug.print("  Vulkan benchmark...\n", .{});
    if (benchmarkVulkan(allocator, text, pattern, options, iterations)) |vulkan_stats| {
        result.vulkan_throughput_mbs = vulkan_stats.throughput_mbs;
        result.vulkan_matches = vulkan_stats.matches;
        std.debug.print("    Throughput: {d:.1} MB/s, Matches: {d}\n", .{ vulkan_stats.throughput_mbs, vulkan_stats.matches });

        // Verify correctness
        if (vulkan_stats.matches != result.expected_matches) {
            std.debug.print("    WARNING: Vulkan match count mismatch! Expected {d}, got {d}\n", .{ result.expected_matches, vulkan_stats.matches });
            result.passed = false;
        }
    } else |_| {
        std.debug.print("    Vulkan unavailable\n", .{});
    }

    return result;
}

const BenchStats = struct {
    throughput_mbs: f64,
    matches: u64,
};

fn benchmarkCpu(allocator: std.mem.Allocator, text: []const u8, pattern: []const u8, options: SubstituteOptions, iterations: usize) !BenchStats {
    var total_time: i64 = 0;
    var matches: u64 = 0;

    for (0..iterations) |_| {
        const start = std.time.milliTimestamp();
        var result = try cpu.findMatches(text, pattern, options, allocator);
        const elapsed = std.time.milliTimestamp() - start;
        matches = result.total_matches;
        result.deinit();
        total_time += elapsed;
    }

    const avg_time_ms = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    const throughput = @as(f64, @floatFromInt(text.len)) / (avg_time_ms / 1000.0) / (1024 * 1024);

    return BenchStats{ .throughput_mbs = throughput, .matches = matches };
}

fn benchmarkMetal(allocator: std.mem.Allocator, text: []const u8, pattern: []const u8, options: SubstituteOptions, iterations: usize) !BenchStats {
    if (!build_options.is_macos) return error.NotAvailable;

    const substituter = gpu.metal.MetalSubstituter.init(allocator) catch return error.InitFailed;
    defer substituter.deinit();

    var total_time: i64 = 0;
    var matches: u64 = 0;

    for (0..iterations) |_| {
        const start = std.time.milliTimestamp();
        var result = try substituter.findMatches(text, pattern, options, allocator);
        const elapsed = std.time.milliTimestamp() - start;
        matches = result.total_matches;
        result.deinit();
        total_time += elapsed;
    }

    const avg_time_ms = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    const throughput = @as(f64, @floatFromInt(text.len)) / (avg_time_ms / 1000.0) / (1024 * 1024);

    return BenchStats{ .throughput_mbs = throughput, .matches = matches };
}

fn benchmarkVulkan(allocator: std.mem.Allocator, text: []const u8, pattern: []const u8, options: SubstituteOptions, iterations: usize) !BenchStats {
    const substituter = gpu.vulkan.VulkanSubstituter.init(allocator) catch return error.InitFailed;
    defer substituter.deinit();

    var total_time: i64 = 0;
    var matches: u64 = 0;

    for (0..iterations) |_| {
        const start = std.time.milliTimestamp();
        var result = try substituter.findMatches(text, pattern, options, allocator);
        const elapsed = std.time.milliTimestamp() - start;
        matches = result.total_matches;
        result.deinit();
        total_time += elapsed;
    }

    const avg_time_ms = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    const throughput = @as(f64, @floatFromInt(text.len)) / (avg_time_ms / 1000.0) / (1024 * 1024);

    return BenchStats{ .throughput_mbs = throughput, .matches = matches };
}

// Data generators

fn generateEnglishText(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const words = [_][]const u8{
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "I",
        "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
        "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
        "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
        "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
        "when", "make", "can", "like", "time", "no", "just", "him", "know", "take",
        "people", "into", "year", "your", "good", "some", "could", "them", "see", "other",
        "than", "then", "now", "look", "only", "come", "its", "over", "think", "also",
    };
    return generateWordList(allocator, size, &words);
}

fn generateCodeLikeText(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const words = [_][]const u8{
        "function", "const", "let", "var", "if", "else", "for", "while", "return",
        "class", "struct", "enum", "import", "export", "public", "private", "static",
        "void", "int", "string", "bool", "float", "double", "null", "undefined",
        "test", "testing", "tests", "testCase", "testValue", "assertTrue", "assertFalse",
        "error", "warning", "debug", "info", "log", "print", "println", "printf",
        "async", "await", "promise", "callback", "handler", "listener", "event",
    };
    return generateWordList(allocator, size, &words);
}

fn generateTechText(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const words = [_][]const u8{
        "performance", "benchmark", "throughput", "latency", "bandwidth", "memory",
        "optimization", "algorithm", "structure", "data", "process", "thread",
        "parallel", "concurrent", "synchronization", "buffer", "cache", "queue",
        "stack", "heap", "allocation", "deallocation", "garbage", "collection",
        "compiler", "runtime", "execution", "instruction", "register", "cpu", "gpu",
        "shader", "compute", "kernel", "dispatch", "workgroup", "thread", "barrier",
    };
    return generateWordList(allocator, size, &words);
}

fn generateLogFile(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const prefixes = [_][]const u8{
        "[INFO]", "[DEBUG]", "[WARNING]", "[ERROR]", "[TRACE]", "[FATAL]",
    };
    const messages = [_][]const u8{
        "Request received from client",
        "Processing data batch",
        "Connection established",
        "Cache miss for key",
        "Database query executed",
        "File operation completed",
        "Authentication successful",
        "Session expired",
        "Rate limit exceeded",
        "Configuration loaded",
        "Service started on port",
        "Shutting down gracefully",
    };

    var text = try allocator.alloc(u8, size);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    var pos: usize = 0;
    var timestamp: u64 = 1700000000;

    while (pos < size - 100) {
        const ts_str = std.fmt.bufPrint(text[pos..], "{d} ", .{timestamp}) catch break;
        pos += ts_str.len;
        timestamp += random.intRangeAtMost(u64, 1, 1000);

        const prefix = prefixes[random.intRangeAtMost(usize, 0, prefixes.len - 1)];
        if (pos + prefix.len + 1 >= size) break;
        @memcpy(text[pos..][0..prefix.len], prefix);
        pos += prefix.len;
        text[pos] = ' ';
        pos += 1;

        const msg = messages[random.intRangeAtMost(usize, 0, messages.len - 1)];
        if (pos + msg.len + 1 >= size) break;
        @memcpy(text[pos..][0..msg.len], msg);
        pos += msg.len;
        text[pos] = '\n';
        pos += 1;
    }

    @memset(text[pos..], ' ');
    return text;
}

fn generateSparseMatchText(allocator: std.mem.Allocator, size: usize) ![]u8 {
    var text = try allocator.alloc(u8, size);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    for (text) |*c| {
        const r = random.intRangeAtMost(u8, 0, 30);
        if (r < 26) {
            c.* = 'a' + r;
        } else if (r < 29) {
            c.* = ' ';
        } else {
            c.* = '\n';
        }
    }

    const marker = "UNIQUE_MARKER_XYZ";
    const num_markers = @max(1, size / 100000);
    for (0..num_markers) |_| {
        const pos = random.intRangeAtMost(usize, 0, size - marker.len - 1);
        @memcpy(text[pos..][0..marker.len], marker);
    }

    return text;
}

fn generateWordList(allocator: std.mem.Allocator, size: usize, words: []const []const u8) ![]u8 {
    var text = try allocator.alloc(u8, size);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    var pos: usize = 0;
    while (pos < size - 20) {
        const word = words[random.intRangeAtMost(usize, 0, words.len - 1)];
        if (pos + word.len + 1 >= size) break;

        @memcpy(text[pos..][0..word.len], word);
        pos += word.len;

        if (random.intRangeAtMost(u8, 0, 10) == 0) {
            text[pos] = '\n';
        } else {
            text[pos] = ' ';
        }
        pos += 1;
    }

    @memset(text[pos..], ' ');
    return text;
}
