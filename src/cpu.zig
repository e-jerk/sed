const std = @import("std");
const gpu = @import("gpu");

const SubstituteOptions = gpu.SubstituteOptions;
const SubstituteResult = gpu.SubstituteResult;
const MatchResult = gpu.MatchResult;

// SIMD vector types for optimal performance
const Vec16 = @Vector(16, u8);
const Vec32 = @Vector(32, u8);

// Constants for vectorized operations
const NEWLINE_VEC32: Vec32 = @splat('\n');
const UPPER_A_VEC16: Vec16 = @splat('A');
const UPPER_Z_VEC16: Vec16 = @splat('Z');
const CASE_DIFF_VEC16: Vec16 = @splat(32);

/// CPU-based substitute/search using SIMD-optimized Boyer-Moore-Horspool algorithm
pub fn findMatches(text: []const u8, pattern: []const u8, options: SubstituteOptions, allocator: std.mem.Allocator) !SubstituteResult {
    if (pattern.len == 0 or text.len < pattern.len) {
        return SubstituteResult{ .matches = &.{}, .total_matches = 0, .allocator = allocator };
    }

    // Pre-compute lowercase pattern if case insensitive
    var lower_pattern_buf: [1024]u8 = undefined;
    const search_pattern = if (options.case_insensitive and pattern.len <= 1024) blk: {
        toLowerSlice(pattern, lower_pattern_buf[0..pattern.len]);
        break :blk lower_pattern_buf[0..pattern.len];
    } else pattern;

    const skip_table = buildSkipTable(search_pattern, options.case_insensitive);

    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var pos: usize = 0;
    var total_matches: u64 = 0;
    var line_num: u32 = 0;
    var last_newline_pos: usize = 0;
    var line_start: usize = 0;
    var found_in_line = false;

    // Count lines as we go
    while (pos + pattern.len <= text.len) {
        // Update line count and track line start using SIMD when possible
        while (last_newline_pos < pos) {
            if (text[last_newline_pos] == '\n') {
                line_num += 1;
                line_start = last_newline_pos + 1;
                found_in_line = false;
            }
            last_newline_pos += 1;
        }

        // For anchor_start, only match at line start
        if (options.anchor_start and pos != line_start) {
            // Skip to next line using SIMD
            pos = findNextNewlineSIMD(text, pos) + 1;
            continue;
        }

        if (matchAtPositionSIMD(text, pos, search_pattern, options.case_insensitive)) {
            // For non-global mode, only match first occurrence per line
            if (!options.global and found_in_line) {
                pos = findNextNewlineSIMD(text, pos) + 1;
                continue;
            }

            try matches.append(allocator, MatchResult{
                .start = @intCast(pos),
                .end = @intCast(pos + pattern.len),
                .line_num = line_num,
            });
            total_matches += 1;
            found_in_line = true;

            if (options.first_only) {
                pos = findNextNewlineSIMD(text, pos) + 1;
                continue;
            }

            // For non-global mode, skip to next line after first match
            if (!options.global) {
                pos = findNextNewlineSIMD(text, pos) + 1;
                continue;
            }
        }

        const skip_char = if (options.case_insensitive)
            toLowerChar(text[pos + pattern.len - 1])
        else
            text[pos + pattern.len - 1];
        const skip = skip_table[skip_char];
        pos += @max(skip, 1);
    }

    const result = try matches.toOwnedSlice(allocator);
    return SubstituteResult{ .matches = result, .total_matches = total_matches, .allocator = allocator };
}

/// SIMD-optimized pattern matching at a specific position
inline fn matchAtPositionSIMD(text: []const u8, pos: usize, pattern: []const u8, case_insensitive: bool) bool {
    if (pos + pattern.len > text.len) return false;

    const text_slice = text[pos..][0..pattern.len];
    var offset: usize = 0;

    // Process 16 bytes at a time
    while (offset + 16 <= pattern.len) {
        const text_vec: Vec16 = text_slice[offset..][0..16].*;
        const pattern_vec: Vec16 = pattern[offset..][0..16].*;

        const cmp_result = if (case_insensitive)
            @as(Vec16, toLowerVec16(text_vec)) == pattern_vec
        else
            text_vec == pattern_vec;

        if (!@reduce(.And, cmp_result)) return false;
        offset += 16;
    }

    // Process remaining bytes
    while (offset < pattern.len) {
        var tc = text_slice[offset];
        const pc = pattern[offset];

        if (case_insensitive) {
            tc = toLowerChar(tc);
        }

        if (tc != pc) return false;
        offset += 1;
    }

    return true;
}

/// SIMD-optimized newline finder
fn findNextNewlineSIMD(text: []const u8, start: usize) usize {
    var i = start;

    // Search 32 bytes at a time
    while (i + 32 <= text.len) {
        const chunk: Vec32 = text[i..][0..32].*;
        const newlines = chunk == NEWLINE_VEC32;

        if (@reduce(.Or, newlines)) {
            // Find the first newline
            for (0..32) |j| {
                if (text[i + j] == '\n') return i + j;
            }
        }
        i += 32;
    }

    // Handle remaining bytes
    while (i < text.len) {
        if (text[i] == '\n') return i;
        i += 1;
    }

    return text.len;
}

/// Vectorized lowercase conversion for Vec16
inline fn toLowerVec16(v: Vec16) Vec16 {
    const is_upper = (v >= UPPER_A_VEC16) & (v <= UPPER_Z_VEC16);
    return @select(u8, is_upper, v + CASE_DIFF_VEC16, v);
}

/// Scalar lowercase conversion
inline fn toLowerChar(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Convert slice to lowercase using SIMD
inline fn toLowerSlice(src: []const u8, dst: []u8) void {
    var i: usize = 0;
    // Process 16 bytes at a time
    while (i + 16 <= src.len) {
        const vec: Vec16 = src[i..][0..16].*;
        const lower = toLowerVec16(vec);
        dst[i..][0..16].* = lower;
        i += 16;
    }
    // Handle remaining bytes
    while (i < src.len) {
        dst[i] = toLowerChar(src[i]);
        i += 1;
    }
}

/// CPU-based transliterate (y/source/dest/) with SIMD optimization
pub fn transliterate(text: []u8, source: []const u8, dest: []const u8) void {
    // Build translation table
    var table: [256]u8 = undefined;
    for (&table, 0..) |*t, i| t.* = @intCast(i);

    const len = @min(source.len, dest.len);
    for (0..len) |i| {
        table[source[i]] = dest[i];
    }

    // Translate using SIMD - process 32 bytes at a time
    var i: usize = 0;
    while (i + 32 <= text.len) {
        // Unfortunately, table lookup doesn't vectorize well
        // Process in chunks but use scalar lookups
        inline for (0..32) |j| {
            text[i + j] = table[text[i + j]];
        }
        i += 32;
    }

    // Handle remaining bytes
    while (i < text.len) {
        text[i] = table[text[i]];
        i += 1;
    }
}

/// Build skip table for Boyer-Moore-Horspool
pub fn buildSkipTable(pattern: []const u8, case_insensitive: bool) [256]usize {
    var table: [256]usize = undefined;
    @memset(&table, pattern.len);

    for (pattern[0 .. pattern.len - 1], 0..) |c, i| {
        const skip = pattern.len - 1 - i;
        if (case_insensitive) {
            const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
            const upper = if (c >= 'a' and c <= 'z') c - 32 else c;
            table[lower] = skip;
            table[upper] = skip;
        } else {
            table[c] = skip;
        }
    }
    return table;
}
