# GPU-Accelerated Sed

A high-performance `sed` replacement that uses GPU acceleration via Metal (macOS) and Vulkan for blazing-fast stream editing.

## Features

- **GPU-Accelerated Substitution**: Parallel pattern matching for `s/pattern/replacement/` commands
- **SIMD-Optimized CPU**: Vectorized Boyer-Moore-Horspool with 16/32-byte operations
- **Auto-Selection**: Intelligent backend selection based on file size and pattern complexity
- **GNU Compatible**: Supports multiple expressions, line addressing, and common sed commands

## Installation

Available via Homebrew. See the homebrew-utils repository for installation instructions.

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

# Line addressing
sed '2s/old/new/' file.txt         # Line 2 only
sed '2,4s/old/new/' file.txt       # Lines 2-4
sed '3,$s/old/new/' file.txt       # Line 3 to end
sed '$s/old/new/' file.txt         # Last line only
sed '2d' file.txt                  # Delete line 2
sed '2,4d' file.txt                # Delete lines 2-4

# Edit file in place
sed -i 's/old/new/g' file.txt

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
| `/pattern/d` delete | ✓ | ✓ | ✓ | **8x** | Native |
| `/pattern/p` print | ✓ | ✓ | ✓ | **8x** | Native |
| `-E/-r` extended regex | ✓ | ✓ | ✓ | **5-10x** | **Native** |
| `y/src/dst/` transliterate | ✓ | — | — | CPU only | Native |
| `&` matched text | ✓ | ✓ | ✓ | **8x** | Native |
| `\n` `\t` escape sequences | ✓ | ✓ | ✓ | **8x** | Native |
| `-i` in-place edit | ✓ | ✓ | ✓ | **8x** | Native |
| `-n` suppress output | ✓ | ✓ | ✓ | **8x** | Native |
| `-e` multiple expressions | ✓ | — | — | CPU only | **Native** |
| Line addressing (`1,5s/...`) | ✓ | — | — | CPU only | **Native** |
| `\1` backreferences | — | — | — | — | GNU fallback |
| `a\` `i\` `c\` commands | — | — | — | — | GNU fallback |
| Hold space (`h/H/g/G/x`) | — | — | — | — | GNU fallback |
| Branching (`b/t/:label`) | — | — | — | — | GNU fallback |

**Test Coverage**: 37/37 GNU compatibility tests passing

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
      FLAGS: g (global), i (ignore case), 1 (first only)
      Special: & = matched text, \n \t = newline/tab

  y/SOURCE/DEST/                                                  [SIMD]
      Transliterate characters (256-byte lookup, 32-byte unroll)

  /REGEXP/d                                                       [GPU+SIMD]
      Delete lines matching REGEXP.

  /REGEXP/p                                                       [GPU+SIMD]
      Print lines matching REGEXP.

  ADDRESS COMMAND           Line addressing (1,5s/.../.../)       [SIMD]

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
bash gnu-tests.sh   # GNU compatibility tests (37 tests)
```

## Recent Changes

- **GPU Regex Support**: Native Thompson NFA regex execution on Metal and Vulkan GPUs for `s/regex/replacement/` with extended patterns
- **Multiple Expressions**: Native `-e` support for chaining expressions
- **Line Addressing**: Native support for `2s/...`, `2,4s/...`, `$s/...`, `2d`, `2,4d`
- **Mixed Commands**: Combine substitution, delete, and other commands with `-e`
- **Test Coverage**: 37 GNU compatibility tests passing

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
