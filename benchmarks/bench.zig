const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");
const cpu_gnu = @import("cpu_gnu");

const SubstituteOptions = gpu.SubstituteOptions;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Default parameters
    var file_size: usize = 10 * 1024 * 1024; // 10MB
    var pattern: []const u8 = "the";
    var iterations: usize = 5;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--size") and i + 1 < args.len) {
            i += 1;
            file_size = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--pattern") and i + 1 < args.len) {
            i += 1;
            pattern = args[i];
        } else if (std.mem.eql(u8, args[i], "--iterations") and i + 1 < args.len) {
            i += 1;
            iterations = try std.fmt.parseInt(usize, args[i], 10);
        }
    }

    std.debug.print("\n====== SED BENCHMARK ======\n\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Data size:   {d:.2} MB\n", .{@as(f64, @floatFromInt(file_size)) / (1024 * 1024)});
    std.debug.print("  Pattern:     \"{s}\"\n", .{pattern});
    std.debug.print("  Iterations:  {d}\n\n", .{iterations});

    // Generate test data (English-like text)
    std.debug.print("Generating test data...\n", .{});
    const text = try generateTestData(allocator, file_size);
    defer allocator.free(text);

    const options = SubstituteOptions{ .global = true };

    // Warm up and count matches
    var warmup_result = try cpu.findMatches(text, pattern, options, allocator);
    const expected_matches = warmup_result.total_matches;
    warmup_result.deinit();
    std.debug.print("Expected matches: {d}\n\n", .{expected_matches});

    // Benchmark CPU (Optimized)
    std.debug.print("Benchmarking CPU (Optimized)...\n", .{});
    const cpu_stats = try benchmarkCpu(allocator, text, pattern, options, iterations);

    // Benchmark CPU (GNU)
    std.debug.print("Benchmarking CPU (GNU)...\n", .{});
    const cpu_gnu_stats = try benchmarkCpuGnu(allocator, text, pattern, options, iterations);

    // Benchmark Metal (macOS only)
    var metal_stats: ?BenchStats = null;
    if (build_options.is_macos) {
        std.debug.print("Benchmarking Metal...\n", .{});
        metal_stats = try benchmarkMetal(allocator, text, pattern, options, iterations);
    }

    // Benchmark Vulkan
    std.debug.print("Benchmarking Vulkan...\n", .{});
    const vulkan_stats = try benchmarkVulkan(allocator, text, pattern, options, iterations);

    // Print results
    std.debug.print("\n====== RESULTS ======\n\n", .{});
    std.debug.print("{s:<12} {s:>12} {s:>12} {s:>12} {s:>10}\n", .{ "Backend", "Avg (ms)", "Min (ms)", "Throughput", "Speedup" });
    std.debug.print("{s:-<12} {s:->12} {s:->12} {s:->12} {s:->10}\n", .{ "", "", "", "", "" });

    printStats("CPU-Optimized", cpu_stats, cpu_stats.avg_time_ms);

    if (cpu_gnu_stats) |stats| {
        printStats("CPU-GNU", stats, cpu_stats.avg_time_ms);
    }

    if (metal_stats) |stats| {
        printStats("Metal", stats, cpu_stats.avg_time_ms);
    }

    if (vulkan_stats) |stats| {
        printStats("Vulkan", stats, cpu_stats.avg_time_ms);
    }

    std.debug.print("\n", .{});

    // Verify correctness
    std.debug.print("====== CORRECTNESS CHECK ======\n\n", .{});
    try verifyCorrectness(allocator, text, pattern, options, expected_matches);
}

const BenchStats = struct {
    avg_time_ms: f64,
    min_time_ms: f64,
    throughput_mbs: f64,
    matches: u64,
};

fn benchmarkCpu(allocator: std.mem.Allocator, text: []const u8, pattern: []const u8, options: SubstituteOptions, iterations: usize) !BenchStats {
    var total_time: i64 = 0;
    var min_time: i64 = std.math.maxInt(i64);
    var matches: u64 = 0;

    for (0..iterations) |_| {
        const start = std.time.milliTimestamp();
        var result = try cpu.findMatches(text, pattern, options, allocator);
        const elapsed = std.time.milliTimestamp() - start;

        matches = result.total_matches;
        result.deinit();

        total_time += elapsed;
        min_time = @min(min_time, elapsed);
    }

    const avg_time_ms = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    const throughput = @as(f64, @floatFromInt(text.len)) / (avg_time_ms / 1000.0) / (1024 * 1024);

    return BenchStats{
        .avg_time_ms = avg_time_ms,
        .min_time_ms = @floatFromInt(min_time),
        .throughput_mbs = throughput,
        .matches = matches,
    };
}

fn benchmarkCpuGnu(allocator: std.mem.Allocator, text: []const u8, pattern: []const u8, options: SubstituteOptions, iterations: usize) !?BenchStats {
    var total_time: i64 = 0;
    var min_time: i64 = std.math.maxInt(i64);
    var matches: u64 = 0;

    for (0..iterations) |_| {
        const start = std.time.milliTimestamp();
        var result = cpu_gnu.findMatches(text, pattern, options, allocator) catch |err| {
            std.debug.print("GNU findMatches failed: {}\n", .{err});
            return null;
        };
        const elapsed = std.time.milliTimestamp() - start;

        matches = result.total_matches;
        result.deinit();

        total_time += elapsed;
        min_time = @min(min_time, elapsed);
    }

    const avg_time_ms = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    const throughput = @as(f64, @floatFromInt(text.len)) / (avg_time_ms / 1000.0) / (1024 * 1024);

    return BenchStats{
        .avg_time_ms = avg_time_ms,
        .min_time_ms = @floatFromInt(min_time),
        .throughput_mbs = throughput,
        .matches = matches,
    };
}

fn benchmarkMetal(allocator: std.mem.Allocator, text: []const u8, pattern: []const u8, options: SubstituteOptions, iterations: usize) !?BenchStats {
    if (!build_options.is_macos) return null;

    const substituter = gpu.metal.MetalSubstituter.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return null;
    };
    defer substituter.deinit();

    var total_time: i64 = 0;
    var min_time: i64 = std.math.maxInt(i64);
    var matches: u64 = 0;

    for (0..iterations) |_| {
        const start = std.time.milliTimestamp();
        var result = try substituter.findMatches(text, pattern, options, allocator);
        const elapsed = std.time.milliTimestamp() - start;

        matches = result.total_matches;
        result.deinit();

        total_time += elapsed;
        min_time = @min(min_time, elapsed);
    }

    const avg_time_ms = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    const throughput = @as(f64, @floatFromInt(text.len)) / (avg_time_ms / 1000.0) / (1024 * 1024);

    return BenchStats{
        .avg_time_ms = avg_time_ms,
        .min_time_ms = @floatFromInt(min_time),
        .throughput_mbs = throughput,
        .matches = matches,
    };
}

fn benchmarkVulkan(allocator: std.mem.Allocator, text: []const u8, pattern: []const u8, options: SubstituteOptions, iterations: usize) !?BenchStats {
    const substituter = gpu.vulkan.VulkanSubstituter.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return null;
    };
    defer substituter.deinit();

    var total_time: i64 = 0;
    var min_time: i64 = std.math.maxInt(i64);
    var matches: u64 = 0;

    for (0..iterations) |_| {
        const start = std.time.milliTimestamp();
        var result = substituter.findMatches(text, pattern, options, allocator) catch |err| {
            std.debug.print("Vulkan findMatches failed: {}\n", .{err});
            return null;
        };
        const elapsed = std.time.milliTimestamp() - start;

        matches = result.total_matches;
        result.deinit();

        total_time += elapsed;
        min_time = @min(min_time, elapsed);
    }

    const avg_time_ms = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    const throughput = @as(f64, @floatFromInt(text.len)) / (avg_time_ms / 1000.0) / (1024 * 1024);

    return BenchStats{
        .avg_time_ms = avg_time_ms,
        .min_time_ms = @floatFromInt(min_time),
        .throughput_mbs = throughput,
        .matches = matches,
    };
}

fn printStats(name: []const u8, stats: BenchStats, cpu_avg: f64) void {
    const speedup = cpu_avg / stats.avg_time_ms;
    std.debug.print("{s:<12} {d:>12.1} {d:>12.1} {d:>9.1} MB/s {d:>9.1}x\n", .{
        name,
        stats.avg_time_ms,
        stats.min_time_ms,
        stats.throughput_mbs,
        speedup,
    });
}

fn verifyCorrectness(allocator: std.mem.Allocator, text: []const u8, pattern: []const u8, options: SubstituteOptions, expected: u64) !void {
    // CPU (Optimized)
    var cpu_result = try cpu.findMatches(text, pattern, options, allocator);
    defer cpu_result.deinit();
    const cpu_ok = cpu_result.total_matches == expected;
    std.debug.print("CPU-Optimized: {d} matches - {s}\n", .{ cpu_result.total_matches, if (cpu_ok) "PASS" else "FAIL" });

    // CPU (GNU)
    if (cpu_gnu.findMatches(text, pattern, options, allocator)) |gnu_res| {
        var gnu_result = gnu_res;
        defer gnu_result.deinit();
        const gnu_ok = gnu_result.total_matches == expected;
        std.debug.print("CPU-GNU:       {d} matches - {s}\n", .{ gnu_result.total_matches, if (gnu_ok) "PASS" else "FAIL" });
    } else |_| {
        std.debug.print("CPU-GNU:       unavailable\n", .{});
    }

    // Metal
    if (build_options.is_macos) {
        if (gpu.metal.MetalSubstituter.init(allocator)) |substituter| {
            defer substituter.deinit();
            var result = try substituter.findMatches(text, pattern, options, allocator);
            defer result.deinit();
            const ok = result.total_matches == expected;
            std.debug.print("Metal:  {d} matches - {s}\n", .{ result.total_matches, if (ok) "PASS" else "FAIL" });
        } else |_| {
            std.debug.print("Metal:  unavailable\n", .{});
        }
    }

    // Vulkan
    if (gpu.vulkan.VulkanSubstituter.init(allocator)) |substituter| {
        defer substituter.deinit();
        var result = try substituter.findMatches(text, pattern, options, allocator);
        defer result.deinit();
        const ok = result.total_matches == expected;
        std.debug.print("Vulkan: {d} matches - {s}\n", .{ result.total_matches, if (ok) "PASS" else "FAIL" });
    } else |_| {
        std.debug.print("Vulkan: unavailable\n", .{});
    }
}

fn generateTestData(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const words = [_][]const u8{
        "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing",
        "hello", "world", "test", "data", "search", "pattern", "match",
        "algorithm", "performance", "benchmark", "gpu", "metal", "vulkan",
    };

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
