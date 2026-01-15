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

| Feature | CPU-Optimized | GNU Backend | Metal | Vulkan | Status |
|---------|:-------------:|:-----------:|:-----:|:------:|--------|
| `s/pattern/replacement/` | ✓ | ✓ | ✓ | ✓ | Native |
| `s///g` global flag | ✓ | ✓ | ✓ | ✓ | Native |
| `s///i` case insensitive | ✓ | ✓ | ✓ | ✓ | Native |
| `/pattern/d` delete | ✓ | ✓ | ✓ | ✓ | Native |
| `/pattern/p` print | ✓ | ✓ | ✓ | ✓ | Native |
| `y/src/dst/` transliterate | ✓ | ✓ | — | — | Native (CPU) |
| `&` matched text | ✓ | ✓ | ✓ | ✓ | Native |
| `\n` `\t` escape sequences | ✓ | ✓ | ✓ | ✓ | Native |
| `-i` in-place edit | ✓ | ✓ | ✓ | ✓ | Native |
| `-n` suppress output | ✓ | ✓ | ✓ | ✓ | Native |
| `-e` multiple expressions | ✓ | ✓ | — | — | **Native** |
| Line addressing (`1,5s/...`) | ✓ | ✓ | — | — | **Native** |
| `-E/-r` extended regex | ✓ | ✓ | — | — | Native (CPU) |
| `\1` backreferences | — | ✓ | — | — | GNU fallback |
| `a\` `i\` `c\` commands | — | ✓ | — | — | GNU fallback |
| Hold space (`h/H/g/G/x`) | — | ✓ | — | — | GNU fallback |
| Branching (`b/t/:label`) | — | ✓ | — | — | GNU fallback |

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

## Substitute Flags

| Flag | Description |
|------|-------------|
| `g` | Global - replace all occurrences |
| `i` | Case-insensitive matching |
| `1` | Replace first occurrence only |

## Options

| Flag | Description |
|------|-------------|
| `-e, --expression` | Specify sed expression (can be repeated) |
| `-n, --quiet` | Suppress automatic output |
| `-i, --in-place` | Edit files in place |
| `-V, --verbose` | Show timing and backend info |

## Backend Selection

| Flag | Description |
|------|-------------|
| `--auto` | Automatically select optimal backend (default) |
| `--gpu` | Use GPU (Metal on macOS, Vulkan elsewhere) |
| `--cpu` | Force CPU backend |
| `--gnu` | Force GNU sed backend |
| `--metal` | Force Metal backend (macOS only) |
| `--vulkan` | Force Vulkan backend |

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

- **Multiple Expressions**: Native `-e` support for chaining expressions
- **Line Addressing**: Native support for `2s/...`, `2,4s/...`, `$s/...`, `2d`, `2,4d`
- **Mixed Commands**: Combine substitution, delete, and other commands with `-e`
- **Test Coverage**: 37 GNU compatibility tests passing

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
