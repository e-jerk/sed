#include <metal_stdlib>
#include "string_ops.h"
using namespace metal;

// Configuration for substitution operation
// Optimized with uchar4 vector types for SIMD operations
struct SubstituteConfig {
    uint text_len;           // Length of input text
    uint pattern_len;        // Length of pattern to match
    uint replacement_len;    // Length of replacement string
    uint flags;              // Flags (case insensitive, global, etc.)
    uint max_matches;        // Maximum number of matches to store
    uint num_threads;        // Number of GPU threads dispatched
    uint _pad1;
    uint _pad2;
};

// Match result
struct MatchResult {
    uint start;              // Start position in text
    uint end;                // End position in text
    uint line_num;           // Line number (0-indexed)
    uint _pad;
};

// Note: Counters are passed as separate atomic_uint buffers for better atomics handling

// Flags
constant uint FLAG_CASE_INSENSITIVE = 1;
// Reserved for future use:
// FLAG_GLOBAL = 2 (Replace all occurrences - handled in host code)
// FLAG_FIRST_ONLY = 4 (Replace first occurrence only - handled in host code)
// FLAG_LINE_MODE = 8 (Process line by line - handled in host code)

// Common functions from string_ops.h:
// to_lower, to_lower4, char_match, match4, match_at_position

// Simple literal string matching (for s/literal/replacement/)
// Uses vectorized pattern matching for better performance
// Each thread processes a chunk of text positions
kernel void find_matches(
    device const uchar* text [[buffer(0)]],
    device const uchar* pattern [[buffer(1)]],
    device const SubstituteConfig& config [[buffer(2)]],
    device MatchResult* results [[buffer(3)]],
    device atomic_uint* result_count [[buffer(4)]],
    device atomic_uint* total_matches [[buffer(5)]],
    uint tid [[thread_position_in_grid]],
    uint num_threads [[threads_per_grid]]
) {
    uint text_len = config.text_len;
    uint pattern_len = config.pattern_len;

    if (pattern_len == 0 || text_len < pattern_len) return;
    if (tid >= num_threads) return;

    bool case_insensitive = (config.flags & FLAG_CASE_INSENSITIVE) != 0;

    // Calculate this thread's search range (chunked processing)
    uint searchable_len = text_len - pattern_len + 1;
    uint chunk_size = (searchable_len + num_threads - 1) / num_threads;
    uint start_pos = tid * chunk_size;
    uint end_pos = min(start_pos + chunk_size, searchable_len);

    if (start_pos >= searchable_len) return;

    // Process all positions in this thread's chunk
    for (uint pos = start_pos; pos < end_pos; pos++) {
        // Use vectorized pattern matching at this position
        if (match_at_position(text, text_len, pos, pattern, pattern_len, case_insensitive)) {
            // Atomically increment and get match index
            uint idx = atomic_fetch_add_explicit(result_count, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(total_matches, 1, memory_order_relaxed);

            if (idx < config.max_matches) {
                results[idx].start = pos;
                results[idx].end = pos + pattern_len;
                // Line number computed on host side for efficiency
                results[idx].line_num = 0;
            }
        }
    }
}

// Line filtering kernel (for /pattern/d or /pattern/p)
// Uses vectorized pattern matching for better performance
kernel void filter_lines(
    device const uchar* text [[buffer(0)]],
    device const uchar* pattern [[buffer(1)]],
    device const SubstituteConfig& config [[buffer(2)]],
    device uint* line_matches [[buffer(3)]],    // 1 if line matches, 0 otherwise
    device const uint* line_offsets [[buffer(4)]],  // Start offset of each line
    device const uint* line_lengths [[buffer(5)]],  // Length of each line
    uint gid [[thread_position_in_grid]],
    uint num_threads [[threads_per_grid]]
) {
    if (gid >= num_threads) return;

    uint line_start = line_offsets[gid];
    uint line_len = line_lengths[gid];

    bool case_insensitive = (config.flags & FLAG_CASE_INSENSITIVE) != 0;

    // Search for pattern in this line using vectorized matching
    bool found = false;
    for (uint pos = 0; pos + config.pattern_len <= line_len && !found; pos++) {
        if (match_at_position(text, config.text_len, line_start + pos, pattern, config.pattern_len, case_insensitive)) {
            found = true;
        }
    }

    line_matches[gid] = found ? 1 : 0;
}

// Transliterate kernel (for y/source/dest/)
kernel void transliterate(
    device uchar* text [[buffer(0)]],
    device const uchar* source_chars [[buffer(1)]],
    device const uchar* dest_chars [[buffer(2)]],
    device const SubstituteConfig& config [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.text_len) return;

    uchar c = text[gid];

    // Look up character in source set
    for (uint i = 0; i < config.pattern_len; i++) {
        if (c == source_chars[i]) {
            text[gid] = dest_chars[i];
            break;
        }
    }
}
