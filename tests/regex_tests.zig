const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");

const SubstituteOptions = gpu.SubstituteOptions;

// ============================================================================
// Regex Unit Tests for sed
// Tests BRE (Basic Regular Expressions) and ERE (Extended Regular Expressions)
// Based on GNU sed compatibility requirements
// ============================================================================

// ----------------------------------------------------------------------------
// Extended Regular Expression (ERE) Tests - sed -E
// ----------------------------------------------------------------------------

test "regex: dot matches any character" {
    const allocator = std.testing.allocator;
    const text = "hello";

    var result = try cpu.findMatchesRegex(text, "h.llo", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: star matches zero or more" {
    const allocator = std.testing.allocator;
    const text = "ac abc abbc abbbc";

    var result = try cpu.findMatchesRegex(text, "ab*c", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 4), result.total_matches);
}

test "regex: plus matches one or more" {
    const allocator = std.testing.allocator;
    const text = "ac abc abbc abbbc";

    var result = try cpu.findMatchesRegex(text, "ab+c", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    // Should not match "ac" (zero b's)
    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: question mark matches zero or one" {
    const allocator = std.testing.allocator;
    const text = "color colour";

    var result = try cpu.findMatchesRegex(text, "colou?r", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: alternation" {
    const allocator = std.testing.allocator;
    const text = "cat dog bird cat";

    var result = try cpu.findMatchesRegex(text, "cat|dog", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: character class" {
    const allocator = std.testing.allocator;
    const text = "a1b2c3";

    var result = try cpu.findMatchesRegex(text, "[0-9]", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: negated character class" {
    const allocator = std.testing.allocator;
    const text = "a1b2c3";

    var result = try cpu.findMatchesRegex(text, "[^0-9]", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: caret anchor" {
    const allocator = std.testing.allocator;
    const text = "hello world\nhello there";

    var result = try cpu.findMatchesRegex(text, "^hello", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: dollar anchor" {
    const allocator = std.testing.allocator;
    const text = "hello world\nthere world";

    var result = try cpu.findMatchesRegex(text, "world$", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: word boundary \\b" {
    const allocator = std.testing.allocator;
    const text = "the theory there";

    var result = try cpu.findMatchesRegex(text, "\\bthe\\b", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: word character class \\w" {
    const allocator = std.testing.allocator;
    const text = "hello_123";

    var result = try cpu.findMatchesRegex(text, "\\w+", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: digit class \\d" {
    const allocator = std.testing.allocator;
    const text = "abc123def456";

    var result = try cpu.findMatchesRegex(text, "\\d+", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: whitespace class \\s" {
    const allocator = std.testing.allocator;
    const text = "hello world\ttab";

    var result = try cpu.findMatchesRegex(text, "\\s+", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: grouping with capture" {
    const allocator = std.testing.allocator;
    const text = "abab cdcd abab";

    var result = try cpu.findMatchesRegex(text, "(ab)+", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: interval {n}" {
    const allocator = std.testing.allocator;
    const text = "a aa aaa aaaa";

    var result = try cpu.findMatchesRegex(text, "a{3}", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expect(result.total_matches >= 2);
}

test "regex: case insensitive" {
    const allocator = std.testing.allocator;
    const text = "Hello HELLO hello HeLLo";

    var result = try cpu.findMatchesRegex(text, "hello", .{ .extended = true, .case_insensitive = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 4), result.total_matches);
}

// ----------------------------------------------------------------------------
// Basic Regular Expression (BRE) Tests - sed default mode
// In BRE, special characters require backslash escaping
// ----------------------------------------------------------------------------

test "BRE: literal special characters without escape" {
    const allocator = std.testing.allocator;
    const text = "a+b a*b a?b";

    // In BRE, + and ? are literal without backslash
    var result = try cpu.findMatchesRegex(text, "a+b", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "BRE: escaped plus for one-or-more" {
    const allocator = std.testing.allocator;
    const text = "ab abb abbb";

    // In BRE, \+ means one or more b's after a
    // "ab" has 1 b, "abb" has 2 b's, "abbb" has 3 b's - all match
    var result = try cpu.findMatchesRegex(text, "ab\\+", .{ .extended = false, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "BRE: escaped question mark for optional" {
    const allocator = std.testing.allocator;
    const text = "color colour";

    // In BRE, \? means optional
    var result = try cpu.findMatchesRegex(text, "colou\\?r", .{ .extended = false, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "BRE: escaped parentheses for grouping" {
    const allocator = std.testing.allocator;
    const text = "abab cdcd";

    // In BRE, \( and \) for grouping
    var result = try cpu.findMatchesRegex(text, "\\(ab\\)*", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expect(result.total_matches >= 1);
}

test "BRE: escaped braces for interval" {
    const allocator = std.testing.allocator;
    const text = "aa aaa aaaa";

    // In BRE, \{ and \} for intervals
    var result = try cpu.findMatchesRegex(text, "a\\{3\\}", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expect(result.total_matches >= 1);
}

test "BRE: star is special without escape" {
    const allocator = std.testing.allocator;
    const text = "ac abc abbc";

    // In BRE, * is special (zero or more) without backslash
    var result = try cpu.findMatchesRegex(text, "ab*c", .{ .extended = false, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "BRE: dot is special without escape" {
    const allocator = std.testing.allocator;
    const text = "cat cot cut";

    // In BRE, . is special (any char) without backslash
    var result = try cpu.findMatchesRegex(text, "c.t", .{ .extended = false, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

// ----------------------------------------------------------------------------
// Substitution-specific tests with regex
// ----------------------------------------------------------------------------

test "regex substitution: simple replace" {
    const allocator = std.testing.allocator;
    const text = "hello world";
    const pattern = "world";
    const replacement = "universe";

    var result = try cpu.findMatchesRegex(text, pattern, .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
    try std.testing.expectEqual(@as(u32, 6), result.matches[0].start);
    try std.testing.expectEqual(@as(u32, 11), result.matches[0].end);
    _ = replacement;
}

test "regex substitution: global replace" {
    const allocator = std.testing.allocator;
    const text = "the cat sat on the mat";
    const pattern = "the";

    var result = try cpu.findMatchesRegex(text, pattern, .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex substitution: capture group positions" {
    const allocator = std.testing.allocator;
    const text = "hello world";
    const pattern = "(hello) (world)";

    var result = try cpu.findMatchesRegex(text, pattern, .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
    // Capture groups should be tracked for backreference support
}

test "regex substitution: match positions for replacement" {
    const allocator = std.testing.allocator;
    const text = "foo bar baz";
    const pattern = "bar";

    var result = try cpu.findMatchesRegex(text, pattern, .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
    try std.testing.expectEqual(@as(u32, 4), result.matches[0].start);
    try std.testing.expectEqual(@as(u32, 7), result.matches[0].end);
}

// ----------------------------------------------------------------------------
// Address pattern tests (for /pattern/d, /pattern/p)
// ----------------------------------------------------------------------------

test "regex address: line matching" {
    const allocator = std.testing.allocator;
    const text = "error: something\nwarning: else\nerror: another";

    var result = try cpu.findMatchesRegex(text, "^error:", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    // Should match 2 lines starting with "error:"
    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex address: negation" {
    const allocator = std.testing.allocator;
    const text = "keep this\ndelete error\nkeep that";

    // Lines NOT matching "error" - this is handled at a higher level
    var result = try cpu.findMatchesRegex(text, "error", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

// ----------------------------------------------------------------------------
// Edge Cases and GNU Compatibility
// ----------------------------------------------------------------------------

test "regex: empty pattern" {
    const allocator = std.testing.allocator;
    const text = "hello";

    // Empty regex should match empty string at every position
    var result = try cpu.findMatchesRegex(text, "", .{ .extended = true }, allocator);
    defer result.deinit();

    // First match at position 0
    try std.testing.expect(result.total_matches >= 1);
}

test "regex: pattern at end of text without newline" {
    const allocator = std.testing.allocator;
    const text = "hello world";

    var result = try cpu.findMatchesRegex(text, "world$", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: multiple matches same line" {
    const allocator = std.testing.allocator;
    const text = "the cat and the dog";

    var result = try cpu.findMatchesRegex(text, "the", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: complex pattern with special chars" {
    const allocator = std.testing.allocator;
    const text = "file.txt and file_backup.txt";

    var result = try cpu.findMatchesRegex(text, "file[._]", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: multiline mode line start" {
    const allocator = std.testing.allocator;
    const text = "first line\nsecond line\nthird line";

    var result = try cpu.findMatchesRegex(text, "^\\w+ line", .{ .extended = true, .global = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: greedy vs minimal matching" {
    const allocator = std.testing.allocator;
    const text = "<tag>content</tag>";

    // Standard regex is greedy
    var result = try cpu.findMatchesRegex(text, "<.*>", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
    // Greedy should match the entire "<tag>content</tag>"
    try std.testing.expectEqual(@as(u32, 0), result.matches[0].start);
    try std.testing.expectEqual(@as(u32, 18), result.matches[0].end);
}
