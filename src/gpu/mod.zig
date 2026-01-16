const std = @import("std");
const build_options = @import("build_options");

// Import e_jerk_gpu library for GPU detection and auto-selection
pub const e_jerk_gpu = @import("e_jerk_gpu");

// Re-export library types for use across sed
pub const GpuCapabilities = e_jerk_gpu.GpuCapabilities;
pub const AutoSelector = e_jerk_gpu.AutoSelector;
pub const AutoSelectConfig = e_jerk_gpu.AutoSelectConfig;
pub const WorkloadInfo = e_jerk_gpu.WorkloadInfo;
pub const SelectionResult = e_jerk_gpu.SelectionResult;

pub const metal = if (build_options.is_macos) @import("metal.zig") else struct {
    pub const MetalSubstituter = void;
};
pub const vulkan = @import("vulkan.zig");

// Regex compiler for GPU regex support
pub const regex_compiler = @import("regex_compiler.zig");

// Configuration
pub const BATCH_SIZE: usize = 1024 * 1024;
pub const MAX_GPU_BUFFER_SIZE: usize = 64 * 1024 * 1024;
pub const MIN_GPU_SIZE: usize = 64 * 1024;
pub const MAX_PATTERN_LEN: u32 = 1024;
pub const MAX_RESULTS: u32 = 1000000;

pub const EMBEDDED_METAL_SHADER = if (build_options.is_macos) @import("metal_shader").EMBEDDED_METAL_SHADER else "";

// Sed-specific data structures

// Substitute configuration (must match shader struct layout)
pub const SubstituteConfig = extern struct {
    text_len: u32,
    pattern_len: u32,
    replacement_len: u32,
    flags: u32,
    max_matches: u32,
    num_threads: u32,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

// Result for each match (must match shader struct layout)
pub const MatchResult = extern struct {
    start: u32,
    end: u32,
    line_num: u32,
    _pad: u32 = 0,
};

// Substitute flags
pub const SubstituteFlags = struct {
    pub const CASE_INSENSITIVE: u32 = 1;
    pub const GLOBAL: u32 = 2;
    pub const FIRST_ONLY: u32 = 4;
    pub const LINE_MODE: u32 = 8;
};

// Substitute options
pub const SubstituteOptions = struct {
    case_insensitive: bool = false,
    global: bool = false, // Default: replace first occurrence only (like GNU sed)
    first_only: bool = false,
    line_mode: bool = false,
    anchor_start: bool = false, // ^ pattern anchor
    extended: bool = false, // ERE mode (-E/-r), when false uses BRE

    pub fn toFlags(self: SubstituteOptions) u32 {
        var flags: u32 = 0;
        if (self.case_insensitive) flags |= SubstituteFlags.CASE_INSENSITIVE;
        if (self.global) flags |= SubstituteFlags.GLOBAL;
        if (self.first_only) flags |= SubstituteFlags.FIRST_ONLY;
        if (self.line_mode) flags |= SubstituteFlags.LINE_MODE;
        return flags;
    }
};

// Substitution result
pub const SubstituteResult = struct {
    matches: []MatchResult,
    total_matches: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SubstituteResult) void {
        self.allocator.free(self.matches);
    }
};

// Use library's Backend enum
pub const Backend = e_jerk_gpu.Backend;

pub fn detectBestBackend() Backend {
    if (build_options.is_macos) return .metal;
    return .vulkan;
}

pub fn shouldUseGpu(text_len: usize) bool {
    return text_len >= MIN_GPU_SIZE;
}

// ============================================================================
// GPU Regex Types (matching Metal shader structs)
// ============================================================================

pub const MAX_REGEX_STATES: u32 = 256;
pub const BITMAP_WORDS_PER_CLASS: u32 = 8;

pub const RegexStateType = enum(u8) {
    literal = 0,
    char_class = 1,
    dot = 2,
    split = 3,
    match = 4,
    anchor_start = 5,
    anchor_end = 6,
    word_boundary = 7,
};

pub const RegexState = extern struct {
    type: u8,
    flags: u8,
    out: u16,
    out2: u16,
    literal_char: u8,
    group_idx: u8,
    bitmap_offset: u32,

    pub const FLAG_CASE_INSENSITIVE: u8 = 0x01;
    pub const FLAG_NEGATED: u8 = 0x02;
};

pub const RegexHeader = extern struct {
    num_states: u32,
    start_state: u32,
    num_groups: u32,
    flags: u32,

    pub const FLAG_ANCHORED_START: u32 = 0x01;
    pub const FLAG_ANCHORED_END: u32 = 0x02;
    pub const FLAG_CASE_INSENSITIVE: u32 = 0x04;
};

pub const RegexSearchConfig = extern struct {
    text_len: u32,
    num_states: u32,
    start_state: u32,
    header_flags: u32,
    num_bitmaps: u32,
    max_results: u32,
    flags: u32,
    _pad: u32 = 0,
};

pub const RegexMatchResult = extern struct {
    start: u32,
    end: u32,
    line_start: u32,
    flags: u32,

    pub const FLAG_VALID: u32 = 0x01;
};

pub fn formatBytes(bytes: usize) struct { value: f64, unit: []const u8 } {
    if (bytes >= 1024 * 1024 * 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024), .unit = "GB" };
    if (bytes >= 1024 * 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / (1024 * 1024), .unit = "MB" };
    if (bytes >= 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / 1024, .unit = "KB" };
    return .{ .value = @as(f64, @floatFromInt(bytes)), .unit = "B" };
}
