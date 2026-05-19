# GPU-Accelerated Sed

A high-performance `sed` replacement that uses GPU acceleration via Metal (macOS) and Vulkan for blazing-fast stream editing.

## Features

- **GPU-Accelerated Substitution**: Parallel pattern matching for `s/pattern/replacement/` commands
- **SIMD-Optimized CPU**: Vectorized Boyer-Moore-Horspool with 16/32-byte operations
- **Auto-Selection**: Intelligent backend selection based on file size and pattern complexity
- **GNU Compatible**: Supports multiple expressions, line addressing, hold space, branching, and most sed commands

## Installation

Homebrew formulas are now maintained in [e-jerk/utils](https://github.com/e-jerk/homebrew-utils) (pure GPU versions) and [e-jerk/utils-gnu](https://github.com/e-jerk/homebrew-utils-gnu) (GNU-fallback versions).

```bash
# Pure GPU version (no dependencies)
brew tap e-jerk/utils
brew install e-jerk/utils/sed

# GNU-fallback version (with GNU fallback support)
brew tap e-jerk/utils-gnu
brew install e-jerk/utils-gnu/sed
```

## Usage

```bash
# Substitute (replace all occurrences)
sed 's/foo/bar/g' file.txt

# Case-insensitive substitute
sed 's/error/warning/gi' log.txt

# Replace first occurrence only
sed 's/old/new/1' file.txt

# Delete lines matching pattern
sed '/pattern/d' file.txt

# Print only matching lines
sed -n '/pattern/p' file.txt

# Transliterate characters
sed 'y/abc/xyz/' file.txt

# Multiple expressions
sed -e 's/foo/bar/' -e 's/baz/qux/' file.txt
sed -e 's/a/A/' -e 's/b/B/' -e 's/c/C/' file.txt

# Semicolon-separated expressions
sed 's/foo/bar/; s/baz/qux/' file.txt

# Line addressing
sed '2s/old/new/' file.txt         # Line 2 only
sed '2,4s/old/new/' file.txt       # Lines 2-4
sed '3,$s/old/new/' file.txt       # Line 3 to end
sed '$s/old/new/' file.txt         # Last line only
sed '2d' file.txt                  # Delete line 2
sed '2,4d' file.txt                # Delete lines 2-4

# Address negation
sed '2!s/old/new/' file.txt        # All except line 2

# Print line number
sed '=' file.txt

# Append / insert / change text
sed 'a\new line' file.txt
sed 'i\inserted line' file.txt
sed 'c\replaced line' file.txt

# Hold space
sed 'h; g' file.txt
sed 'H; G' file.txt
sed 'x' file.txt

# Branching and labels
sed ':loop; s/foo/bar/; t loop' file.txt
sed 'b end; s/foo/bar/; :end' file.txt

# Next line commands
sed 'n; s/foo/bar/' file.txt
sed 'N; s/\n/ /' file.txt

# Quit
sed '5q' file.txt
sed '5q 42' file.txt               # Quit with exit code 42

# Write changed lines to file
sed 's/foo/bar/gw changes.txt' file.txt

# Execute replacement as shell command
sed 's/|.*|/echo "&"/e' file.txt

# List unambiguously
sed 'l' file.txt

# Edit file in place
sed -i 's/old/new/g' file.txt

# Follow symlinks
sed -l 's/old/new/g' file.txt

# Force GPU backend
sed --gpu 's/search/replace/g' largefile.txt

# Verbose output
sed -V 's/pattern/replacement/g' file.txt
```

## GNU Feature Compatibility

| Feature | CPU | Metal | Vulkan | GPU Speedup | Status |
|---------|:---:|:-----:|:------:|:-----------:|--------|
| `s/pattern/replacement/` | ✓ | ✓ | ✓ | **16x** | Native |
| `s///g` global flag | ✓ | ✓ | ✓ | **8x** | Native |
| `s///i` case insensitive | ✓ | ✓ | ✓ | **5.5x** | Native |
| `s///I` case insensitive (ASCII) | ✓ | ✓ | ✓ | **5.5x** | Native |
| `s///e` execute replacement | ✓ | — | — | CPU only | Native |
| `s///w file` write to file | ✓ | — | — | CPU only | Native |
| `s///m` multiline mode | ✓ | ✓ | ✓ | **5x** | Native |
| `/pattern/d` delete | ✓ | ✓ | ✓ | **8x** | Native |
| `/pattern/p` print | ✓ | ✓ | ✓ | **8x** | Native |
| `-E/-r` extended regex | ✓ | ✓ | ✓ | **5-10x** | **Native** |
| `y/src/dst/` transliterate | ✓ | — | — | CPU only | Native |
| `&` matched text | ✓ | ✓ | ✓ | **8x** | Native |
| `\n` `\t` escape sequences | ✓ | ✓ | ✓ | **8x** | Native |
| `\1`-`\9` backreferences | ✓ | — | — | CPU only | Native |
| `-i` in-place edit | ✓ | ✓ | ✓ | **8x** | Native |
| `-n` suppress output | ✓ | ✓ | ✓ | **8x** | Native |
| `-e` multiple expressions | ✓ | — | — | CPU only | **Native** |
| `;` semicolon-separated expressions | ✓ | — | — | CPU only | **Native** |
| Line addressing (`1,5s/...`) | ✓ | — | — | CPU only | **Native** |
| `!` address negation | ✓ | — | — | CPU only | **Native** |
| `=` print line number | ✓ | — | — | CPU only | **Native** |
| `a\` `i\` `c\` text commands | ✓ | — | — | CPU only | **Native** |
| `h`/`H`/`g`/`G`/`x` hold space | ✓ | — | — | CPU only | **Native** |
| `b` unconditional branch | ✓ | — | — | CPU only | **Native** |
| `t`/`T` branch on substitute | ✓ | — | — | CPU only | **Native** |
| `n`/`N` next/append-next | ✓ | — | — | CPU only | **Native** |
| `q`/`q N` quit with exit code | ✓ | — | — | CPU only | **Native** |
| `D` delete first line, restart | ✓ | — | — | CPU only | **Native** |
| `P` print first line | ✓ | — | — | CPU only | **Native** |
| `l` list unambiguously | ✓ | — | — | CPU only | **Native** |
| `e` standalone execute | ✓ | — | — | CPU only | **Native** |
| `v` version command | ✓ | — | — | CPU only | **Native** |
| `#` comments | ✓ | — | — | CPU only | **Native** |
| `-z` null-data mode | ✓ | — | — | CPU only | **Native** |
| `-u` unbuffered | ✓ | — | — | CPU only | **Native** |
| `--follow-symlinks` | ✓ | — | — | CPU only | **Native** |

**Test Coverage**: 55+ GNU compatibility tests passing

## Supported Commands

| Command | Description |
|---------|-------------|
| `s/pattern/replacement/flags` | Substitute pattern with replacement |
| `y/source/dest/` | Transliterate characters |
| `/pattern/d` | Delete lines matching pattern |
| `/pattern/p` | Print lines matching pattern |
| `Ns/pattern/replacement/` | Apply to line N only |
| `N,Ms/pattern/replacement/` | Apply to lines N through M |
| `$s/pattern/replacement/` | Apply to last line |
| `Nd` | Delete line N |
| `N,Md` | Delete lines N through M |
| `N!command` | Negated address — all lines except N |
| `a\text` | Append text after line |
| `i\text` | Insert text before line |
| `c\text` | Replace line with text |
| `=` | Print current line number |
| `n` | Read next line into pattern space |
| `N` | Append next line to pattern space |
| `q` | Quit immediately |
| `q N` | Quit with exit code N |
| `h` | Copy pattern space to hold space |
| `H` | Append pattern space to hold space |
| `g` | Copy hold space to pattern space |
| `G` | Append hold space to pattern space |
| `x` | Exchange pattern and hold space |
| `b label` | Branch unconditionally to label |
| `:label` | Define a label |
| `t label` | Branch to label if last substitute succeeded |
| `T label` | Branch to label if last substitute failed |
| `D` | Delete first line of pattern space, restart cycle |
| `P` | Print first line of pattern space |
| `l` | List pattern space unambiguously |
| `e` | Execute pattern space as shell command |
| `v` | Fail if version mismatch |
| `# comment` | Comment (ignored) |

## Command Line Reference

<details>
<summary>Full --help output</summary>

```
Usage: sed [OPTION]... {SCRIPT} [INPUT-FILE]...

Stream editor for filtering and transforming text.
If no INPUT-FILE is given, or if INPUT-FILE is -, read standard input.

Options:
  -n, --quiet, --silent    suppress automatic printing            [GPU+SIMD]
  -e SCRIPT, --expression=SCRIPT
                           add script (can repeat)                [SIMD]
  -E, -r, --regexp-extended
                           use extended regex (ERE)               [GPU+SIMD]
  -i, --in-place           edit files in place                    [GPU+SIMD]
  -z, --null-data          separate lines by NUL characters       [SIMD]
  -u, --unbuffered         minimal input/output buffering         [SIMD]
  -l, --follow-symlinks    follow symlinks when processing in place [SIMD]
  -V, --verbose            print backend and timing info
  -h, --help               display this help and exit
      --version            output version information and exit

Backend selection:
  --auto                   auto-select optimal backend (default)
  --gpu                    force GPU (Metal on macOS, Vulkan on Linux)
  --cpu                    force CPU backend (SIMD-optimized)
  --gnu                    force GNU sed backend (GPL, full features)
  --metal                  force Metal backend (macOS only)
  --vulkan                 force Vulkan backend

Commands:
  s/REGEXP/REPLACEMENT/FLAGS                                      [GPU+SIMD]
      Substitute REGEXP with REPLACEMENT.
      FLAGS: g (global), i (ignore case), I (ASCII ignore case),
             1 (first only), e (execute), w file (write), m (multiline)
      Special: & = matched text, \n \t = newline/tab, \1-\9 = backrefs

  y/SOURCE/DEST/                                                  [SIMD]
      Transliterate characters (256-byte lookup, 32-byte unroll)

  /REGEXP/d                                                       [GPU+SIMD]
      Delete lines matching REGEXP.

  /REGEXP/p                                                       [GPU+SIMD]
      Print lines matching REGEXP.

  ADDRESS COMMAND           Line addressing (1,5s/.../.../)       [SIMD]
  ADDRESS!COMMAND           Negated address                        [SIMD]

Optimization legend:
  [GPU+SIMD]  GPU-accelerated (Metal/Vulkan) + SIMD-optimized CPU
  [SIMD]      SIMD-optimized CPU only (GPU not yet implemented)
  GPU uses parallel compute shaders for pattern matching
  CPU uses Boyer-Moore-Horspool with 16/32-byte SIMD vectors

GPU Performance (typical speedups vs SIMD CPU):
  s/pattern/replacement/:   ~16x    s///g global:        ~8x
  s///i case insensitive:   ~5.5x   /pattern/d delete:   ~8x
  -E extended regex:        ~5-10x

Examples:
  sed 's/foo/bar/g' input.txt         Replace all 'foo' with 'bar'
  sed -E 's/[0-9]+/NUM/g' file.txt    Extended regex (ERE)
  sed -i 's/old/new/g' file.txt       Edit file in place
  sed 'y/abc/xyz/' file.txt           Transliterate a->x, b->y, c->z
  sed '/error/d' file.txt             Delete lines with 'error'
  sed -n '/pattern/p' file.txt        Print only matching lines
  sed --gpu 's/x/y/g' large.txt       Force GPU acceleration
```

</details>

## Memory Safety (zust)

This project uses [zust](https://github.com/e-jerk/zust) — zero-cost ownership and memory safety for Zig. The entire source tree has been transpiled to zust-safe Zig with the following transformations applied by `zust-transpile`:

- **Array initialization**: `var buf: [N]u8 = undefined` → zeroed initialization
- **Pointer capture loops**: `for (slice) |*item|` rewritten to index-based iteration
- **Resource cleanup**: `defer allocator.free(x)` statements safely stripped
- **Unsafe casts**: `@ptrCast`, `@bitCast`, `@intCast` annotated with review comments
- **Optional unwraps**: `opt.?` in expression contexts preserved with review comments

Run the memory-safety analyzer:

```bash
zig build analyze    # Runs zust-analyzer --strictness=high on src/
```

The analyzer currently reports **zero non-slice errors**.

## Build Variants

| Variant | Description | Vulkan on macOS | `--gnu` flag |
|---------|-------------|-----------------|--------------|
| **pure** | Zig + SIMD + GPU only. No external dependencies. | No | Not available |
| **gnu** | Includes GNU sed + Vulkan via MoltenVK. | Yes | Falls back to GNU sed |

The gnu build enables Vulkan on macOS using MoltenVK, allowing both Metal and Vulkan backends on Mac.

## Backend Selection

| Flag | Description |
|------|-------------|
| `--auto` | Automatically select optimal backend (default) |
| `--gpu` | Use GPU (Metal on macOS, Vulkan elsewhere) |
| `--cpu` | Force CPU backend (SIMD-optimized) |
| `--gnu` | Force GNU sed backend (gnu build only) |
| `--metal` | Force Metal backend (macOS only) |
| `--vulkan` | Force Vulkan backend (macOS+gnu build, or Linux) |

## Architecture & Optimizations

### CPU Implementation (`src/cpu_optimized.zig`)

The CPU backend uses SIMD-optimized algorithms:

**Boyer-Moore-Horspool Search**:
- `findMatches()`: Main search function with 256-entry skip table
- `matchAtPositionSIMD()`: 16-byte vectorized pattern comparison
- Pre-computed lowercase pattern for case-insensitive search

**SIMD Vector Operations**:
- `Vec16` and `Vec32` types (`@Vector(16, u8)`, `@Vector(32, u8)`)
- `toLowerVec16()`: Parallel lowercase conversion using `@select`
- `findNextNewlineSIMD()`: 32-byte chunked newline search

**Multiple Expressions**:
- Expressions collected into array during argument parsing
- Applied sequentially to each line
- Supports mixing command types (`s///`, `d`, `y///`)

**Line Addressing**:
- `Address` union: single line, range, last line (`$`), pattern
- Address parsing before command character
- Line number tracking during processing
- Range validation with start/end bounds

**Transliteration**:
- `transliterate()`: 256-byte lookup table for O(1) character mapping
- 32-byte unrolled loop for throughput

### GPU Implementation

**Metal Shader (`src/shaders/substitute.metal`)**:

- **Chunked Processing**: Each thread handles `(searchable_len + num_threads - 1) / num_threads` positions
- **uchar4 SIMD**: 4-byte vectorized pattern matching via `match_at_position()`
- **Atomic Match Collection**: `atomic_uint` counters for thread-safe result storage
- **Host-Side Line Numbers**: Line counting moved to CPU for efficiency (avoids O(n) scan per match)

**Vulkan Shader (`src/shaders/substitute.comp`)**:

- **uvec4 SIMD**: 16-byte vectorized comparison via `match_uvec4()`
- **Chunked Dispatch**: `text_len / 64 / 256` workgroups for balanced parallelism
- **Packed Word Access**: Handles unaligned reads via bit shifting
- **Workgroup Size**: 256 threads (`local_size_x = 256`)

### Performance Optimizations

**GPU Thread Reduction**:
- Original: 1 thread per text position (50M threads for 50MB)
- Optimized: ~780K threads with chunked processing (64x reduction)

**Line Number Computation**:
- GPU shader stores position only (no line counting in hot path)
- Host computes line numbers in single sorted pass after GPU returns
- Eliminates O(position) scan per match on GPU

**First-Only Mode**:
- CPU: Skips to next line immediately after first match
- GPU: Host-side filtering after match collection

### Auto-Selection

The `e_jerk_gpu` library considers:

- **Data Size**: GPU preferred for 1MB+ files
- **Match Density**: High-density patterns benefit more from GPU
- **Hardware Tier**: Adjusts thresholds based on GPU performance score

## Performance

| Pattern Type | CPU | GPU | Speedup |
|--------------|-----|-----|---------|
| Single char (`e`) | 177 MB/s | 2.8 GB/s | **16.0x** |
| Common word (`the`) | 397 MB/s | 3.1 GB/s | **7.9x** |
| Identifier (`test`) | 478 MB/s | 3.1 GB/s | **6.5x** |
| Case-insensitive | 633 MB/s | 3.5 GB/s | **5.5x** |
| Long pattern | 754 MB/s | 3.2 GB/s | **4.2x** |
| Log warnings | 1.1 GB/s | 4.2 GB/s | **3.8x** |

*Results measured on Apple M1 Max with 50MB test files.*

## Requirements

- **macOS**: Metal support (built-in), optional MoltenVK for Vulkan
- **Linux**: Vulkan runtime (`libvulkan1`)
- **Build**: Zig 0.15.2+, glslc (Vulkan shader compiler)

## Building from Source

```bash
zig build -Doptimize=ReleaseFast

# Run tests
zig build test      # Unit tests
zig build smoke     # Integration tests (GPU verification)
zig build bench     # Benchmarks
zig build analyze   # Memory-safety analyzer (zust)
bash gnu-tests.sh   # GNU compatibility tests (55+ tests)
```

## Recent Changes

- **New sed Commands**: `n`/`N` (next/append-next), `q`/`q N` (quit with exit code), `=` (line number), `a\`/`i\`/`c\` (text commands), `h`/`H`/`g`/`G`/`x` (hold space), `t`/`T`/`b` (branching), `D`/`P` (multiline operations), `!` (address negation), `l` (list unambiguously), `e` (execute), `v` (version), `#` (comments)
- **Substitution Flags**: `s///e` (execute), `s///w file` (write), `s///m` (multiline), `s///I` (ASCII case-insensitive)
- **Expression Parsing**: `;` semicolon-separated expressions, `\1`-`\9` capture backreferences (CPU only)
- **CLI Flags**: `-z`/`--null-data`, `-u`/`--unbuffered`, `--follow-symlinks`/`-l`
- **GPU Regex Support**: Native Thompson NFA regex execution on Metal and Vulkan GPUs for `s/regex/replacement/` with extended patterns
- **Test Coverage**: 55+ GNU compatibility tests passing

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
