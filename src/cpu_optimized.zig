const std = @import("std");
const gpu = @import("gpu");
const regex = @import("regex");

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

/// CPU-based regex match finding using Thompson NFA
/// Supports BRE (Basic Regular Expressions) and ERE (Extended Regular Expressions)
pub fn findMatchesRegex(text: []const u8, pattern: []const u8, options: SubstituteOptions, allocator: std.mem.Allocator) !SubstituteResult {
    // Empty pattern - match empty string at start (GNU sed behavior)
    if (pattern.len == 0) {
        var matches: std.ArrayListUnmanaged(MatchResult) = .{};
        try matches.append(allocator, MatchResult{
            .start = 0,
            .end = 0,
            .line_num = 0,
        });
        const result = try matches.toOwnedSlice(allocator);
        return SubstituteResult{ .matches = result, .total_matches = 1, .allocator = allocator };
    }

    // Convert BRE pattern to ERE if needed
    const ere_pattern = if (!options.extended)
        try convertBREtoERE(pattern, allocator)
    else
        null;
    defer if (ere_pattern) |p| allocator.free(p);

    const actual_pattern = ere_pattern orelse pattern;

    // Compile the regex pattern
    var compiled = regex.Regex.compile(allocator, actual_pattern, .{
        .case_insensitive = options.case_insensitive,
        .extended = true, // Always use ERE internally after conversion
        .multiline = true, // Enable multiline mode for ^ and $ to match at line boundaries
    }) catch |err| {
        // If regex compilation fails, fall back to literal search
        if (err == error.InvalidPattern or err == error.UnmatchedParen or err == error.UnmatchedBracket) {
            return findMatches(text, pattern, .{
                .case_insensitive = options.case_insensitive,
                .global = options.global,
                .first_only = options.first_only,
                .anchor_start = options.anchor_start,
            }, allocator);
        }
        return err;
    };
    defer compiled.deinit();

    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var total_matches: u64 = 0;
    var line_num: u32 = 0;
    var line_start: usize = 0;
    var pos: usize = 0;
    var found_in_line = false;

    while (pos <= text.len) {
        // Update line number tracking
        while (line_start < pos) {
            if (text[line_start] == '\n') {
                line_num += 1;
                found_in_line = false;
            }
            line_start += 1;
        }

        // For anchor_start, only match at line boundaries
        if (options.anchor_start) {
            // Find current line start
            var current_line_start = pos;
            if (pos > 0) {
                var i = pos - 1;
                while (i > 0 and text[i] != '\n') i -= 1;
                current_line_start = if (text[i] == '\n') i + 1 else i;
            }
            if (pos != current_line_start) {
                // Skip to next line
                while (pos < text.len and text[pos] != '\n') pos += 1;
                pos += 1;
                continue;
            }
        }

        // For non-global mode, only match first occurrence per line
        if (!options.global and found_in_line) {
            // Skip to next line
            while (pos < text.len and text[pos] != '\n') pos += 1;
            pos += 1;
            continue;
        }

        // Try to find a match at this position
        if (compiled.findAt(text, pos, allocator)) |m_opt| {
            if (m_opt) |m| {
                defer {
                    var m_copy = m;
                    m_copy.deinit();
                }

                try matches.append(allocator, MatchResult{
                    .start = @intCast(m.start),
                    .end = @intCast(m.end),
                    .line_num = line_num,
                });
                total_matches += 1;
                found_in_line = true;

                if (options.first_only) {
                    // Skip to next line
                    while (pos < text.len and text[pos] != '\n') pos += 1;
                    pos += 1;
                    continue;
                }

                // Move past the match (avoid zero-length infinite loop)
                pos = if (m.end > m.start) m.end else m.start + 1;
                continue;
            }
        } else |_| {}

        break;
    }

    const result = try matches.toOwnedSlice(allocator);
    return SubstituteResult{ .matches = result, .total_matches = total_matches, .allocator = allocator };
}

/// Convert BRE (Basic Regular Expression) pattern to ERE (Extended Regular Expression)
/// In BRE: \+ \? \| \( \) \{ \} are special, unescaped versions are literal
/// In ERE: + ? | ( ) { } are special, escaped versions are literal
fn convertBREtoERE(bre_pattern: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < bre_pattern.len) {
        if (bre_pattern[i] == '\\' and i + 1 < bre_pattern.len) {
            const next = bre_pattern[i + 1];
            switch (next) {
                // In BRE, \+ \? \| \( \) are special (quantifiers/grouping)
                // In ERE, just + ? | ( ) without backslash
                '+', '?', '|', '(', ')' => {
                    try result.append(allocator, next);
                    i += 2;
                },
                // In BRE, \{ \} are interval brackets
                // In ERE, just { } without backslash
                '{', '}' => {
                    try result.append(allocator, next);
                    i += 2;
                },
                // Other escapes pass through
                else => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, next);
                    i += 2;
                },
            }
        } else if (bre_pattern[i] == '+' or bre_pattern[i] == '?' or bre_pattern[i] == '|' or
            bre_pattern[i] == '(' or bre_pattern[i] == ')' or
            bre_pattern[i] == '{' or bre_pattern[i] == '}')
        {
            // In BRE, unescaped + ? | ( ) { } are literal
            // In ERE, they need to be escaped
            try result.append(allocator, '\\');
            try result.append(allocator, bre_pattern[i]);
            i += 1;
        } else {
            try result.append(allocator, bre_pattern[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}
