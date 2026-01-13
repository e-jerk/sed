const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const spirv = @import("spirv");
const mod = @import("mod.zig");

const SubstituteConfig = mod.SubstituteConfig;
const MatchResult = mod.MatchResult;
const SubstituteOptions = mod.SubstituteOptions;
const SubstituteResult = mod.SubstituteResult;
const MAX_GPU_BUFFER_SIZE = mod.MAX_GPU_BUFFER_SIZE;
const MAX_RESULTS = mod.MAX_RESULTS;

const VulkanLoader = struct {
    lib: std.DynLib,
    getProcAddr: vk.PfnGetInstanceProcAddr,

    fn load() !VulkanLoader {
        const lib_names = switch (builtin.os.tag) {
            .macos => &[_][]const u8{ "libMoltenVK.dylib", "libvulkan.1.dylib", "libvulkan.dylib" },
            .linux => &[_][]const u8{ "libvulkan.so.1", "libvulkan.so" },
            .windows => &[_][]const u8{"vulkan-1.dll"},
            else => return error.UnsupportedPlatform,
        };

        for (lib_names) |name| {
            var lib = std.DynLib.open(name) catch continue;
            if (lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr")) |proc| {
                return .{ .lib = lib, .getProcAddr = proc };
            }
            lib.close();
        }
        return error.VulkanNotFound;
    }
};

var vulkan_loader: ?VulkanLoader = null;

fn getVkGetInstanceProcAddr() !vk.PfnGetInstanceProcAddr {
    if (vulkan_loader) |loader| return loader.getProcAddr;
    vulkan_loader = try VulkanLoader.load();
    return vulkan_loader.?.getProcAddr;
}

pub const VulkanSubstituter = struct {
    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    compute_queue: vk.Queue,
    compute_queue_family: u32,
    descriptor_set_layout: vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,
    compute_pipeline: vk.Pipeline,
    descriptor_pool: vk.DescriptorPool,
    shader_module: vk.ShaderModule,
    command_pool: vk.CommandPool,
    fence: vk.Fence,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    allocator: std.mem.Allocator,
    vkb: vk.BaseWrapper,
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    capabilities: mod.GpuCapabilities,

    const Self = @This();
    const BufferAllocation = struct { buffer: vk.Buffer, memory: vk.DeviceMemory, size: vk.DeviceSize, mapped: ?*anyopaque };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const vkb = vk.BaseWrapper.load(try getVkGetInstanceProcAddr());

        const app_info = vk.ApplicationInfo{
            .p_application_name = "sed",
            .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .p_engine_name = "sed",
            .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_2),
        };

        const instance = vkb.createInstance(&.{ .p_application_info = &app_info, .enabled_layer_count = 0, .pp_enabled_layer_names = null, .enabled_extension_count = 0, .pp_enabled_extension_names = null }, null) catch return error.InstanceCreationFailed;
        const vki = vk.InstanceWrapper.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);
        errdefer vki.destroyInstance(instance, null);

        var device_count: u32 = 0;
        _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);
        if (device_count == 0) return error.NoVulkanDevice;

        var physical_devices: [16]vk.PhysicalDevice = undefined;
        device_count = @min(device_count, 16);
        _ = try vki.enumeratePhysicalDevices(instance, &device_count, &physical_devices);

        var selected_device: ?vk.PhysicalDevice = null;
        var selected_queue_family: u32 = 0;
        var selected_props: vk.PhysicalDeviceProperties = undefined;

        for (physical_devices[0..device_count]) |pdev| {
            const props = vki.getPhysicalDeviceProperties(pdev);

            var queue_count: u32 = 0;
            vki.getPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, null);
            var queue_props: [32]vk.QueueFamilyProperties = undefined;
            queue_count = @min(queue_count, 32);
            vki.getPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, &queue_props);

            for (queue_props[0..queue_count], 0..) |qp, i| {
                if (qp.queue_flags.compute_bit) {
                    if (selected_device == null or
                        (props.device_type == .discrete_gpu and selected_props.device_type != .discrete_gpu))
                    {
                        selected_device = pdev;
                        selected_queue_family = @intCast(i);
                        selected_props = props;
                    }
                    break;
                }
            }
        }

        const physical_device = selected_device orelse return error.NoComputeQueue;

        const queue_priority: f32 = 1.0;
        const device = vki.createDevice(physical_device, &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&vk.DeviceQueueCreateInfo{ .queue_family_index = selected_queue_family, .queue_count = 1, .p_queue_priorities = @ptrCast(&queue_priority) }),
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
            .enabled_extension_count = 0,
            .pp_enabled_extension_names = null,
            .p_enabled_features = null,
        }, null) catch return error.DeviceCreationFailed;

        const vkd = vk.DeviceWrapper.load(device, vki.dispatch.vkGetDeviceProcAddr.?);
        errdefer vkd.destroyDevice(device, null);

        const compute_queue = vkd.getDeviceQueue(device, selected_queue_family, 0);

        const shader_module = vkd.createShaderModule(device, &.{ .code_size = spirv.EMBEDDED_SPIRV.len, .p_code = @ptrCast(@alignCast(spirv.EMBEDDED_SPIRV.ptr)) }, null) catch return error.ShaderModuleCreationFailed;
        errdefer vkd.destroyShaderModule(device, shader_module, null);

        // 8 bindings: config, text, pattern, results, counters, line_matches, line_offsets, line_lengths
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .uniform_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 3, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 4, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 5, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 6, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 7, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        };

        const descriptor_set_layout = vkd.createDescriptorSetLayout(device, &.{ .binding_count = bindings.len, .p_bindings = &bindings }, null) catch return error.DescriptorSetLayoutCreationFailed;
        errdefer vkd.destroyDescriptorSetLayout(device, descriptor_set_layout, null);

        const pipeline_layout = vkd.createPipelineLayout(device, &.{ .set_layout_count = 1, .p_set_layouts = @ptrCast(&descriptor_set_layout), .push_constant_range_count = 0, .p_push_constant_ranges = null }, null) catch return error.PipelineLayoutCreationFailed;
        errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

        var compute_pipeline: vk.Pipeline = undefined;
        _ = vkd.createComputePipelines(device, .null_handle, 1, @ptrCast(&vk.ComputePipelineCreateInfo{
            .stage = .{ .stage = .{ .compute_bit = true }, .module = shader_module, .p_name = "main", .p_specialization_info = null },
            .layout = pipeline_layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }), null, @ptrCast(&compute_pipeline)) catch return error.ComputePipelineCreationFailed;
        errdefer vkd.destroyPipeline(device, compute_pipeline, null);

        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{ .type = .uniform_buffer, .descriptor_count = 1 },
            .{ .type = .storage_buffer, .descriptor_count = 7 },
        };
        const descriptor_pool = vkd.createDescriptorPool(device, &.{ .max_sets = 1, .pool_size_count = 2, .p_pool_sizes = &pool_sizes }, null) catch return error.DescriptorPoolCreationFailed;
        errdefer vkd.destroyDescriptorPool(device, descriptor_pool, null);

        const command_pool = vkd.createCommandPool(device, &.{ .queue_family_index = selected_queue_family, .flags = .{ .reset_command_buffer_bit = true } }, null) catch return error.CommandPoolCreationFailed;
        errdefer vkd.destroyCommandPool(device, command_pool, null);

        const fence = vkd.createFence(device, &.{ .flags = .{} }, null) catch return error.FenceCreationFailed;
        errdefer vkd.destroyFence(device, fence, null);

        const mem_props = vki.getPhysicalDeviceMemoryProperties(physical_device);

        const is_discrete = selected_props.device_type == .discrete_gpu;
        const device_type: mod.GpuCapabilities.DeviceType = switch (selected_props.device_type) {
            .discrete_gpu => .discrete,
            .integrated_gpu => .integrated,
            .virtual_gpu => .virtual,
            .cpu => .cpu,
            else => .other,
        };

        const max_threads = selected_props.limits.max_compute_work_group_invocations;
        const max_buffer = selected_props.limits.max_storage_buffer_range;

        var device_local_memory: u64 = 0;
        for (0..mem_props.memory_heap_count) |i| {
            const heap = mem_props.memory_heaps[i];
            if (heap.flags.device_local_bit) {
                device_local_memory += heap.size;
            }
        }

        const capabilities = mod.GpuCapabilities{
            .max_threads_per_group = max_threads,
            .max_buffer_size = max_buffer,
            .recommended_memory = device_local_memory,
            .is_discrete = is_discrete,
            .device_type = device_type,
        };

        const self = try allocator.create(Self);
        self.* = Self{
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .compute_queue = compute_queue,
            .compute_queue_family = selected_queue_family,
            .descriptor_set_layout = descriptor_set_layout,
            .pipeline_layout = pipeline_layout,
            .compute_pipeline = compute_pipeline,
            .descriptor_pool = descriptor_pool,
            .shader_module = shader_module,
            .command_pool = command_pool,
            .fence = fence,
            .mem_props = mem_props,
            .allocator = allocator,
            .vkb = vkb,
            .vki = vki,
            .vkd = vkd,
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.vkd.destroyFence(self.device, self.fence, null);
        self.vkd.destroyCommandPool(self.device, self.command_pool, null);
        self.vkd.destroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.vkd.destroyPipeline(self.device, self.compute_pipeline, null);
        self.vkd.destroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.vkd.destroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        self.vkd.destroyShaderModule(self.device, self.shader_module, null);
        self.vkd.destroyDevice(self.device, null);
        self.vki.destroyInstance(self.instance, null);
        self.allocator.destroy(self);
    }

    fn createStorageBuffer(self: *Self, size: vk.DeviceSize) !BufferAllocation {
        const buffer = self.vkd.createBuffer(self.device, &.{ .size = size, .usage = .{ .storage_buffer_bit = true }, .sharing_mode = .exclusive, .queue_family_index_count = 0, .p_queue_family_indices = null }, null) catch return error.BufferCreationFailed;
        const mem_reqs = self.vkd.getBufferMemoryRequirements(self.device, buffer);
        const mem_type_index = findMemoryType(&self.mem_props, mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }) orelse return error.NoSuitableMemoryType;
        const memory = self.vkd.allocateMemory(self.device, &.{ .allocation_size = mem_reqs.size, .memory_type_index = mem_type_index }, null) catch return error.MemoryAllocationFailed;
        self.vkd.bindBufferMemory(self.device, buffer, memory, 0) catch return error.MemoryBindFailed;
        const mapped = self.vkd.mapMemory(self.device, memory, 0, size, .{}) catch return error.MemoryMapFailed;
        return BufferAllocation{ .buffer = buffer, .memory = memory, .size = size, .mapped = mapped };
    }

    fn createUniformBuffer(self: *Self, size: vk.DeviceSize) !BufferAllocation {
        const buffer = self.vkd.createBuffer(self.device, &.{ .size = size, .usage = .{ .uniform_buffer_bit = true }, .sharing_mode = .exclusive, .queue_family_index_count = 0, .p_queue_family_indices = null }, null) catch return error.BufferCreationFailed;
        const mem_reqs = self.vkd.getBufferMemoryRequirements(self.device, buffer);
        const mem_type_index = findMemoryType(&self.mem_props, mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }) orelse return error.NoSuitableMemoryType;
        const memory = self.vkd.allocateMemory(self.device, &.{ .allocation_size = mem_reqs.size, .memory_type_index = mem_type_index }, null) catch return error.MemoryAllocationFailed;
        self.vkd.bindBufferMemory(self.device, buffer, memory, 0) catch return error.MemoryBindFailed;
        const mapped = self.vkd.mapMemory(self.device, memory, 0, size, .{}) catch return error.MemoryMapFailed;
        return BufferAllocation{ .buffer = buffer, .memory = memory, .size = size, .mapped = mapped };
    }

    fn destroyBuffer(self: *Self, buf: BufferAllocation) void {
        self.vkd.unmapMemory(self.device, buf.memory);
        self.vkd.freeMemory(self.device, buf.memory, null);
        self.vkd.destroyBuffer(self.device, buf.buffer, null);
    }

    pub fn findMatches(self: *Self, text: []const u8, pattern: []const u8, options: SubstituteOptions, result_allocator: std.mem.Allocator) !SubstituteResult {
        if (text.len == 0 or pattern.len == 0) return SubstituteResult{ .matches = &[_]MatchResult{}, .total_matches = 0, .allocator = result_allocator };
        if (text.len > MAX_GPU_BUFFER_SIZE) return error.TextTooLarge;

        // Create buffers
        const config_buffer = try self.createUniformBuffer(@sizeOf(SubstituteConfig));
        defer self.destroyBuffer(config_buffer);

        const text_size: vk.DeviceSize = @intCast(((text.len + 3) / 4) * 4);
        const text_buffer = try self.createStorageBuffer(@max(text_size, 4));
        defer self.destroyBuffer(text_buffer);

        const pattern_size: vk.DeviceSize = @intCast(((pattern.len + 3) / 4) * 4);
        const pattern_buffer = try self.createStorageBuffer(@max(pattern_size, 4));
        defer self.destroyBuffer(pattern_buffer);

        const results_size: vk.DeviceSize = @intCast(@sizeOf(MatchResult) * MAX_RESULTS);
        const results_buffer = try self.createStorageBuffer(results_size);
        defer self.destroyBuffer(results_buffer);

        const counters_buffer = try self.createStorageBuffer(8);
        defer self.destroyBuffer(counters_buffer);

        // Placeholder buffers for line-mode operations
        const placeholder_buffer = try self.createStorageBuffer(4);
        defer self.destroyBuffer(placeholder_buffer);

        // Copy data
        @memcpy(@as([*]u8, @ptrCast(text_buffer.mapped))[0..text.len], text);
        @memcpy(@as([*]u8, @ptrCast(pattern_buffer.mapped))[0..pattern.len], pattern);

        @as(*SubstituteConfig, @ptrCast(@alignCast(config_buffer.mapped))).* = SubstituteConfig{
            .text_len = @intCast(text.len),
            .pattern_len = @intCast(pattern.len),
            .replacement_len = 0,
            .flags = options.toFlags(),
            .max_matches = MAX_RESULTS,
            .num_threads = 0,
        };

        // Clear counters
        @as(*[2]u32, @ptrCast(@alignCast(counters_buffer.mapped))).* = .{ 0, 0 };

        // Setup descriptor set
        var descriptor_set: vk.DescriptorSet = undefined;
        self.vkd.allocateDescriptorSets(self.device, &.{ .descriptor_pool = self.descriptor_pool, .descriptor_set_count = 1, .p_set_layouts = @ptrCast(&self.descriptor_set_layout) }, @ptrCast(&descriptor_set)) catch return error.DescriptorSetAllocationFailed;

        const buffer_infos = [_]vk.DescriptorBufferInfo{
            .{ .buffer = config_buffer.buffer, .offset = 0, .range = @sizeOf(SubstituteConfig) },
            .{ .buffer = text_buffer.buffer, .offset = 0, .range = @max(text_size, 4) },
            .{ .buffer = pattern_buffer.buffer, .offset = 0, .range = @max(pattern_size, 4) },
            .{ .buffer = results_buffer.buffer, .offset = 0, .range = results_size },
            .{ .buffer = counters_buffer.buffer, .offset = 0, .range = 8 },
            .{ .buffer = placeholder_buffer.buffer, .offset = 0, .range = 4 },
            .{ .buffer = placeholder_buffer.buffer, .offset = 0, .range = 4 },
            .{ .buffer = placeholder_buffer.buffer, .offset = 0, .range = 4 },
        };

        const writes = [_]vk.WriteDescriptorSet{
            .{ .dst_set = descriptor_set, .dst_binding = 0, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .uniform_buffer, .p_image_info = undefined, .p_buffer_info = @ptrCast(&buffer_infos[0]), .p_texel_buffer_view = undefined },
            .{ .dst_set = descriptor_set, .dst_binding = 1, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = undefined, .p_buffer_info = @ptrCast(&buffer_infos[1]), .p_texel_buffer_view = undefined },
            .{ .dst_set = descriptor_set, .dst_binding = 2, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = undefined, .p_buffer_info = @ptrCast(&buffer_infos[2]), .p_texel_buffer_view = undefined },
            .{ .dst_set = descriptor_set, .dst_binding = 3, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = undefined, .p_buffer_info = @ptrCast(&buffer_infos[3]), .p_texel_buffer_view = undefined },
            .{ .dst_set = descriptor_set, .dst_binding = 4, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = undefined, .p_buffer_info = @ptrCast(&buffer_infos[4]), .p_texel_buffer_view = undefined },
            .{ .dst_set = descriptor_set, .dst_binding = 5, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = undefined, .p_buffer_info = @ptrCast(&buffer_infos[5]), .p_texel_buffer_view = undefined },
            .{ .dst_set = descriptor_set, .dst_binding = 6, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = undefined, .p_buffer_info = @ptrCast(&buffer_infos[6]), .p_texel_buffer_view = undefined },
            .{ .dst_set = descriptor_set, .dst_binding = 7, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = undefined, .p_buffer_info = @ptrCast(&buffer_infos[7]), .p_texel_buffer_view = undefined },
        };
        self.vkd.updateDescriptorSets(self.device, 8, &writes, 0, undefined);

        // Record and submit
        var command_buffer: vk.CommandBuffer = undefined;
        self.vkd.allocateCommandBuffers(self.device, &.{ .command_pool = self.command_pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&command_buffer)) catch return error.CommandBufferAllocationFailed;
        defer self.vkd.freeCommandBuffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));

        self.vkd.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } }) catch return error.CommandBufferBeginFailed;
        self.vkd.cmdBindPipeline(command_buffer, .compute, self.compute_pipeline);
        self.vkd.cmdBindDescriptorSets(command_buffer, .compute, self.pipeline_layout, 0, 1, @ptrCast(&descriptor_set), 0, undefined);

        // Use chunked processing - dispatch fewer workgroups for efficiency
        // Each thread handles multiple positions (similar to Metal approach)
        const total_threads = @max(1, text.len / 64);
        const workgroups = @max(1, (total_threads + 255) / 256);
        self.vkd.cmdDispatch(command_buffer, @intCast(workgroups), 1, 1);
        self.vkd.endCommandBuffer(command_buffer) catch return error.CommandBufferEndFailed;

        self.vkd.queueSubmit(self.compute_queue, 1, @ptrCast(&vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        }), self.fence) catch return error.QueueSubmitFailed;
        _ = self.vkd.waitForFences(self.device, 1, @ptrCast(&self.fence), .true, std.math.maxInt(u64)) catch return error.FenceWaitFailed;
        self.vkd.resetFences(self.device, 1, @ptrCast(&self.fence)) catch return error.FenceResetFailed;

        // Read results
        const counters_ptr: *[2]u32 = @ptrCast(@alignCast(counters_buffer.mapped));
        const match_count = counters_ptr[0];
        var total_matches: u64 = counters_ptr[1];

        const num_to_copy = @min(match_count, MAX_RESULTS);
        var matches = try result_allocator.alloc(MatchResult, num_to_copy);
        if (num_to_copy > 0) {
            @memcpy(matches, @as([*]MatchResult, @ptrCast(@alignCast(results_buffer.mapped)))[0..num_to_copy]);
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
            matches = try result_allocator.realloc(matches, write_idx);
            total_matches = write_idx;
        }

        self.vkd.resetDescriptorPool(self.device, self.descriptor_pool, .{}) catch {};
        return SubstituteResult{ .matches = matches, .total_matches = total_matches, .allocator = result_allocator };
    }

    pub fn getCapabilities(self: *Self) mod.GpuCapabilities {
        return self.capabilities;
    }
};

fn findMemoryType(mem_props: *const vk.PhysicalDeviceMemoryProperties, type_filter: u32, properties: vk.MemoryPropertyFlags) ?u32 {
    for (0..mem_props.memory_type_count) |i| {
        const idx: u5 = @intCast(i);
        if ((type_filter & (@as(u32, 1) << idx)) != 0) {
            const mem_type = mem_props.memory_types[i];
            if (mem_type.property_flags.host_visible_bit == properties.host_visible_bit and mem_type.property_flags.host_coherent_bit == properties.host_coherent_bit) return @intCast(i);
        }
    }
    return null;
}
