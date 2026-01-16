const std = @import("std");
const mtl = @import("zig-metal");
const mod = @import("mod.zig");
const regex_compiler = @import("regex_compiler.zig");
const regex_lib = @import("regex");

const SubstituteConfig = mod.SubstituteConfig;
const MatchResult = mod.MatchResult;
const SubstituteOptions = mod.SubstituteOptions;
const SubstituteResult = mod.SubstituteResult;
const RegexSearchConfig = mod.RegexSearchConfig;
const RegexState = mod.RegexState;
const RegexMatchResult = mod.RegexMatchResult;
const EMBEDDED_METAL_SHADER = mod.EMBEDDED_METAL_SHADER;
const MAX_GPU_BUFFER_SIZE = mod.MAX_GPU_BUFFER_SIZE;
const MAX_RESULTS = mod.MAX_RESULTS;

// Access low-level Metal device methods for memory queries
const DeviceMixin = mtl.gen.MTLDeviceProtocolMixin(mtl.gen.MTLDevice, "MTLDevice");

pub const MetalSubstituter = struct {
    device: mtl.MTLDevice,
    command_queue: mtl.MTLCommandQueue,
    find_pipeline: mtl.MTLComputePipelineState,
    filter_pipeline: mtl.MTLComputePipelineState,
    transliterate_pipeline: mtl.MTLComputePipelineState,
    regex_pipeline: mtl.MTLComputePipelineState,
    allocator: std.mem.Allocator,
    threads_per_group: usize,
    capabilities: mod.GpuCapabilities,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const device = mtl.createSystemDefaultDevice() orelse return error.NoMetalDevice;
        errdefer device.release();

        const command_queue = device.newCommandQueue() orelse return error.CommandQueueCreationFailed;
        errdefer command_queue.release();

        const source_ns = mtl.NSString.stringWithUTF8String(EMBEDDED_METAL_SHADER.ptr);
        const library = device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse return error.ShaderCompilationFailed;
        defer library.release();

        const find_func_name = mtl.NSString.stringWithUTF8String("find_matches");
        const find_func = library.newFunctionWithName(find_func_name) orelse return error.FunctionNotFound;
        defer find_func.release();

        const filter_func_name = mtl.NSString.stringWithUTF8String("filter_lines");
        const filter_func = library.newFunctionWithName(filter_func_name) orelse return error.FunctionNotFound;
        defer filter_func.release();

        const transliterate_func_name = mtl.NSString.stringWithUTF8String("transliterate");
        const transliterate_func = library.newFunctionWithName(transliterate_func_name) orelse return error.FunctionNotFound;
        defer transliterate_func.release();

        const regex_func_name = mtl.NSString.stringWithUTF8String("regex_find_matches");
        const regex_func = library.newFunctionWithName(regex_func_name) orelse return error.FunctionNotFound;
        defer regex_func.release();

        const find_pipeline = device.newComputePipelineStateWithFunctionError(find_func, null) orelse return error.PipelineCreationFailed;
        errdefer find_pipeline.release();

        const filter_pipeline = device.newComputePipelineStateWithFunctionError(filter_func, null) orelse return error.PipelineCreationFailed;
        errdefer filter_pipeline.release();

        const transliterate_pipeline = device.newComputePipelineStateWithFunctionError(transliterate_func, null) orelse return error.PipelineCreationFailed;
        errdefer transliterate_pipeline.release();

        const regex_pipeline = device.newComputePipelineStateWithFunctionError(regex_func, null) orelse return error.PipelineCreationFailed;
        errdefer regex_pipeline.release();

        const threads_per_group = find_pipeline.maxTotalThreadsPerThreadgroup();

        // Query actual memory from Metal API (deterministic, not inferred)
        const recommended_memory = DeviceMixin.recommendedMaxWorkingSetSize(device.ptr);
        const max_buffer_len = DeviceMixin.maxBufferLength(device.ptr);
        const has_unified = DeviceMixin.hasUnifiedMemory(device.ptr) != 0;

        // Apple Silicon with unified memory is high-performance
        const is_high_perf = has_unified and threads_per_group >= 1024;

        // Build capabilities from actual hardware attributes
        const capabilities = mod.GpuCapabilities{
            .max_threads_per_group = @intCast(threads_per_group),
            .max_buffer_size = @min(max_buffer_len, MAX_GPU_BUFFER_SIZE),
            .recommended_memory = recommended_memory,
            .is_discrete = is_high_perf,
            .device_type = if (is_high_perf) .discrete else .integrated,
        };

        const self = try allocator.create(Self);
        self.* = Self{
            .device = device,
            .command_queue = command_queue,
            .find_pipeline = find_pipeline,
            .filter_pipeline = filter_pipeline,
            .transliterate_pipeline = transliterate_pipeline,
            .regex_pipeline = regex_pipeline,
            .allocator = allocator,
            .threads_per_group = threads_per_group,
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.regex_pipeline.release();
        self.transliterate_pipeline.release();
        self.filter_pipeline.release();
        self.find_pipeline.release();
        self.command_queue.release();
        self.device.release();
        self.allocator.destroy(self);
    }

    pub fn findMatches(
        self: *Self,
        text: []const u8,
        pattern: []const u8,
        options: SubstituteOptions,
        allocator: std.mem.Allocator,
    ) !SubstituteResult {
        if (text.len == 0 or pattern.len == 0) {
            return SubstituteResult{
                .matches = &[_]MatchResult{},
                .total_matches = 0,
                .allocator = allocator,
            };
        }

        // Create buffers
        const text_buffer = self.device.newBufferWithLengthOptions(text.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer text_buffer.release();
        if (text_buffer.contents()) |ptr| {
            const text_ptr: [*]u8 = @ptrCast(ptr);
            @memcpy(text_ptr[0..text.len], text);
        }

        const pattern_buffer = self.device.newBufferWithLengthOptions(pattern.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer pattern_buffer.release();
        if (pattern_buffer.contents()) |ptr| {
            const pattern_ptr: [*]u8 = @ptrCast(ptr);
            @memcpy(pattern_ptr[0..pattern.len], pattern);
        }

        // Use chunked processing - each thread handles multiple positions
        // Similar to grep's approach for efficient GPU utilization
        const num_threads: u32 = @intCast(@max(1, text.len / 64));
        const config = SubstituteConfig{
            .text_len = @intCast(text.len),
            .pattern_len = @intCast(pattern.len),
            .replacement_len = 0,
            .flags = options.toFlags(),
            .max_matches = MAX_RESULTS,
            .num_threads = num_threads,
        };
        const config_buffer = self.device.newBufferWithLengthOptions(@sizeOf(SubstituteConfig), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer config_buffer.release();
        if (config_buffer.contents()) |ptr| {
            const config_ptr: *SubstituteConfig = @ptrCast(@alignCast(ptr));
            config_ptr.* = config;
        }

        const results_size = @sizeOf(MatchResult) * MAX_RESULTS;
        const results_buffer = self.device.newBufferWithLengthOptions(results_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer results_buffer.release();

        // Counters: [match_count, total_matches]
        const counters_buffer = self.device.newBufferWithLengthOptions(8, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer counters_buffer.release();
        const counters_ptr: *[2]u32 = @ptrCast(@alignCast(counters_buffer.contents()));
        counters_ptr[0] = 0;
        counters_ptr[1] = 0;

        // Execute
        const command_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferCreationFailed;
        const encoder = command_buffer.computeCommandEncoder() orelse return error.EncoderCreationFailed;

        encoder.setComputePipelineState(self.find_pipeline);
        encoder.setBufferOffsetAtIndex(text_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(pattern_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(config_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(results_buffer, 0, 3);
        encoder.setBufferOffsetAtIndex(counters_buffer, 0, 4);
        encoder.setBufferOffsetAtIndex(counters_buffer, 4, 5);

        const grid_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        const thread_group_size = mtl.MTLSize{ .width = @min(self.threads_per_group, num_threads), .height = 1, .depth = 1 };

        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, thread_group_size);
        encoder.endEncoding();

        command_buffer.commit();
        command_buffer.waitUntilCompleted();

        // Read results
        const match_count = counters_ptr[0];
        var total_matches: u64 = counters_ptr[1];

        const num_to_copy = @min(match_count, MAX_RESULTS);
        var matches = try allocator.alloc(MatchResult, num_to_copy);
        if (num_to_copy > 0) {
            const results_ptr: [*]MatchResult = @ptrCast(@alignCast(results_buffer.contents()));
            @memcpy(matches, results_ptr[0..num_to_copy]);
        }

        // For first_only mode, filter to keep only first match per line
        if (options.first_only and matches.len > 0) {
            // Sort by position to process in order
            std.mem.sort(MatchResult, matches, {}, struct {
                fn cmp(_: void, a: MatchResult, b: MatchResult) bool {
                    return a.start < b.start;
                }
            }.cmp);

            // Compute line numbers efficiently by scanning text once
            var line_num: u32 = 0;
            var text_pos: usize = 0;
            for (matches) |*match| {
                // Count newlines from current position to match position
                while (text_pos < match.start) {
                    if (text[text_pos] == '\n') line_num += 1;
                    text_pos += 1;
                }
                match.line_num = line_num;
            }

            // Filter to first match per line
            var write_idx: usize = 0;
            var last_line_num: u32 = std.math.maxInt(u32);
            for (matches) |match| {
                if (match.line_num != last_line_num) {
                    matches[write_idx] = match;
                    write_idx += 1;
                    last_line_num = match.line_num;
                }
            }
            // Shrink the slice
            matches = try allocator.realloc(matches, write_idx);
            total_matches = write_idx;
        }

        return SubstituteResult{
            .matches = matches,
            .total_matches = total_matches,
            .allocator = allocator,
        };
    }

    /// GPU-accelerated regex pattern matching for sed substitution
    pub fn findMatchesRegex(
        self: *Self,
        text: []const u8,
        pattern: []const u8,
        options: SubstituteOptions,
        allocator: std.mem.Allocator,
    ) !SubstituteResult {
        if (text.len == 0) {
            return SubstituteResult{
                .matches = &[_]MatchResult{},
                .total_matches = 0,
                .allocator = allocator,
            };
        }

        // Compile regex pattern for GPU
        var gpu_regex = try regex_compiler.compileForGpu(pattern, .{
            .case_insensitive = options.case_insensitive,
        }, allocator);
        defer gpu_regex.deinit();

        // Find line boundaries
        var line_offsets: std.ArrayListUnmanaged(u32) = .{};
        defer line_offsets.deinit(allocator);
        var line_lengths: std.ArrayListUnmanaged(u32) = .{};
        defer line_lengths.deinit(allocator);

        var line_start: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '\n') {
                try line_offsets.append(allocator, @intCast(line_start));
                try line_lengths.append(allocator, @intCast(i - line_start));
                line_start = i + 1;
            }
        }
        if (line_start < text.len) {
            try line_offsets.append(allocator, @intCast(line_start));
            try line_lengths.append(allocator, @intCast(text.len - line_start));
        }

        const num_lines = line_offsets.items.len;
        if (num_lines == 0) {
            return SubstituteResult{
                .matches = &[_]MatchResult{},
                .total_matches = 0,
                .allocator = allocator,
            };
        }

        // Create text buffer
        var text_buffer = self.device.newBufferWithLengthOptions(text.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer text_buffer.release();
        if (text_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..text.len], text);
        }

        // Create states buffer
        const states_size = gpu_regex.states.len * @sizeOf(RegexState);
        var states_buffer = self.device.newBufferWithLengthOptions(@max(states_size, 1), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer states_buffer.release();
        if (states_size > 0) {
            if (states_buffer.contents()) |ptr| {
                const dst: [*]RegexState = @ptrCast(@alignCast(ptr));
                @memcpy(dst[0..gpu_regex.states.len], gpu_regex.states);
            }
        }

        // Create bitmaps buffer
        const bitmaps_size = gpu_regex.bitmaps.len * @sizeOf(u32);
        var bitmaps_buffer = self.device.newBufferWithLengthOptions(@max(bitmaps_size, 4), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer bitmaps_buffer.release();
        if (bitmaps_size > 0) {
            if (bitmaps_buffer.contents()) |ptr| {
                const dst: [*]u32 = @ptrCast(@alignCast(ptr));
                @memcpy(dst[0..gpu_regex.bitmaps.len], gpu_regex.bitmaps);
            }
        }

        // Create config buffer
        const config = RegexSearchConfig{
            .text_len = @intCast(text.len),
            .num_states = gpu_regex.header.num_states,
            .start_state = gpu_regex.header.start_state,
            .header_flags = gpu_regex.header.flags,
            .num_bitmaps = @intCast(gpu_regex.bitmaps.len / 8),
            .max_results = MAX_RESULTS,
            .flags = options.toFlags(),
        };
        var config_buffer = self.device.newBufferWithLengthOptions(@sizeOf(RegexSearchConfig), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer config_buffer.release();
        if (config_buffer.contents()) |ptr| {
            @as(*RegexSearchConfig, @ptrCast(@alignCast(ptr))).* = config;
        }

        // Create header buffer
        var header_buffer = self.device.newBufferWithLengthOptions(@sizeOf(mod.RegexHeader), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer header_buffer.release();
        if (header_buffer.contents()) |ptr| {
            @as(*mod.RegexHeader, @ptrCast(@alignCast(ptr))).* = gpu_regex.header;
        }

        // Create results buffer
        const results_size = @sizeOf(RegexMatchResult) * MAX_RESULTS;
        var results_buffer = self.device.newBufferWithLengthOptions(results_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer results_buffer.release();

        // Create counters buffer
        var counters_buffer = self.device.newBufferWithLengthOptions(8, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer counters_buffer.release();
        const counters_ptr: *[2]u32 = @ptrCast(@alignCast(counters_buffer.contents()));
        counters_ptr[0] = 0;
        counters_ptr[1] = 0;

        // Create line offsets/lengths buffers
        var line_offsets_buffer = self.device.newBufferWithLengthOptions(line_offsets.items.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer line_offsets_buffer.release();
        if (line_offsets_buffer.contents()) |ptr| {
            @memcpy(@as([*]u32, @ptrCast(@alignCast(ptr)))[0..line_offsets.items.len], line_offsets.items);
        }

        var line_lengths_buffer = self.device.newBufferWithLengthOptions(line_lengths.items.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer line_lengths_buffer.release();
        if (line_lengths_buffer.contents()) |ptr| {
            @memcpy(@as([*]u32, @ptrCast(@alignCast(ptr)))[0..line_lengths.items.len], line_lengths.items);
        }

        // Execute regex matching
        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferCreationFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderCreationFailed;

        encoder.setComputePipelineState(self.regex_pipeline);
        encoder.setBufferOffsetAtIndex(text_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(states_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(bitmaps_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(config_buffer, 0, 3);
        encoder.setBufferOffsetAtIndex(header_buffer, 0, 4);
        encoder.setBufferOffsetAtIndex(results_buffer, 0, 5);
        encoder.setBufferOffsetAtIndex(counters_buffer, 0, 6);
        encoder.setBufferOffsetAtIndex(counters_buffer, 4, 7);
        encoder.setBufferOffsetAtIndex(line_offsets_buffer, 0, 8);
        encoder.setBufferOffsetAtIndex(line_lengths_buffer, 0, 9);

        const grid_size = mtl.MTLSize{ .width = num_lines, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = @min(self.threads_per_group, num_lines), .height = 1, .depth = 1 };

        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        const result_count = counters_ptr[0];
        var total_matches: u64 = counters_ptr[1];

        // Copy results and convert RegexMatchResult to MatchResult
        const num_to_copy = @min(result_count, MAX_RESULTS);
        var matches = try allocator.alloc(MatchResult, num_to_copy);

        if (num_to_copy > 0) {
            const regex_results_ptr: [*]RegexMatchResult = @ptrCast(@alignCast(results_buffer.contents()));
            for (0..num_to_copy) |i| {
                const r = regex_results_ptr[i];
                matches[i] = MatchResult{
                    .start = r.start,
                    .end = r.end,
                    .line_num = 0, // Computed on host side if needed
                };
            }
        }

        // For first_only mode (non-global), filter to keep only first match per line
        if (!options.global and matches.len > 0) {
            std.mem.sort(MatchResult, matches, {}, struct {
                fn cmp(_: void, a: MatchResult, b: MatchResult) bool {
                    return a.start < b.start;
                }
            }.cmp);

            var line_num: u32 = 0;
            var text_pos: usize = 0;
            for (matches) |*match| {
                while (text_pos < match.start) {
                    if (text[text_pos] == '\n') line_num += 1;
                    text_pos += 1;
                }
                match.line_num = line_num;
            }

            var write_idx: usize = 0;
            var last_line_num: u32 = std.math.maxInt(u32);
            for (matches) |match| {
                if (match.line_num != last_line_num) {
                    matches[write_idx] = match;
                    write_idx += 1;
                    last_line_num = match.line_num;
                }
            }
            matches = try allocator.realloc(matches, write_idx);
            total_matches = write_idx;
        }

        return SubstituteResult{
            .matches = matches,
            .total_matches = total_matches,
            .allocator = allocator,
        };
    }

    pub fn getCapabilities(self: *Self) mod.GpuCapabilities {
        return self.capabilities;
    }
};
