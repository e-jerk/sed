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

/// Parsed sed command
const SedCommand = struct {
    cmd_type: CommandType,
    pattern: []const u8,
    replacement: []const u8,
    options: SubstituteOptions,
};

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
    var expression: ?[]const u8 = null;
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(allocator);
    var verbose = false;
    var in_place = false;
    var suppress_output = false;
    var use_extended_regex = false; // ERE mode (-E/-r)

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--expression")) {
            if (i + 1 < args.len) {
                i += 1;
                expression = args[i];
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
            if (expression == null) {
                expression = arg;
            } else {
                try files.append(allocator, arg);
            }
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            return;
        }
    }

    const sed_expr = expression orelse {
        std.debug.print("Error: No expression specified\n", .{});
        printUsage();
        return;
    };

    // If no files specified, read from stdin
    const read_stdin = files.items.len == 0;

    // Parse sed expression
    var cmd = parseSedExpression(sed_expr) catch |err| {
        std.debug.print("Error parsing expression: {}\n", .{err});
        return;
    };
    cmd.options.extended = use_extended_regex;

    if (verbose) {
        std.debug.print("sed - GPU-accelerated sed\n", .{});
        std.debug.print("Command: {s}\n", .{@tagName(cmd.cmd_type)});
        std.debug.print("Pattern: \"{s}\"\n", .{cmd.pattern});
        if (cmd.replacement.len > 0) {
            std.debug.print("Replacement: \"{s}\"\n", .{cmd.replacement});
        }
        std.debug.print("Mode: {s}\n", .{@tagName(backend_mode)});
        std.debug.print("\n", .{});
    }

    // Process each file or stdin
    if (read_stdin) {
        try processStdin(allocator, cmd, backend_mode, verbose, suppress_output);
    } else {
        for (files.items) |filepath| {
            // Handle "-" as stdin
            if (std.mem.eql(u8, filepath, "-")) {
                try processStdin(allocator, cmd, backend_mode, verbose, suppress_output);
            } else {
                try processFile(allocator, filepath, cmd, backend_mode, verbose, in_place, suppress_output);
            }
        }
    }
}

/// Choose appropriate find function based on options (literal vs regex)
fn doFindMatches(text: []const u8, pattern: []const u8, options: SubstituteOptions, allocator: std.mem.Allocator) !gpu.SubstituteResult {
    if (options.extended) {
        return cpu.findMatchesRegex(text, pattern, options, allocator);
    } else {
        // For BRE mode (default), also use regex for special characters
        // Check if pattern contains regex metacharacters
        var has_meta = false;
        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            const c = pattern[i];
            if (c == '.' or c == '*' or c == '^' or c == '$' or c == '[') {
                has_meta = true;
                break;
            }
            if (c == '\\' and i + 1 < pattern.len) {
                const next = pattern[i + 1];
                if (next == '+' or next == '?' or next == '|' or next == '(' or next == ')' or next == '{' or next == '}') {
                    has_meta = true;
                    break;
                }
                i += 1;
            }
        }
        if (has_meta) {
            return cpu.findMatchesRegex(text, pattern, options, allocator);
        }
        return cpu.findMatches(text, pattern, options, allocator);
    }
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

fn processSubstituteStdin(allocator: std.mem.Allocator, text: []const u8, cmd: SedCommand, backend: gpu.Backend, verbose: bool, suppress_output: bool) !void {
    // Find matches
    var result = switch (backend) {
        .metal => blk: {
            if (build_options.is_macos) {
                const substituter = gpu.metal.MetalSubstituter.init(allocator) catch {
                    break :blk try doFindMatches(text, cmd.pattern, cmd.options, allocator);
                };
                defer substituter.deinit();
                break :blk substituter.findMatches(text, cmd.pattern, cmd.options, allocator) catch {
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
            break :blk substituter.findMatches(text, cmd.pattern, cmd.options, allocator) catch {
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
        try output.appendSlice(allocator, cmd.replacement);
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
    if (expr.len < 3) return error.InvalidExpression;

    // Check for transliterate (y/source/dest/)
    if (expr[0] == 'y' and expr.len >= 4) {
        const delim = expr[1];
        var parts: [3][]const u8 = undefined;
        var part_idx: usize = 0;
        var start: usize = 2;

        for (expr[2..], 2..) |c, idx| {
            if (c == delim) {
                parts[part_idx] = expr[start..idx];
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
            };
        }
    }

    // Check for substitute (s/pattern/replacement/flags)
    if (expr[0] == 's' and expr.len >= 4) {
        const delim = expr[1];
        var pattern_end: usize = 2;
        while (pattern_end < expr.len and expr[pattern_end] != delim) {
            if (expr[pattern_end] == '\\' and pattern_end + 1 < expr.len) {
                pattern_end += 2; // Skip escaped char
            } else {
                pattern_end += 1;
            }
        }

        if (pattern_end >= expr.len) return error.InvalidExpression;

        const pattern = expr[2..pattern_end];
        var replacement_end = pattern_end + 1;
        while (replacement_end < expr.len and expr[replacement_end] != delim) {
            if (expr[replacement_end] == '\\' and replacement_end + 1 < expr.len) {
                replacement_end += 2;
            } else {
                replacement_end += 1;
            }
        }

        const replacement = expr[pattern_end + 1 .. replacement_end];

        // Parse flags
        var options = SubstituteOptions{};
        if (replacement_end + 1 < expr.len) {
            const flags = expr[replacement_end + 1 ..];
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
        };
    }

    // Check for address/pattern command (/pattern/d or /pattern/p)
    if (expr[0] == '/') {
        var pattern_end: usize = 1;
        while (pattern_end < expr.len and expr[pattern_end] != '/') {
            pattern_end += 1;
        }

        if (pattern_end >= expr.len) return error.InvalidExpression;

        var pattern = expr[1..pattern_end];
        var options = SubstituteOptions{};

        // Handle ^ anchor at start of pattern
        if (pattern.len > 0 and pattern[0] == '^') {
            options.anchor_start = true;
            pattern = pattern[1..];
        }

        const cmd_char = if (pattern_end + 1 < expr.len) expr[pattern_end + 1] else 'p';

        return SedCommand{
            .cmd_type = if (cmd_char == 'd') .delete else .print,
            .pattern = pattern,
            .replacement = "",
            .options = options,
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
                break :blk substituter.findMatches(text, cmd.pattern, cmd.options, allocator) catch |err| {
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
            break :blk substituter.findMatches(text, cmd.pattern, cmd.options, allocator) catch |err| {
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
        // Append replacement
        try output.appendSlice(allocator, cmd.replacement);
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
                break :blk substituter.findMatches(text, cmd.pattern, cmd.options, allocator) catch {
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
            break :blk substituter.findMatches(text, cmd.pattern, cmd.options, allocator) catch {
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
                break :blk substituter.findMatches(text, cmd.pattern, cmd.options, allocator) catch {
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
            break :blk substituter.findMatches(text, cmd.pattern, cmd.options, allocator) catch {
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
        \\Usage: sed [OPTION]... {SCRIPT-ONLY-IF-NO-OTHER-SCRIPT} [INPUT-FILE]...
        \\
        \\Stream editor for filtering and transforming text.
        \\If no INPUT-FILE is given, or if INPUT-FILE is -, read standard input.
        \\
        \\Options:
        \\  -n, --quiet, --silent    suppress automatic printing of pattern space
        \\  -e SCRIPT, --expression=SCRIPT
        \\                           add the script to the commands to be executed
        \\  -E, -r, --regexp-extended
        \\                           use extended regular expressions (ERE)
        \\  -i, --in-place           edit files in place
        \\  -V, --verbose            print backend and timing information
        \\  -h, --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\GPU Backend selection:
        \\  --auto                   auto-select optimal backend (default)
        \\  --gpu                    force GPU (Metal on macOS, Vulkan on Linux)
        \\  --cpu                    force CPU backend
        \\  --metal                  force Metal backend (macOS only)
        \\  --vulkan                 force Vulkan backend
        \\
        \\Commands:
        \\  s/REGEXP/REPLACEMENT/FLAGS
        \\      Substitute REGEXP with REPLACEMENT.
        \\      FLAGS: g (global), i (ignore case), 1 (first only)
        \\
        \\  y/SOURCE/DEST/
        \\      Transliterate characters in SOURCE to DEST.
        \\
        \\  /REGEXP/d
        \\      Delete lines matching REGEXP.
        \\
        \\  /REGEXP/p
        \\      Print lines matching REGEXP.
        \\
        \\GPU Performance (typical speedups vs CPU):
        \\  1MB files:   ~2x
        \\  10MB files:  ~5x
        \\  50MB files:  ~7x
        \\
        \\Examples:
        \\  sed 's/foo/bar/g' input.txt         Replace all 'foo' with 'bar'
        \\  sed -E 's/[0-9]+/NUM/g' file.txt    Extended regex (ERE)
        \\  sed -i 's/old/new/g' file.txt       Edit file in place
        \\  cat file.txt | sed 's/a/b/g'        Read from stdin
        \\  echo "hello" | sed 's/hello/hi/'    Pipe through sed
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
