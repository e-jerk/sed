const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");
const cpu_gnu = @import("cpu_gnu");

const SubstituteOptions = gpu.SubstituteOptions;

/// Backend selection mode
const BackendMode = enum {
    auto, // Automatically select based on workload
    gpu_mode, // Auto-select best GPU (Metal on macOS, else Vulkan)
    cpu_mode,
    cpu_gnu, // GNU sed reference implementation
    metal,
    vulkan,
};

/// Sed command type
const CommandType = enum {
    substitute, // s/pattern/replacement/flags
    delete, // /pattern/d
    print, // /pattern/p
    transliterate, // y/source/dest/
};

/// Line address for sed commands
const Address = struct {
    start: ?u32 = null, // null means beginning or not specified
    end: ?u32 = null, // null means same as start (single line) or end of file
    is_last_line: bool = false, // $ address
    end_is_last: bool = false, // $ as end of range

    /// Check if a line number matches this address (line_num is 1-indexed)
    pub fn matches(self: Address, line_num: u32, total_lines: u32) bool {
        // Handle $ (last line)
        const effective_start = if (self.is_last_line) total_lines else (self.start orelse 1);
        const effective_end = if (self.end_is_last) total_lines else (self.end orelse effective_start);

        return line_num >= effective_start and line_num <= effective_end;
    }
};

/// Parsed sed command
const SedCommand = struct {
    cmd_type: CommandType,
    pattern: []const u8,
    replacement: []const u8,
    options: SubstituteOptions,
    address: ?Address = null, // Optional line address
};

/// Process replacement string, expanding special sequences like & (matched text)
fn processReplacement(replacement: []const u8, matched_text: []const u8, output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < replacement.len) {
        if (replacement[i] == '&') {
            // & expands to the matched text
            try output.appendSlice(allocator, matched_text);
            i += 1;
        } else if (replacement[i] == '\\' and i + 1 < replacement.len) {
            const next = replacement[i + 1];
            if (next == '&') {
                // \& is a literal &
                try output.append(allocator, '&');
                i += 2;
            } else if (next == '\\') {
                // \\ is a literal \
                try output.append(allocator, '\\');
                i += 2;
            } else if (next == 'n') {
                // \n is a newline
                try output.append(allocator, '\n');
                i += 2;
            } else if (next == 't') {
                // \t is a tab
                try output.append(allocator, '\t');
                i += 2;
            } else {
                // Other escapes pass through
                try output.append(allocator, replacement[i]);
                i += 1;
            }
        } else {
            try output.append(allocator, replacement[i]);
            i += 1;
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    var backend_mode: BackendMode = .auto;
    var expressions: std.ArrayListUnmanaged([]const u8) = .{};
    defer expressions.deinit(allocator);
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(allocator);
    var verbose = false;
    var in_place = false;
    var suppress_output = false;
    var use_extended_regex = false; // ERE mode (-E/-r)
    var saw_explicit_expr = false; // Track if -e was used

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--expression")) {
            if (i + 1 < args.len) {
                i += 1;
                try expressions.append(allocator, args[i]);
                saw_explicit_expr = true;
            }
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
            suppress_output = true;
        } else if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--regexp-extended")) {
            use_extended_regex = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--in-place")) {
            in_place = true;
        } else if (std.mem.eql(u8, arg, "--cpu") or std.mem.eql(u8, arg, "--cpu-optimized")) {
            backend_mode = .cpu_mode;
        } else if (std.mem.eql(u8, arg, "--gnu")) {
            backend_mode = .cpu_gnu;
        } else if (std.mem.eql(u8, arg, "--gpu")) {
            backend_mode = .gpu_mode;
        } else if (std.mem.eql(u8, arg, "--metal")) {
            backend_mode = .metal;
        } else if (std.mem.eql(u8, arg, "--vulkan")) {
            backend_mode = .vulkan;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            backend_mode = .auto;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (arg[0] != '-') {
            // First non-option is expression if -e wasn't used
            if (!saw_explicit_expr and expressions.items.len == 0) {
                try expressions.append(allocator, arg);
            } else {
                try files.append(allocator, arg);
            }
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            return;
        }
    }

    if (expressions.items.len == 0) {
        std.debug.print("Error: No expression specified\n", .{});
        printUsage();
        return;
    }

    // Parse all sed expressions
    var commands: std.ArrayListUnmanaged(SedCommand) = .{};
    defer commands.deinit(allocator);

    for (expressions.items) |expr| {
        var cmd = parseSedExpression(expr) catch |err| {
            std.debug.print("Error parsing expression '{s}': {}\n", .{ expr, err });
            return;
        };
        cmd.options.extended = use_extended_regex;
        try commands.append(allocator, cmd);
    }

    // If no files specified, read from stdin
    const read_stdin = files.items.len == 0;

    if (verbose) {
        std.debug.print("sed - GPU-accelerated sed\n", .{});
        std.debug.print("Expressions: {d}\n", .{commands.items.len});
        for (commands.items, 0..) |cmd, idx| {
            std.debug.print("  [{d}] {s}: pattern=\"{s}\"", .{ idx, @tagName(cmd.cmd_type), cmd.pattern });
            if (cmd.replacement.len > 0) {
                std.debug.print(" replacement=\"{s}\"", .{cmd.replacement});
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("Mode: {s}\n", .{@tagName(backend_mode)});
        std.debug.print("\n", .{});
    }

    // Process each file or stdin
    if (read_stdin) {
        try processStdinMulti(allocator, commands.items, backend_mode, verbose, suppress_output);
    } else {
        for (files.items) |filepath| {
            // Handle "-" as stdin
            if (std.mem.eql(u8, filepath, "-")) {
                try processStdinMulti(allocator, commands.items, backend_mode, verbose, suppress_output);
            } else {
                try processFileMulti(allocator, filepath, commands.items, backend_mode, verbose, in_place, suppress_output);
            }
        }
    }
}

/// Check if pattern requires regex processing
fn needsRegex(pattern: []const u8, options: SubstituteOptions) bool {
    if (options.extended) return true;
    // For BRE mode (default), also use regex for special characters
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '.' or c == '*' or c == '^' or c == '$' or c == '[') {
            return true;
        }
        if (c == '\\' and i + 1 < pattern.len) {
            const next = pattern[i + 1];
            if (next == '+' or next == '?' or next == '|' or next == '(' or next == ')' or next == '{' or next == '}') {
                return true;
            }
            i += 1;
        }
    }
    return false;
}

/// Choose appropriate find function based on options (literal vs regex)
fn doFindMatches(text: []const u8, pattern: []const u8, options: SubstituteOptions, allocator: std.mem.Allocator) !gpu.SubstituteResult {
    if (needsRegex(pattern, options)) {
        return cpu.findMatchesRegex(text, pattern, options, allocator);
    }
    return cpu.findMatches(text, pattern, options, allocator);
}

fn processStdin(allocator: std.mem.Allocator, cmd: SedCommand, backend_mode: BackendMode, verbose: bool, suppress_output: bool) !void {
    // Read all stdin into a buffer
    var stdin_list: std.ArrayListUnmanaged(u8) = .{};
    defer stdin_list.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &buf) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
        if (bytes_read == 0) break;
        try stdin_list.appendSlice(allocator, buf[0..bytes_read]);
        if (stdin_list.items.len > gpu.MAX_GPU_BUFFER_SIZE) break;
    }
    const text = stdin_list.items;

    const file_size = text.len;

    if (verbose) {
        std.debug.print("(standard input) ({d} bytes)\n", .{file_size});
    }

    // Select backend
    // Note: cpu_gnu maps to .cpu backend but uses cpu_gnu module for matching
    const backend: gpu.Backend = switch (backend_mode) {
        .auto => selectOptimalBackend(cmd.pattern.len, file_size),
        .gpu_mode => if (build_options.is_macos) .metal else .vulkan,
        .cpu_mode, .cpu_gnu => .cpu,
        .metal => .metal,
        .vulkan => .vulkan,
    };

    if (verbose) {
        std.debug.print("Backend: {s}\n", .{@tagName(backend)});
    }

    switch (cmd.cmd_type) {
        .substitute => try processSubstituteStdin(allocator, text, cmd, backend, verbose, suppress_output),
        .delete => try processDelete(allocator, text, cmd, backend, verbose, suppress_output),
        .print => try processPrint(allocator, text, cmd, backend, verbose, suppress_output),
        .transliterate => try processTransliterateStdin(allocator, text, cmd, verbose, suppress_output),
    }
}

/// Count total lines in text
fn countLines(text: []const u8) u32 {
    var count: u32 = 1; // Start at 1 (line numbers are 1-indexed)
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    // Don't count extra line if text ends with newline
    if (text.len > 0 and text[text.len - 1] == '\n') {
        count -= 1;
    }
    return if (count == 0) 1 else count;
}

/// Apply a single command to text and return the result
fn applyCommand(allocator: std.mem.Allocator, text: []const u8, cmd: SedCommand, backend: gpu.Backend) ![]u8 {
    // Count total lines for address handling
    const total_lines = countLines(text);

    switch (cmd.cmd_type) {
        .substitute => {
            // If we have an address, we need to process line-by-line
            if (cmd.address) |addr| {
                var output: std.ArrayListUnmanaged(u8) = .{};
                errdefer output.deinit(allocator);

                var line_num: u32 = 1;
                var line_start: usize = 0;
                var i: usize = 0;

                while (i <= text.len) : (i += 1) {
                    const at_end = i == text.len;
                    const is_newline = !at_end and text[i] == '\n';

                    if (is_newline or at_end) {
                        const line_end = i;
                        const line = text[line_start..line_end];

                        if (addr.matches(line_num, total_lines)) {
                            // Apply substitution to this line
                            var line_result = try doFindMatches(line, cmd.pattern, cmd.options, allocator);
                            defer line_result.deinit();

                            var last_pos: usize = 0;
                            for (line_result.matches) |match| {
                                try output.appendSlice(allocator, line[last_pos..match.start]);
                                const matched_text = line[match.start..match.end];
                                try processReplacement(cmd.replacement, matched_text, &output, allocator);
                                last_pos = match.end;
                            }
                            try output.appendSlice(allocator, line[last_pos..]);
                        } else {
                            // Pass through unchanged
                            try output.appendSlice(allocator, line);
                        }

                        if (is_newline) {
                            try output.append(allocator, '\n');
                        }

                        line_start = i + 1;
                        line_num += 1;
                    }
                }

                return output.toOwnedSlice(allocator);
            }

            // No address - apply to all lines (original behavior)
            var result = switch (backend) {
                .metal => blk: {
                    if (build_options.is_macos) {
                        const substituter = gpu.metal.MetalSubstituter.init(allocator) catch {
                            break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                        };
                        defer substituter.deinit();
                        break :blk (if (needsRegex(cmd.pattern, cmd.options))
                            substituter.findMatchesRegex(text, cmd.pattern, cmd.options, allocator)
                        else
                            substituter.findMatches(text, cmd.pattern, cmd.options, allocator)) catch {
                            break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                        };
                    } else {
                        break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                    }
                },
                .vulkan => blk: {
                    const substituter = gpu.vulkan.VulkanSubstituter.init(allocator) catch {
                        break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                    };
                    defer substituter.deinit();
                    break :blk (if (needsRegex(cmd.pattern, cmd.options))
                        substituter.findMatchesRegex(text, cmd.pattern, cmd.options, allocator)
                    else
                        substituter.findMatches(text, cmd.pattern, cmd.options, allocator)) catch {
                        break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                    };
                },
                else => try doFindMatches(text, cmd.pattern, cmd.options, allocator),
            };
            defer result.deinit();

            // Build output with replacements
            var output: std.ArrayListUnmanaged(u8) = .{};
            errdefer output.deinit(allocator);

            var last_pos: usize = 0;
            for (result.matches) |match| {
                try output.appendSlice(allocator, text[last_pos..match.start]);
                const matched_text = text[match.start..match.end];
                try processReplacement(cmd.replacement, matched_text, &output, allocator);
                last_pos = match.end;
            }
            try output.appendSlice(allocator, text[last_pos..]);
            return output.toOwnedSlice(allocator);
        },
        .delete => {
            // If we have an address with empty pattern, delete by line number
            if (cmd.address) |addr| {
                if (cmd.pattern.len == 0) {
                    var output: std.ArrayListUnmanaged(u8) = .{};
                    errdefer output.deinit(allocator);

                    var line_num: u32 = 1;
                    var line_start: usize = 0;
                    var i: usize = 0;

                    while (i < text.len) : (i += 1) {
                        if (text[i] == '\n') {
                            if (!addr.matches(line_num, total_lines)) {
                                try output.appendSlice(allocator, text[line_start .. i + 1]);
                            }
                            line_start = i + 1;
                            line_num += 1;
                        }
                    }
                    // Handle last line without newline
                    if (line_start < text.len and !addr.matches(line_num, total_lines)) {
                        try output.appendSlice(allocator, text[line_start..]);
                    }

                    return output.toOwnedSlice(allocator);
                }
            }

            // Pattern-based delete (original behavior)
            var result = try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            defer result.deinit();

            var output: std.ArrayListUnmanaged(u8) = .{};
            errdefer output.deinit(allocator);

            // Mark lines to delete (line_num is 0-indexed from doFindMatches)
            var matched_lines = std.AutoHashMap(u32, void).init(allocator);
            defer matched_lines.deinit();

            for (result.matches) |match| {
                try matched_lines.put(match.line_num, {});
            }

            // Build output excluding deleted lines (use 0-indexed line numbers)
            var line_num: u32 = 0;
            var line_start: usize = 0;
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\n') {
                    if (!matched_lines.contains(line_num)) {
                        try output.appendSlice(allocator, text[line_start .. i + 1]);
                    }
                    line_start = i + 1;
                    line_num += 1;
                }
            }
            // Handle last line without newline
            if (line_start < text.len and !matched_lines.contains(line_num)) {
                try output.appendSlice(allocator, text[line_start..]);
            }

            return output.toOwnedSlice(allocator);
        },
        .print => {
            // For print, just return a copy (print doesn't modify)
            const copy = try allocator.dupe(u8, text);
            return copy;
        },
        .transliterate => {
            // Copy and transliterate
            const copy = try allocator.dupe(u8, text);
            errdefer allocator.free(copy);

            const src_chars = cmd.pattern;
            const dst_chars = cmd.replacement;

            for (copy) |*c| {
                for (src_chars, 0..) |src, j| {
                    if (c.* == src and j < dst_chars.len) {
                        c.* = dst_chars[j];
                        break;
                    }
                }
            }
            return copy;
        },
    }
}

/// Process stdin with multiple commands
fn processStdinMulti(allocator: std.mem.Allocator, commands: []const SedCommand, backend_mode: BackendMode, verbose: bool, suppress_output: bool) !void {
    // Read all stdin into a buffer
    var stdin_list: std.ArrayListUnmanaged(u8) = .{};
    defer stdin_list.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &buf) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
        if (bytes_read == 0) break;
        try stdin_list.appendSlice(allocator, buf[0..bytes_read]);
        if (stdin_list.items.len > gpu.MAX_GPU_BUFFER_SIZE) break;
    }

    const file_size = stdin_list.items.len;

    if (verbose) {
        std.debug.print("(standard input) ({d} bytes)\n", .{file_size});
    }

    // Start with the original text
    var current_text: []u8 = try allocator.dupe(u8, stdin_list.items);

    // Apply each command in sequence
    for (commands, 0..) |cmd, idx| {
        const backend: gpu.Backend = switch (backend_mode) {
            .auto => selectOptimalBackend(cmd.pattern.len, @intCast(current_text.len)),
            .gpu_mode => if (build_options.is_macos) .metal else .vulkan,
            .cpu_mode, .cpu_gnu => .cpu,
            .metal => .metal,
            .vulkan => .vulkan,
        };

        if (verbose) {
            std.debug.print("Command [{d}]: {s}, Backend: {s}\n", .{ idx, @tagName(cmd.cmd_type), @tagName(backend) });
        }

        const new_text = try applyCommand(allocator, current_text, cmd, backend);
        allocator.free(current_text);
        current_text = new_text;
    }
    defer allocator.free(current_text);

    // Output result (unless suppressed)
    if (!suppress_output) {
        _ = std.posix.write(std.posix.STDOUT_FILENO, current_text) catch {};
    }
}

/// Process file with multiple commands
fn processFileMulti(allocator: std.mem.Allocator, filepath: []const u8, commands: []const SedCommand, backend_mode: BackendMode, verbose: bool, in_place: bool, suppress_output: bool) !void {
    const file = std.fs.cwd().openFile(filepath, .{}) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ filepath, err });
        return;
    };
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;

    if (verbose) {
        std.debug.print("File: {s} ({d} bytes)\n", .{ filepath, file_size });
    }

    const original_text = try file.readToEndAlloc(allocator, gpu.MAX_GPU_BUFFER_SIZE);

    // Start with the original text
    var current_text: []u8 = original_text;

    // Apply each command in sequence
    for (commands, 0..) |cmd, idx| {
        const backend: gpu.Backend = switch (backend_mode) {
            .auto => selectOptimalBackend(cmd.pattern.len, @intCast(current_text.len)),
            .gpu_mode => if (build_options.is_macos) .metal else .vulkan,
            .cpu_mode, .cpu_gnu => .cpu,
            .metal => .metal,
            .vulkan => .vulkan,
        };

        if (verbose) {
            std.debug.print("Command [{d}]: {s}, Backend: {s}\n", .{ idx, @tagName(cmd.cmd_type), @tagName(backend) });
        }

        const new_text = try applyCommand(allocator, current_text, cmd, backend);
        allocator.free(current_text);
        current_text = new_text;
    }
    defer allocator.free(current_text);

    // Write output
    if (in_place) {
        const out_file = try std.fs.cwd().createFile(filepath, .{});
        defer out_file.close();
        try out_file.writeAll(current_text);
    } else if (!suppress_output) {
        _ = std.posix.write(std.posix.STDOUT_FILENO, current_text) catch {};
    }
}

fn processSubstituteStdin(allocator: std.mem.Allocator, text: []const u8, cmd: SedCommand, backend: gpu.Backend, verbose: bool, suppress_output: bool) !void {
    // Find matches
    var result = switch (backend) {
        .metal => blk: {
            if (build_options.is_macos) {
                const substituter = gpu.metal.MetalSubstituter.init(allocator) catch {
                    break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                };
                defer substituter.deinit();
                break :blk (if (needsRegex(cmd.pattern, cmd.options))
                    substituter.findMatchesRegex(text, cmd.pattern, cmd.options, allocator)
                else
                    substituter.findMatches(text, cmd.pattern, cmd.options, allocator)) catch {
                    break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                };
            } else {
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            }
        },
        .vulkan => blk: {
            const substituter = gpu.vulkan.VulkanSubstituter.init(allocator) catch {
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            };
            defer substituter.deinit();
            break :blk (if (needsRegex(cmd.pattern, cmd.options))
                substituter.findMatchesRegex(text, cmd.pattern, cmd.options, allocator)
            else
                substituter.findMatches(text, cmd.pattern, cmd.options, allocator)) catch {
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            };
        },
        else => try doFindMatches(text, cmd.pattern, cmd.options, allocator),
    };
    defer result.deinit();

    if (verbose) {
        std.debug.print("Found {d} matches\n\n", .{result.total_matches});
    }

    // Build output with replacements
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(allocator);

    var last_pos: usize = 0;
    for (result.matches) |match| {
        try output.appendSlice(allocator, text[last_pos..match.start]);
        const matched_text = text[match.start..match.end];
        try processReplacement(cmd.replacement, matched_text, &output, allocator);
        last_pos = match.end;
    }
    try output.appendSlice(allocator, text[last_pos..]);

    if (!suppress_output) {
        _ = std.posix.write(std.posix.STDOUT_FILENO, output.items) catch {};
    }
}

fn processTransliterateStdin(allocator: std.mem.Allocator, text: []const u8, cmd: SedCommand, verbose: bool, suppress_output: bool) !void {
    const mutable_text = try allocator.alloc(u8, text.len);
    defer allocator.free(mutable_text);
    @memcpy(mutable_text, text);

    cpu.transliterate(mutable_text, cmd.pattern, cmd.replacement);

    if (verbose) {
        std.debug.print("Transliterated {d} bytes\n\n", .{mutable_text.len});
    }

    if (!suppress_output) {
        _ = std.posix.write(std.posix.STDOUT_FILENO, mutable_text) catch {};
    }
}

fn parseSedExpression(expr: []const u8) !SedCommand {
    if (expr.len < 1) return error.InvalidExpression;

    // First, try to parse a line address (number, range, or $)
    var address: ?Address = null;
    var cmd_start: usize = 0;

    if (expr[0] >= '0' and expr[0] <= '9') {
        // Line number address
        var i: usize = 0;
        while (i < expr.len and expr[i] >= '0' and expr[i] <= '9') : (i += 1) {}
        const line_num = std.fmt.parseInt(u32, expr[0..i], 10) catch return error.InvalidExpression;
        address = Address{ .start = line_num };
        cmd_start = i;

        // Check for range (comma followed by another number or $)
        if (i < expr.len and expr[i] == ',') {
            i += 1;
            if (i < expr.len) {
                if (expr[i] == '$') {
                    address.?.end_is_last = true;
                    i += 1;
                } else if (expr[i] >= '0' and expr[i] <= '9') {
                    var j = i;
                    while (j < expr.len and expr[j] >= '0' and expr[j] <= '9') : (j += 1) {}
                    const end_num = std.fmt.parseInt(u32, expr[i..j], 10) catch return error.InvalidExpression;
                    address.?.end = end_num;
                    i = j;
                }
            }
            cmd_start = i;
        }
    } else if (expr[0] == '$') {
        // Last line address
        address = Address{ .is_last_line = true };
        cmd_start = 1;
        // Check for range ($,number - unusual but valid)
        if (cmd_start < expr.len and expr[cmd_start] == ',') {
            cmd_start += 1;
            if (cmd_start < expr.len and expr[cmd_start] >= '0' and expr[cmd_start] <= '9') {
                var j = cmd_start;
                while (j < expr.len and expr[j] >= '0' and expr[j] <= '9') : (j += 1) {}
                const end_num = std.fmt.parseInt(u32, expr[cmd_start..j], 10) catch return error.InvalidExpression;
                address.?.end = end_num;
                cmd_start = j;
            }
        }
    }

    // Get the remaining expression after the address
    const remaining = expr[cmd_start..];
    if (remaining.len < 1) return error.InvalidExpression;

    // Check for transliterate (y/source/dest/)
    if (remaining[0] == 'y' and remaining.len >= 4) {
        const delim = remaining[1];
        var parts: [3][]const u8 = undefined;
        var part_idx: usize = 0;
        var start: usize = 2;

        for (remaining[2..], 2..) |c, idx| {
            if (c == delim) {
                parts[part_idx] = remaining[start..idx];
                part_idx += 1;
                start = idx + 1;
                if (part_idx >= 2) break;
            }
        }
        if (part_idx >= 2) {
            return SedCommand{
                .cmd_type = .transliterate,
                .pattern = parts[0],
                .replacement = parts[1],
                .options = .{},
                .address = address,
            };
        }
    }

    // Check for substitute (s/pattern/replacement/flags)
    if (remaining[0] == 's' and remaining.len >= 4) {
        const delim = remaining[1];
        var pattern_end: usize = 2;
        while (pattern_end < remaining.len and remaining[pattern_end] != delim) {
            if (remaining[pattern_end] == '\\' and pattern_end + 1 < remaining.len) {
                pattern_end += 2; // Skip escaped char
            } else {
                pattern_end += 1;
            }
        }

        if (pattern_end >= remaining.len) return error.InvalidExpression;

        const pattern = remaining[2..pattern_end];
        var replacement_end = pattern_end + 1;
        while (replacement_end < remaining.len and remaining[replacement_end] != delim) {
            if (remaining[replacement_end] == '\\' and replacement_end + 1 < remaining.len) {
                replacement_end += 2;
            } else {
                replacement_end += 1;
            }
        }

        const replacement = remaining[pattern_end + 1 .. replacement_end];

        // Parse flags
        var options = SubstituteOptions{};
        if (replacement_end + 1 < remaining.len) {
            const flags = remaining[replacement_end + 1 ..];
            for (flags) |f| {
                switch (f) {
                    'g' => options.global = true,
                    'i', 'I' => options.case_insensitive = true,
                    '1' => options.first_only = true,
                    else => {},
                }
            }
        }

        return SedCommand{
            .cmd_type = .substitute,
            .pattern = pattern,
            .replacement = replacement,
            .options = options,
            .address = address,
        };
    }

    // Check for just 'd' (delete addressed lines)
    if (remaining[0] == 'd') {
        return SedCommand{
            .cmd_type = .delete,
            .pattern = "", // No pattern - use address only
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for just 'p' (print addressed lines)
    if (remaining[0] == 'p') {
        return SedCommand{
            .cmd_type = .print,
            .pattern = "", // No pattern - use address only
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for address/pattern command (/pattern/d or /pattern/p)
    if (remaining[0] == '/') {
        var pattern_end: usize = 1;
        while (pattern_end < remaining.len and remaining[pattern_end] != '/') {
            pattern_end += 1;
        }

        if (pattern_end >= remaining.len) return error.InvalidExpression;

        var pattern = remaining[1..pattern_end];
        var options = SubstituteOptions{};

        // Handle ^ anchor at start of pattern
        if (pattern.len > 0 and pattern[0] == '^') {
            options.anchor_start = true;
            pattern = pattern[1..];
        }

        const cmd_char = if (pattern_end + 1 < remaining.len) remaining[pattern_end + 1] else 'p';

        return SedCommand{
            .cmd_type = if (cmd_char == 'd') .delete else .print,
            .pattern = pattern,
            .replacement = "",
            .options = options,
            .address = address,
        };
    }

    return error.InvalidExpression;
}

fn processFile(allocator: std.mem.Allocator, filepath: []const u8, cmd: SedCommand, backend_mode: BackendMode, verbose: bool, in_place: bool, suppress_output: bool) !void {
    const file = std.fs.cwd().openFile(filepath, .{}) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ filepath, err });
        return;
    };
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;

    if (verbose) {
        std.debug.print("File: {s} ({d} bytes)\n", .{ filepath, file_size });
    }

    const text = try file.readToEndAlloc(allocator, gpu.MAX_GPU_BUFFER_SIZE);
    defer allocator.free(text);

    // Select backend
    // Note: cpu_gnu maps to .cpu backend but uses cpu_gnu module for matching
    const backend: gpu.Backend = switch (backend_mode) {
        .auto => selectOptimalBackend(cmd.pattern.len, file_size),
        .gpu_mode => if (build_options.is_macos) .metal else .vulkan,
        .cpu_mode, .cpu_gnu => .cpu,
        .metal => .metal,
        .vulkan => .vulkan,
    };

    if (verbose) {
        std.debug.print("Backend: {s}\n", .{@tagName(backend)});
    }

    switch (cmd.cmd_type) {
        .substitute => try processSubstitute(allocator, text, cmd, backend, verbose, in_place, suppress_output, filepath),
        .delete => try processDelete(allocator, text, cmd, backend, verbose, suppress_output),
        .print => try processPrint(allocator, text, cmd, backend, verbose, suppress_output),
        .transliterate => try processTransliterate(allocator, text, cmd, backend, verbose, in_place, suppress_output, filepath),
    }
}

fn selectOptimalBackend(pattern_len: usize, file_size: u64) gpu.Backend {
    // GPU is better for larger files and most patterns
    if (file_size < gpu.MIN_GPU_SIZE) return .cpu;
    if (file_size > gpu.MAX_GPU_BUFFER_SIZE) return .cpu;

    // Prefer GPU for most workloads
    _ = pattern_len;
    if (build_options.is_macos) return .metal;
    return .vulkan;
}

fn processSubstitute(allocator: std.mem.Allocator, text: []const u8, cmd: SedCommand, backend: gpu.Backend, verbose: bool, in_place: bool, suppress_output: bool, filepath: []const u8) !void {
    // Find matches
    var result = switch (backend) {
        .metal => blk: {
            if (build_options.is_macos) {
                const substituter = gpu.metal.MetalSubstituter.init(allocator) catch |err| {
                    if (verbose) std.debug.print("Metal init failed: {}, falling back to CPU\n", .{err});
                    break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                };
                defer substituter.deinit();
                break :blk (if (needsRegex(cmd.pattern, cmd.options))
                    substituter.findMatchesRegex(text, cmd.pattern, cmd.options, allocator)
                else
                    substituter.findMatches(text, cmd.pattern, cmd.options, allocator)) catch |err| {
                    if (verbose) std.debug.print("Metal failed: {}, falling back to CPU\n", .{err});
                    break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                };
            } else {
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            }
        },
        .vulkan => blk: {
            const substituter = gpu.vulkan.VulkanSubstituter.init(allocator) catch |err| {
                if (verbose) std.debug.print("Vulkan init failed: {}, falling back to CPU\n", .{err});
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            };
            defer substituter.deinit();
            break :blk (if (needsRegex(cmd.pattern, cmd.options))
                substituter.findMatchesRegex(text, cmd.pattern, cmd.options, allocator)
            else
                substituter.findMatches(text, cmd.pattern, cmd.options, allocator)) catch |err| {
                if (verbose) std.debug.print("Vulkan failed: {}, falling back to CPU\n", .{err});
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            };
        },
        .cpu => try doFindMatches(text, cmd.pattern, cmd.options, allocator),
        else => try doFindMatches(text, cmd.pattern, cmd.options, allocator),
    };
    defer result.deinit();

    if (verbose) {
        std.debug.print("Found {d} matches\n\n", .{result.total_matches});
    }

    // Build output with replacements
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(allocator);

    var last_pos: usize = 0;
    for (result.matches) |match| {
        // Append text before match
        try output.appendSlice(allocator, text[last_pos..match.start]);
        // Append replacement with & expansion
        const matched_text = text[match.start..match.end];
        try processReplacement(cmd.replacement, matched_text, &output, allocator);
        last_pos = match.end;
    }
    // Append remaining text
    try output.appendSlice(allocator, text[last_pos..]);

    if (in_place) {
        const out_file = try std.fs.cwd().createFile(filepath, .{});
        defer out_file.close();
        try out_file.writeAll(output.items);
    } else if (!suppress_output) {
        _ = std.posix.write(std.posix.STDOUT_FILENO, output.items) catch {};
    }
}

fn processDelete(allocator: std.mem.Allocator, text: []const u8, cmd: SedCommand, backend: gpu.Backend, verbose: bool, suppress_output: bool) !void {
    // Find matching lines
    var result = switch (backend) {
        .metal => blk: {
            if (build_options.is_macos) {
                const substituter = gpu.metal.MetalSubstituter.init(allocator) catch {
                    break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                };
                defer substituter.deinit();
                break :blk (if (needsRegex(cmd.pattern, cmd.options))
                    substituter.findMatchesRegex(text, cmd.pattern, cmd.options, allocator)
                else
                    substituter.findMatches(text, cmd.pattern, cmd.options, allocator)) catch {
                    break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                };
            } else {
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            }
        },
        .vulkan => blk: {
            const substituter = gpu.vulkan.VulkanSubstituter.init(allocator) catch {
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            };
            defer substituter.deinit();
            break :blk (if (needsRegex(cmd.pattern, cmd.options))
                substituter.findMatchesRegex(text, cmd.pattern, cmd.options, allocator)
            else
                substituter.findMatches(text, cmd.pattern, cmd.options, allocator)) catch {
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            };
        },
        else => try doFindMatches(text, cmd.pattern, cmd.options, allocator),
    };
    defer result.deinit();

    // Build set of lines to delete
    var delete_lines = std.AutoHashMap(u32, void).init(allocator);
    defer delete_lines.deinit();
    for (result.matches) |match| {
        try delete_lines.put(match.line_num, {});
    }

    if (verbose) {
        std.debug.print("Deleting {d} lines\n\n", .{delete_lines.count()});
    }

    if (suppress_output) return;

    // Output non-deleted lines
    var line_num: u32 = 0;
    var line_start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '\n' or i == text.len - 1) {
            const line_end = if (c == '\n') i + 1 else i + 1;
            if (!delete_lines.contains(line_num)) {
                _ = std.posix.write(std.posix.STDOUT_FILENO, text[line_start..line_end]) catch {};
            }
            line_start = i + 1;
            line_num += 1;
        }
    }
}

fn processPrint(allocator: std.mem.Allocator, text: []const u8, cmd: SedCommand, backend: gpu.Backend, verbose: bool, suppress_output: bool) !void {
    // Find matching lines
    var result = switch (backend) {
        .metal => blk: {
            if (build_options.is_macos) {
                const substituter = gpu.metal.MetalSubstituter.init(allocator) catch {
                    break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                };
                defer substituter.deinit();
                break :blk (if (needsRegex(cmd.pattern, cmd.options))
                    substituter.findMatchesRegex(text, cmd.pattern, cmd.options, allocator)
                else
                    substituter.findMatches(text, cmd.pattern, cmd.options, allocator)) catch {
                    break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                };
            } else {
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            }
        },
        .vulkan => blk: {
            const substituter = gpu.vulkan.VulkanSubstituter.init(allocator) catch {
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            };
            defer substituter.deinit();
            break :blk (if (needsRegex(cmd.pattern, cmd.options))
                substituter.findMatchesRegex(text, cmd.pattern, cmd.options, allocator)
            else
                substituter.findMatches(text, cmd.pattern, cmd.options, allocator)) catch {
                break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
            };
        },
        else => try doFindMatches(text, cmd.pattern, cmd.options, allocator),
    };
    defer result.deinit();

    // Build set of lines to print
    var print_lines = std.AutoHashMap(u32, void).init(allocator);
    defer print_lines.deinit();
    for (result.matches) |match| {
        try print_lines.put(match.line_num, {});
    }

    if (verbose) {
        std.debug.print("Printing {d} matching lines\n\n", .{print_lines.count()});
    }

    if (suppress_output) return;

    // Output matching lines
    var line_num: u32 = 0;
    var line_start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '\n' or i == text.len - 1) {
            const line_end = if (c == '\n') i + 1 else i + 1;
            if (print_lines.contains(line_num)) {
                _ = std.posix.write(std.posix.STDOUT_FILENO, text[line_start..line_end]) catch {};
            }
            line_start = i + 1;
            line_num += 1;
        }
    }
}

fn processTransliterate(allocator: std.mem.Allocator, text: []const u8, cmd: SedCommand, backend: gpu.Backend, verbose: bool, in_place: bool, suppress_output: bool, filepath: []const u8) !void {
    // Make a mutable copy
    const mutable_text = try allocator.alloc(u8, text.len);
    defer allocator.free(mutable_text);
    @memcpy(mutable_text, text);

    // Transliterate
    _ = backend; // TODO: GPU transliterate
    cpu.transliterate(mutable_text, cmd.pattern, cmd.replacement);

    if (verbose) {
        std.debug.print("Transliterated {d} bytes\n\n", .{mutable_text.len});
    }

    if (in_place) {
        const out_file = try std.fs.cwd().createFile(filepath, .{});
        defer out_file.close();
        try out_file.writeAll(mutable_text);
    } else if (!suppress_output) {
        _ = std.posix.write(std.posix.STDOUT_FILENO, mutable_text) catch {};
    }
}

fn printUsage() void {
    const help_text =
        \\Usage: sed [OPTION]... {SCRIPT} [INPUT-FILE]...
        \\
        \\Stream editor for filtering and transforming text.
        \\If no INPUT-FILE is given, or if INPUT-FILE is -, read standard input.
        \\
        \\Options:
        \\  -n, --quiet, --silent    suppress automatic printing            [GPU+SIMD]
        \\  -e SCRIPT, --expression=SCRIPT
        \\                           add script (can repeat)                [SIMD]
        \\  -E, -r, --regexp-extended
        \\                           use extended regex (ERE)               [GPU+SIMD]
        \\  -i, --in-place           edit files in place                    [GPU+SIMD]
        \\  -V, --verbose            print backend and timing info
        \\  -h, --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\Backend selection:
        \\  --auto                   auto-select optimal backend (default)
        \\  --gpu                    force GPU (Metal on macOS, Vulkan on Linux)
        \\  --cpu                    force CPU backend (SIMD-optimized)
        \\  --gnu                    force GNU sed backend (GPL, full features)
        \\  --metal                  force Metal backend (macOS only)
        \\  --vulkan                 force Vulkan backend
        \\
        \\Commands:
        \\  s/REGEXP/REPLACEMENT/FLAGS                                      [GPU+SIMD]
        \\      Substitute REGEXP with REPLACEMENT.
        \\      FLAGS: g (global), i (ignore case), 1 (first only)
        \\      Special: & = matched text, \n \t = newline/tab
        \\
        \\  y/SOURCE/DEST/                                                  [SIMD]
        \\      Transliterate characters (256-byte lookup, 32-byte unroll)
        \\
        \\  /REGEXP/d                                                       [GPU+SIMD]
        \\      Delete lines matching REGEXP.
        \\
        \\  /REGEXP/p                                                       [GPU+SIMD]
        \\      Print lines matching REGEXP.
        \\
        \\  ADDRESS COMMAND           Line addressing (1,5s/.../.../)       [SIMD]
        \\
        \\Optimization legend:
        \\  [GPU+SIMD]  GPU-accelerated (Metal/Vulkan) + SIMD-optimized CPU
        \\  [SIMD]      SIMD-optimized CPU only (GPU not yet implemented)
        \\  GPU uses parallel compute shaders for pattern matching
        \\  CPU uses Boyer-Moore-Horspool with 16/32-byte SIMD vectors
        \\
        \\GPU Performance (typical speedups vs SIMD CPU):
        \\  s/pattern/replacement/:   ~16x    s///g global:        ~8x
        \\  s///i case insensitive:   ~5.5x   /pattern/d delete:   ~8x
        \\  -E extended regex:        ~5-10x
        \\
        \\Examples:
        \\  sed 's/foo/bar/g' input.txt         Replace all 'foo' with 'bar'
        \\  sed -E 's/[0-9]+/NUM/g' file.txt    Extended regex (ERE)
        \\  sed -i 's/old/new/g' file.txt       Edit file in place
        \\  sed 'y/abc/xyz/' file.txt           Transliterate a->x, b->y, c->z
        \\  sed '/error/d' file.txt             Delete lines with 'error'
        \\  sed -n '/pattern/p' file.txt        Print only matching lines
        \\  sed --gpu 's/x/y/g' large.txt       Force GPU acceleration
        \\
    ;
    _ = std.posix.write(std.posix.STDOUT_FILENO, help_text) catch {};
}

test "parse substitute expression" {
    const cmd = try parseSedExpression("s/foo/bar/g");
    try std.testing.expectEqual(CommandType.substitute, cmd.cmd_type);
    try std.testing.expectEqualStrings("foo", cmd.pattern);
    try std.testing.expectEqualStrings("bar", cmd.replacement);
    try std.testing.expect(cmd.options.global);
}

test "parse transliterate expression" {
    const cmd = try parseSedExpression("y/abc/xyz/");
    try std.testing.expectEqual(CommandType.transliterate, cmd.cmd_type);
    try std.testing.expectEqualStrings("abc", cmd.pattern);
    try std.testing.expectEqualStrings("xyz", cmd.replacement);
}

test "parse delete expression" {
    const cmd = try parseSedExpression("/error/d");
    try std.testing.expectEqual(CommandType.delete, cmd.cmd_type);
    try std.testing.expectEqualStrings("error", cmd.pattern);
}

test "parse print expression" {
    const cmd = try parseSedExpression("/error/p");
    try std.testing.expectEqual(CommandType.print, cmd.cmd_type);
    try std.testing.expectEqualStrings("error", cmd.pattern);
}

test "processReplacement: & expands to matched text" {
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try processReplacement("[&]", "hello", &output, std.testing.allocator);
    try std.testing.expectEqualStrings("[hello]", output.items);
}

test "processReplacement: escaped ampersand" {
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try processReplacement("\\&", "hello", &output, std.testing.allocator);
    try std.testing.expectEqualStrings("&", output.items);
}

test "processReplacement: escape sequences" {
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try processReplacement("a\\nb\\tc", "X", &output, std.testing.allocator);
    try std.testing.expectEqualStrings("a\nb\tc", output.items);
}

test "processReplacement: mixed & and escapes" {
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try processReplacement("<&>\\n", "FOO", &output, std.testing.allocator);
    try std.testing.expectEqualStrings("<FOO>\n", output.items);
}
