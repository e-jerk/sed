# GPU-Accelerated Sed

A high-performance `sed` replacement that uses GPU acceleration via Metal (macOS) and Vulkan for blazing-fast stream editing.

## Features

- **GPU-Accelerated Substitution**: Parallel pattern matching for `s/pattern/replacement/` commands
- **SIMD-Optimized CPU**: Vectorized Boyer-Moore-Horspool with 16/32-byte operations
- **Auto-Selection**: Intelligent backend selection based on file size and pattern complexity
- **GNU Compatible**: Supports substitute, delete, print, and transliterate commands

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

# Edit file in place
sed -i 's/old/new/g' file.txt

# Force GPU backend
sed --gpu 's/search/replace/g' largefile.txt

# Verbose output
sed -V 's/pattern/replacement/g' file.txt
```

## Supported Commands

| Command | Description |
|---------|-------------|
| `s/pattern/replacement/flags` | Substitute pattern with replacement |
| `y/source/dest/` | Transliterate characters |
| `/pattern/d` | Delete lines matching pattern |
| `/pattern/p` | Print lines matching pattern |

## Substitute Flags

| Flag | Description |
|------|-------------|
| `g` | Global - replace all occurrences |
| `i` | Case-insensitive matching |
| `1` | Replace first occurrence only |

## Options

| Flag | Description |
|------|-------------|
| `-e, --expression` | Specify sed expression |
| `-n, --quiet` | Suppress automatic output |
| `-i, --in-place` | Edit files in place |
| `-V, --verbose` | Show timing and backend info |

## Backend Selection

| Flag | Description |
|------|-------------|
| `--auto` | Automatically select optimal backend (default) |
| `--gpu` | Use GPU (Metal on macOS, Vulkan elsewhere) |
| `--cpu` | Force CPU backend |
| `--metal` | Force Metal backend (macOS only) |
| `--vulkan` | Force Vulkan backend |

## Architecture & Optimizations

### CPU Implementation (`src/cpu.zig`)

The CPU backend uses SIMD-optimized algorithms:

**Boyer-Moore-Horspool Search**:
- `findMatches()`: Main search function with 256-entry skip table
- `matchAtPositionSIMD()`: 16-byte vectorized pattern comparison
- Pre-computed lowercase pattern for case-insensitive search

**SIMD Vector Operations**:
- `Vec16` and `Vec32` types (`@Vector(16, u8)`, `@Vector(32, u8)`)
- `toLowerVec16()`: Parallel lowercase conversion using `@select`
- `findNextNewlineSIMD()`: 32-byte chunked newline search

**Line Tracking**:
- Incremental line number tracking during search
- Efficient `first_only` mode skips to next line after match
- Anchor support (`^`) for line-start matching

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

| Pattern Type | 50MB File | GPU Speedup |
|--------------|-----------|-------------|
| Single char (`e`) | 176 MB/s CPU → 2.4 GB/s GPU | **13.5x** |
| Common word (`the`) | 394 MB/s CPU → 2.5 GB/s GPU | **6.4x** |
| Identifier (`test`) | 446 MB/s CPU → 2.5 GB/s GPU | **5.6x** |
| Case-insensitive | 633 MB/s CPU → 2.9 GB/s GPU | **4.6x** |
| Long pattern | 746 MB/s CPU → 2.0 GB/s GPU | **2.7x** |

*Results measured on Apple M1 Max.*

## Requirements

- **macOS**: Metal support (built-in), optional MoltenVK for Vulkan
- **Linux**: Vulkan runtime (`libvulkan1`)
- **Build**: Zig 0.15.2+, glslc (Vulkan shader compiler)

## Building from Source

```bash
zig build -Doptimize=ReleaseFast

# Run tests
zig build test      # Unit tests
zig build smoke     # Integration tests
zig build bench     # Benchmarks
```

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
