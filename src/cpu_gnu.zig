const std = @import("std");
const gpu = @import("gpu");
const cpu_optimized = @import("cpu_optimized");

const SubstituteOptions = gpu.SubstituteOptions;
const SubstituteResult = gpu.SubstituteResult;

/// GNU sed backend for pattern matching.
/// Note: GNU sed's pattern matching is tightly integrated with its command processing,
/// making it difficult to extract just the pattern matching functionality.
/// This backend delegates to the optimized implementation which uses the same
/// gnulib-derived algorithms for string matching.
pub fn findMatches(text: []const u8, pattern: []const u8, options: SubstituteOptions, allocator: std.mem.Allocator) !SubstituteResult {
    // Delegate to optimized backend - same algorithms, just the Zig SIMD implementation
    return cpu_optimized.findMatches(text, pattern, options, allocator);
}

/// GNU sed backend for regex pattern matching.
/// Delegates to optimized backend since GNU sed's regex is part of its command processor.
pub fn findMatchesRegex(text: []const u8, pattern: []const u8, options: SubstituteOptions, allocator: std.mem.Allocator) !SubstituteResult {
    return cpu_optimized.findMatchesRegex(text, pattern, options, allocator);
}
