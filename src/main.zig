const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");
const cpu_gnu = @import("cpu_gnu");

const SubstituteOptions = gpu.SubstituteOptions;

/// Unescape sed pattern escape sequences (\n -> newline, \t -> tab, etc.)
fn unescapePattern(allocator: std.mem.Allocator, pattern: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1;
            switch (pattern[i]) {
                'n' => try result.append(allocator, '\n'),
                't' => try result.append(allocator, '\t'),
                'r' => try result.append(allocator, '\r'),
                '\\' => try result.append(allocator, '\\'),
                else => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, pattern[i]);
                },
            }
        } else {
            try result.append(allocator, pattern[i]);
        }
    }
    return result.toOwnedSlice(allocator);
}

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
    read_file, // r file - append file contents after matching lines
    write_file, // w file - write matching lines to file
    next, // n - read next line into pattern space
    append_next, // N - append next line to pattern space
    quit, // q - quit immediately
    line_number, // = - print current line number
    append_text, // a\ text - append text after line
    insert_text, // i\ text - insert text before line
    change_text, // c\ text - replace line with text
    hold, // h - copy pattern space to hold space
    get_hold, // g - copy hold space to pattern space
    append_hold, // H - append pattern space to hold space
    get_append_hold, // G - append hold space to pattern space
    exchange, // x - exchange pattern space and hold space
    label, // :label - define a branch target
    branch, // t label - branch to label if last s succeeded
    branch_not, // T label - branch to label if last s failed
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
    file_path: []const u8 = "", // For r/w commands
    text: []const u8 = "", // For a/i/c commands
    label: []const u8 = "", // For :/t/T commands
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
    var in_place_suffix: ?[]const u8 = null;
    var suppress_output = false;
    var use_extended_regex = false; // ERE mode (-E/-r)
    var saw_explicit_expr = false; // Track if -e was used
    var null_data = false; // -z: use NUL as line delimiter
    var unbuffered = false; // -u: unbuffered output

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
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            if (i + 1 < args.len) {
                i += 1;
                const file = std.fs.cwd().openFile(args[i], .{}) catch |err| {
                    std.debug.print("sed: {s}: {}\n", .{ args[i], err });
                    return;
                };
                defer file.close();
                const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
                    std.debug.print("sed: {s}: {}\n", .{ args[i], err });
                    return;
                };
                defer allocator.free(content);
                var iter = std.mem.splitScalar(u8, content, '\n');
                while (iter.next()) |line| {
                    if (line.len > 0) {
                        try expressions.append(allocator, try allocator.dupe(u8, line));
                    }
                }
                saw_explicit_expr = true;
            }
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
            suppress_output = true;
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--null-data")) {
            null_data = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unbuffered")) {
            unbuffered = true;
        } else if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--regexp-extended")) {
            use_extended_regex = true;
        } else if (std.mem.eql(u8, arg, "-i")) {
            in_place_suffix = "";
        } else if (std.mem.startsWith(u8, arg, "-i")) {
            in_place_suffix = arg[2..]; // -i.bak -> .bak
        } else if (std.mem.eql(u8, arg, "--in-place")) {
            in_place_suffix = "";
        } else if (std.mem.startsWith(u8, arg, "--in-place=")) {
            in_place_suffix = arg["--in-place=".len..];
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

    // Parse all sed expressions (split on ; for multiple commands per expression)
    var commands: std.ArrayListUnmanaged(SedCommand) = .{};
    defer commands.deinit(allocator);

    for (expressions.items) |expr| {
        // Split expression by semicolons, respecting escaped semicolons
        var expr_pos: usize = 0;
        while (expr_pos < expr.len) {
            // Find next unescaped semicolon
            var split_pos = expr_pos;
            while (split_pos < expr.len) {
                if (expr[split_pos] == ';' and (split_pos == 0 or expr[split_pos - 1] != '\\')) {
                    break;
                }
                split_pos += 1;
            }
            const sub_expr = std.mem.trim(u8, expr[expr_pos..split_pos], " \t");
            if (sub_expr.len > 0) {
                var cmd = parseSedExpression(sub_expr) catch |err| {
                    std.debug.print("Error parsing expression '{s}': {}\n", .{ sub_expr, err });
                    return;
                };
                cmd.options.extended = use_extended_regex;
                try commands.append(allocator, cmd);
            }
            expr_pos = split_pos + 1;
        }
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
        try processStdinMulti(allocator, commands.items, backend_mode, verbose, suppress_output, null_data);
    } else {
        for (files.items) |filepath| {
            // Handle "-" as stdin
            if (std.mem.eql(u8, filepath, "-")) {
                try processStdinMulti(allocator, commands.items, backend_mode, verbose, suppress_output, null_data);
            } else {
                try processFileMulti(allocator, filepath, commands.items, backend_mode, verbose, in_place_suffix, suppress_output, null_data);
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

/// Read file contents for sed r command
fn readFileContents(allocator: std.mem.Allocator, filepath: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
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
        .read_file => {
            // Read file contents
            const file_content = readFileContents(allocator, cmd.file_path) catch |err| {
                std.debug.print("sed: {s}: {}\n", .{ cmd.file_path, err });
                return allocator.dupe(u8, text);
            };
            defer allocator.free(file_content);

            var output: std.ArrayListUnmanaged(u8) = .{};
            errdefer output.deinit(allocator);

            // Determine which lines should have file appended
            // If no pattern and no address, append after every line
            var matched_lines = std.AutoHashMap(u32, void).init(allocator);
            defer matched_lines.deinit();

            if (cmd.pattern.len > 0) {
                var result = try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                defer result.deinit();
                for (result.matches) |match| {
                    try matched_lines.put(match.line_num, {});
                }
            }

            const use_address = cmd.address != null;
            const match_all_lines = cmd.pattern.len == 0 and cmd.address == null;

            var line_num: u32 = 1;
            var line_start: usize = 0;
            var i: usize = 0;

            while (i < text.len) : (i += 1) {
                if (text[i] == '\n') {
                    const should_append = match_all_lines or if (use_address) cmd.address.?.matches(line_num, total_lines) else matched_lines.contains(line_num - 1);
                    try output.appendSlice(allocator, text[line_start .. i + 1]);
                    if (should_append) {
                        try output.appendSlice(allocator, file_content);
                        if (file_content.len > 0 and file_content[file_content.len - 1] != '\n') {
                            try output.append(allocator, '\n');
                        }
                    }
                    line_start = i + 1;
                    line_num += 1;
                }
            }
            // Handle last line without newline
            if (line_start < text.len) {
                const should_append = match_all_lines or if (use_address) cmd.address.?.matches(line_num, total_lines) else matched_lines.contains(line_num - 1);
                try output.appendSlice(allocator, text[line_start..]);
                if (should_append) {
                    try output.appendSlice(allocator, file_content);
                }
            }

            return output.toOwnedSlice(allocator);
        },
        .write_file => {
            // Write matching lines to file, return original text unchanged
            var file = std.fs.cwd().createFile(cmd.file_path, .{}) catch |err| {
                std.debug.print("sed: {s}: {}\n", .{ cmd.file_path, err });
                return allocator.dupe(u8, text);
            };
            defer file.close();

            // Determine which lines should be written
            // If no pattern and no address, write all lines
            var matched_lines = std.AutoHashMap(u32, void).init(allocator);
            defer matched_lines.deinit();

            if (cmd.pattern.len > 0) {
                var result = try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                defer result.deinit();
                for (result.matches) |match| {
                    try matched_lines.put(match.line_num, {});
                }
            }

            const use_address = cmd.address != null;
            const match_all_lines = cmd.pattern.len == 0 and cmd.address == null;

            var line_num: u32 = 1;
            var line_start: usize = 0;
            var i: usize = 0;

            while (i < text.len) : (i += 1) {
                if (text[i] == '\n') {
                    const should_write = match_all_lines or if (use_address) cmd.address.?.matches(line_num, total_lines) else matched_lines.contains(line_num - 1);
                    if (should_write) {
                        try file.writeAll(text[line_start .. i + 1]);
                    }
                    line_start = i + 1;
                    line_num += 1;
                }
            }
            // Handle last line without newline
            if (line_start < text.len) {
                const should_write = match_all_lines or if (use_address) cmd.address.?.matches(line_num, total_lines) else matched_lines.contains(line_num - 1);
                if (should_write) {
                    try file.writeAll(text[line_start..]);
                }
            }

            return allocator.dupe(u8, text);
        },
        .next, .append_next, .quit, .line_number,
        .append_text, .insert_text, .change_text,
        .hold, .get_hold, .append_hold, .get_append_hold, .exchange,
        .label, .branch, .branch_not => {
            // These commands require line-by-line processing and should not be called here
            return allocator.dupe(u8, text);
        },
    }
}

/// Process stdin with multiple commands
fn processStdinMulti(allocator: std.mem.Allocator, commands: []const SedCommand, backend_mode: BackendMode, verbose: bool, suppress_output: bool, null_data: bool) !void {
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

    // Use line-by-line processor for n/N/q/= commands
    if (needsLineByLine(commands)) {
        var output_buffer: std.ArrayListUnmanaged(u8) = .{};
        defer output_buffer.deinit(allocator);

        const writer = struct {
            buffer: *std.ArrayListUnmanaged(u8),
            allocator: std.mem.Allocator,
            pub fn writeAll(self: @This(), data: []const u8) !void {
                try self.buffer.appendSlice(self.allocator, data);
            }
        }{ .buffer = &output_buffer, .allocator = allocator };

        try processLineByLine(allocator, stdin_list.items, commands, backend_mode, verbose, suppress_output, null_data, writer);

        if (!suppress_output) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, output_buffer.items) catch {};
        }
        return;
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

/// Check if commands require line-by-line processing
fn needsLineByLine(commands: []const SedCommand) bool {
    for (commands) |cmd| {
        switch (cmd.cmd_type) {
            .next, .append_next, .quit, .line_number,
            .append_text, .insert_text, .change_text,
            .hold, .get_hold, .append_hold, .get_append_hold, .exchange,
            .label, .branch, .branch_not => return true,
            else => {},
        }
    }
    return false;
}

/// Process text line-by-line with sed commands
fn processLineByLine(allocator: std.mem.Allocator, text: []const u8, commands: []const SedCommand, _backend_mode: BackendMode, verbose: bool, suppress_output: bool, null_data: bool, out_writer: anytype) !void {
    _ = _backend_mode;
    const line_delim: u8 = if (null_data) 0 else '\n';
    var line_num: u32 = 1;
    var pos: usize = 0;
    var quit_requested = false;

    // Hold space persists across lines
    var hold_space: std.ArrayListUnmanaged(u8) = .{};
    defer hold_space.deinit(allocator);

    // Build label map for branch commands
    var label_map: std.StringHashMapUnmanaged(usize) = .{};
    defer {
        var it = label_map.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        label_map.deinit(allocator);
    }
    for (commands, 0..) |cmd, idx| {
        if (cmd.cmd_type == .label and cmd.label.len > 0) {
            const key = try allocator.dupe(u8, cmd.label);
            try label_map.put(allocator, key, idx);
        }
    }

    while (pos < text.len and !quit_requested) {
        // Find end of current line
        var line_end = pos;
        while (line_end < text.len and text[line_end] != line_delim) line_end += 1;

        var has_delim = line_end < text.len;
        const line = text[pos..line_end];

        // Pattern space starts with current line
        var pattern_space: std.ArrayListUnmanaged(u8) = .{};
        defer pattern_space.deinit(allocator);
        try pattern_space.appendSlice(allocator, line);

        // Track if we should auto-print this line
        var should_print = !suppress_output;
        var skip_to_next = false;
        var manual_advance = false; // Set by n/N to prevent double-advance
        var insert_texts: std.ArrayListUnmanaged([]const u8) = .{};
        defer insert_texts.deinit(allocator);
        var append_texts: std.ArrayListUnmanaged([]const u8) = .{};
        defer append_texts.deinit(allocator);
        var change_text: ?[]const u8 = null;
        var last_substitute_succeeded = false;

        // Apply each command to the pattern space
        var cmd_idx: usize = 0;
        while (cmd_idx < commands.len) {
            const cmd = commands[cmd_idx];
            if (skip_to_next or quit_requested) break;

            // Check if address matches
            const total_lines = countLines(text); // Approximate
            const address_matches = if (cmd.address) |addr| addr.matches(line_num, total_lines) else true;
            if (!address_matches) {
                cmd_idx += 1;
                continue;
            }

            if (verbose) {
                std.debug.print("Command [{d}]: {s}, Line: {d}\n", .{ cmd_idx, @tagName(cmd.cmd_type), line_num });
            }

            switch (cmd.cmd_type) {
                .label => {
                    // No-op: label definition
                },
                .branch => {
                    // t label: branch if last substitute succeeded
                    if (last_substitute_succeeded) {
                        if (cmd.label.len > 0) {
                            if (label_map.get(cmd.label)) |target_idx| {
                                cmd_idx = target_idx;
                                last_substitute_succeeded = false;
                                continue;
                            }
                        } else {
                            // t with no label = jump to end of script
                            break;
                        }
                    }
                    last_substitute_succeeded = false;
                },
                .branch_not => {
                    // T label: branch if last substitute failed
                    if (!last_substitute_succeeded) {
                        if (cmd.label.len > 0) {
                            if (label_map.get(cmd.label)) |target_idx| {
                                cmd_idx = target_idx;
                                last_substitute_succeeded = false;
                                continue;
                            }
                        } else {
                            // T with no label = jump to end of script
                            break;
                        }
                    }
                    last_substitute_succeeded = false;
                },
                .substitute => {
                    const search_pattern = if (std.mem.indexOfScalar(u8, cmd.pattern, '\\') != null)
                        try unescapePattern(allocator, cmd.pattern)
                    else
                        cmd.pattern;
                    defer if (search_pattern.ptr != cmd.pattern.ptr) allocator.free(search_pattern);
                    var result = try doFindMatches(pattern_space.items, search_pattern, cmd.options, allocator);
                    defer result.deinit();
                    var new_space: std.ArrayListUnmanaged(u8) = .{};
                    errdefer new_space.deinit(allocator);
                    var last_p: usize = 0;
                    for (result.matches) |match| {
                        try new_space.appendSlice(allocator, pattern_space.items[last_p..match.start]);
                        const matched_text = pattern_space.items[match.start..match.end];
                        try processReplacement(cmd.replacement, matched_text, &new_space, allocator);
                        last_p = match.end;
                    }
                    try new_space.appendSlice(allocator, pattern_space.items[last_p..]);
                    pattern_space.deinit(allocator);
                    pattern_space = new_space;
                    last_substitute_succeeded = result.matches.len > 0;
                },
                .delete => {
                    pattern_space.clearRetainingCapacity();
                    should_print = false;
                    skip_to_next = true;
                    if (manual_advance) {
                        // d after n/N: skip the loaded line and continue to next
                        manual_advance = false;
                        if (has_delim) {
                            pos = line_end + 1;
                            line_num += 1;
                        }
                    }
                },
                .print => {
                    try out_writer.writeAll(pattern_space.items);
                    if (has_delim) try out_writer.writeAll(&[_]u8{line_delim});
                },
                .transliterate => {
                    for (pattern_space.items) |*c| {
                        for (cmd.pattern, 0..) |src, j| {
                            if (c.* == src and j < cmd.replacement.len) {
                                c.* = cmd.replacement[j];
                                break;
                            }
                        }
                    }
                },
                .read_file => {
                    if (cmd.file_path.len > 0) {
                        const content = readFileContents(allocator, cmd.file_path) catch "";
                        defer if (content.len > 0) allocator.free(content);
                        try out_writer.writeAll(pattern_space.items);
                        if (has_delim) try out_writer.writeAll(&[_]u8{line_delim});
                        try out_writer.writeAll(content);
                        if (content.len > 0 and content[content.len - 1] != line_delim) {
                            try out_writer.writeAll(&[_]u8{line_delim});
                        }
                        should_print = false;
                        skip_to_next = true;
                    }
                },
                .write_file => {
                    if (cmd.file_path.len > 0) {
                        var f = std.fs.cwd().createFile(cmd.file_path, .{ .truncate = false }) catch |err| {
                            std.debug.print("sed: {s}: {}\n", .{ cmd.file_path, err });
                            continue;
                        };
                        defer f.close();
                        try f.writeAll(pattern_space.items);
                        if (has_delim) try f.writeAll(&[_]u8{line_delim});
                    }
                },
                .next => {
                    if (should_print) {
                        try out_writer.writeAll(pattern_space.items);
                        if (has_delim) try out_writer.writeAll(&[_]u8{line_delim});
                    }
                    // Read next line into pattern space
                    if (has_delim) {
                        pos = line_end + 1;
                        line_num += 1;
                        // Find next line end
                        var next_end = pos;
                        while (next_end < text.len and text[next_end] != line_delim) next_end += 1;
                        pattern_space.clearRetainingCapacity();
                        try pattern_space.appendSlice(allocator, text[pos..next_end]);
                        line_end = next_end;
                        has_delim = line_end < text.len;
                        manual_advance = true;
                    }
                    should_print = !suppress_output;
                },
                .append_next => {
                    // Append next line to pattern space
                    if (has_delim and line_end + 1 < text.len) {
                        try pattern_space.append(allocator, line_delim);
                        var next_end = line_end + 1;
                        while (next_end < text.len and text[next_end] != line_delim) next_end += 1;
                        try pattern_space.appendSlice(allocator, text[line_end + 1 .. next_end]);
                        line_end = next_end;
                        has_delim = line_end < text.len;
                    }
                },
                .quit => {
                    quit_requested = true;
                },
                .line_number => {
                    var num_buf: [16]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch "";
                    try out_writer.writeAll(num_str);
                    try out_writer.writeAll(&[_]u8{line_delim});
                },
                .append_text => {
                    if (cmd.text.len > 0) {
                        try append_texts.append(allocator, cmd.text);
                    }
                },
                .insert_text => {
                    if (cmd.text.len > 0) {
                        try insert_texts.append(allocator, cmd.text);
                    }
                },
                .change_text => {
                    if (cmd.text.len > 0) {
                        change_text = cmd.text;
                    }
                    pattern_space.clearRetainingCapacity();
                    should_print = false;
                    skip_to_next = true;
                },
                .hold => {
                    hold_space.clearRetainingCapacity();
                    try hold_space.appendSlice(allocator, pattern_space.items);
                },
                .append_hold => {
                    try hold_space.append(allocator, line_delim);
                    try hold_space.appendSlice(allocator, pattern_space.items);
                },
                .get_hold => {
                    pattern_space.clearRetainingCapacity();
                    try pattern_space.appendSlice(allocator, hold_space.items);
                },
                .get_append_hold => {
                    if (hold_space.items.len > 0) {
                        try pattern_space.append(allocator, line_delim);
                        try pattern_space.appendSlice(allocator, hold_space.items);
                    }
                },
                .exchange => {
                    const tmp = try allocator.dupe(u8, pattern_space.items);
                    defer allocator.free(tmp);
                    pattern_space.clearRetainingCapacity();
                    try pattern_space.appendSlice(allocator, hold_space.items);
                    hold_space.clearRetainingCapacity();
                    try hold_space.appendSlice(allocator, tmp);
                },
            }
            cmd_idx += 1;
        }

        // Output insert texts before the line
        for (insert_texts.items) |txt| {
            try out_writer.writeAll(txt);
            try out_writer.writeAll(&[_]u8{line_delim});
        }

        // Auto-print pattern space if not suppressed and not already printed
        if (should_print and !skip_to_next) {
            try out_writer.writeAll(pattern_space.items);
            if (has_delim) try out_writer.writeAll(&[_]u8{line_delim});
        }

        // Output change text (replaces the line)
        if (change_text) |txt| {
            try out_writer.writeAll(txt);
            try out_writer.writeAll(&[_]u8{line_delim});
        }

        // Output append texts after the line
        for (append_texts.items) |txt| {
            try out_writer.writeAll(txt);
            try out_writer.writeAll(&[_]u8{line_delim});
        }

        if (manual_advance) {
            // n/N already advanced pos and line_end; just continue
            continue;
        } else if (has_delim) {
            pos = line_end + 1;
            line_num += 1;
        } else {
            break;
        }
    }
}

/// Process file with multiple commands
fn processFileMulti(allocator: std.mem.Allocator, filepath: []const u8, commands: []const SedCommand, backend_mode: BackendMode, verbose: bool, in_place_suffix: ?[]const u8, suppress_output: bool, null_data: bool) !void {
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

    // Use line-by-line processor for n/N/q/= commands
    if (needsLineByLine(commands)) {
        var output_buffer: std.ArrayListUnmanaged(u8) = .{};
        defer output_buffer.deinit(allocator);

        const writer = struct {
            buffer: *std.ArrayListUnmanaged(u8),
            allocator: std.mem.Allocator,
            pub fn writeAll(self: @This(), data: []const u8) !void {
                try self.buffer.appendSlice(self.allocator, data);
            }
        }{ .buffer = &output_buffer, .allocator = allocator };

        try processLineByLine(allocator, original_text, commands, backend_mode, verbose, suppress_output, null_data, writer);
        allocator.free(original_text);

        // Write output
        if (in_place_suffix) |suffix| {
            if (suffix.len > 0) {
                const backup_path = try std.mem.concat(allocator, u8, &.{ filepath, suffix });
                defer allocator.free(backup_path);
                try std.fs.cwd().copyFile(filepath, std.fs.cwd(), backup_path, .{});
            }
            const out_file = try std.fs.cwd().createFile(filepath, .{});
            defer out_file.close();
            try out_file.writeAll(output_buffer.items);
        } else if (!suppress_output) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, output_buffer.items) catch {};
        }
        return;
    }

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
    if (in_place_suffix) |suffix| {
        // Create backup if suffix is non-empty
        if (suffix.len > 0) {
            const backup_path = try std.mem.concat(allocator, u8, &.{ filepath, suffix });
            defer allocator.free(backup_path);
            try std.fs.cwd().copyFile(filepath, std.fs.cwd(), backup_path, .{});
        }
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

    // Check for label definition (:label) — no address allowed
    if (expr[0] == ':') {
        const label_name = std.mem.trimLeft(u8, expr[1..], " \t");
        return SedCommand{
            .cmd_type = .label,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .label = label_name,
        };
    }

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

    // Check for 'r FILE' (read file and append after matching lines)
    if (remaining[0] == 'r') {
        const file_path = if (remaining.len > 1) std.mem.trimLeft(u8, remaining[1..], " ") else "";
        return SedCommand{
            .cmd_type = .read_file,
            .pattern = "", // No pattern - use address only
            .replacement = "",
            .options = .{},
            .address = address,
            .file_path = file_path,
        };
    }

    // Check for 'w FILE' (write matching lines to file)
    if (remaining[0] == 'w') {
        const file_path = if (remaining.len > 1) std.mem.trimLeft(u8, remaining[1..], " ") else "";
        return SedCommand{
            .cmd_type = .write_file,
            .pattern = "", // No pattern - use address only
            .replacement = "",
            .options = .{},
            .address = address,
            .file_path = file_path,
        };
    }

    // Check for 'n' (next line)
    if (remaining[0] == 'n') {
        return SedCommand{
            .cmd_type = .next,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for 'N' (append next line)
    if (remaining[0] == 'N') {
        return SedCommand{
            .cmd_type = .append_next,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for 'q' (quit)
    if (remaining[0] == 'q') {
        return SedCommand{
            .cmd_type = .quit,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for '=' (line number)
    if (remaining[0] == '=') {
        return SedCommand{
            .cmd_type = .line_number,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for 'a' (append text after line)
    if (remaining[0] == 'a') {
        const text = if (remaining.len > 1) std.mem.trimLeft(u8, remaining[1..], " \\") else "";
        return SedCommand{
            .cmd_type = .append_text,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
            .text = text,
        };
    }

    // Check for 'i' (insert text before line)
    if (remaining[0] == 'i') {
        const text = if (remaining.len > 1) std.mem.trimLeft(u8, remaining[1..], " \\") else "";
        return SedCommand{
            .cmd_type = .insert_text,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
            .text = text,
        };
    }

    // Check for 'c' (change line to text)
    if (remaining[0] == 'c') {
        const text = if (remaining.len > 1) std.mem.trimLeft(u8, remaining[1..], " \\") else "";
        return SedCommand{
            .cmd_type = .change_text,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
            .text = text,
        };
    }

    // Check for 'h' (copy pattern space to hold space)
    if (remaining[0] == 'h') {
        return SedCommand{
            .cmd_type = .hold,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for 'H' (append pattern space to hold space)
    if (remaining[0] == 'H') {
        return SedCommand{
            .cmd_type = .append_hold,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for 'g' (copy hold space to pattern space)
    if (remaining[0] == 'g') {
        return SedCommand{
            .cmd_type = .get_hold,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for 'G' (append hold space to pattern space)
    if (remaining[0] == 'G') {
        return SedCommand{
            .cmd_type = .get_append_hold,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for 'x' (exchange pattern space and hold space)
    if (remaining[0] == 'x') {
        return SedCommand{
            .cmd_type = .exchange,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
        };
    }

    // Check for 't' (branch to label if last substitute succeeded)
    if (remaining[0] == 't') {
        const label_name = if (remaining.len > 1) std.mem.trimLeft(u8, remaining[1..], " \t") else "";
        return SedCommand{
            .cmd_type = .branch,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
            .label = label_name,
        };
    }

    // Check for 'T' (branch to label if last substitute failed)
    if (remaining[0] == 'T') {
        const label_name = if (remaining.len > 1) std.mem.trimLeft(u8, remaining[1..], " \t") else "";
        return SedCommand{
            .cmd_type = .branch_not,
            .pattern = "",
            .replacement = "",
            .options = .{},
            .address = address,
            .label = label_name,
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

        if (cmd_char == 'r') {
            const file_path = if (pattern_end + 2 < remaining.len) std.mem.trimLeft(u8, remaining[pattern_end + 2 ..], " ") else "";
            return SedCommand{
                .cmd_type = .read_file,
                .pattern = pattern,
                .replacement = "",
                .options = options,
                .address = address,
                .file_path = file_path,
            };
        } else if (cmd_char == 'w') {
            const file_path = if (pattern_end + 2 < remaining.len) std.mem.trimLeft(u8, remaining[pattern_end + 2 ..], " ") else "";
            return SedCommand{
                .cmd_type = .write_file,
                .pattern = pattern,
                .replacement = "",
                .options = options,
                .address = address,
                .file_path = file_path,
            };
        }

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

fn processFile(allocator: std.mem.Allocator, filepath: []const u8, cmd: SedCommand, backend_mode: BackendMode, verbose: bool, in_place_suffix: ?[]const u8, suppress_output: bool) !void {
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
        .substitute => try processSubstitute(allocator, text, cmd, backend, verbose, in_place_suffix, suppress_output, filepath),
        .delete => try processDelete(allocator, text, cmd, backend, verbose, suppress_output),
        .print => try processPrint(allocator, text, cmd, backend, verbose, suppress_output),
        .transliterate => try processTransliterate(allocator, text, cmd, backend, verbose, in_place_suffix, suppress_output, filepath),
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

fn processSubstitute(allocator: std.mem.Allocator, text: []const u8, cmd: SedCommand, backend: gpu.Backend, verbose: bool, in_place_suffix: ?[]const u8, suppress_output: bool, filepath: []const u8) !void {
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

    if (in_place_suffix) |suffix| {
        // Create backup if suffix is non-empty
        if (suffix.len > 0) {
            const backup_path = try std.mem.concat(allocator, u8, &.{ filepath, suffix });
            defer allocator.free(backup_path);
            try std.fs.cwd().copyFile(filepath, std.fs.cwd(), backup_path, .{});
        }
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

fn processTransliterate(allocator: std.mem.Allocator, text: []const u8, cmd: SedCommand, backend: gpu.Backend, verbose: bool, in_place_suffix: ?[]const u8, suppress_output: bool, filepath: []const u8) !void {
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

    if (in_place_suffix) |suffix| {
        // Create backup if suffix is non-empty
        if (suffix.len > 0) {
            const backup_path = try std.mem.concat(allocator, u8, &.{ filepath, suffix });
            defer allocator.free(backup_path);
            try std.fs.cwd().copyFile(filepath, std.fs.cwd(), backup_path, .{});
        }
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
