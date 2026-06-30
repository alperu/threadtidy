#!/usr/bin/env bash
# Build mlx.metallib from mlx-swift's vendored Metal kernel sources.
#
# mlx-swift's SwiftPM manifest does NOT compile its Metal kernels.
# When MLX initializes its Metal device it loads `mlx.metallib` from
# the binary directory; without that file inference crashes with:
#   (Metal) Unable to open mach-O at path: <private>  Error:2
#
# This script compiles the JIT-required kernel subset (mirrors the
# logic outside the `if(NOT MLX_METAL_JIT)` block of mlx-swift's
# `Source/Cmlx/mlx/mlx/backend/metal/kernels/CMakeLists.txt`) into
# .air objects and links them into a single mlx.metallib. The result
# is dropped at build/metallib/mlx.metallib and is meant to be copied
# into ThreadTidy.app/Contents/MacOS/ next to the binary by
# script/build-app.sh.
#
# Idempotent: skips work when the existing metallib is newer than
# every .metal source it consumes.
#
# Exits non-zero on any compile or link failure.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT/src/ThreadTidy"
MLX_ROOT="$PKG_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
KERNELS_DIR="$MLX_ROOT/mlx/backend/metal/kernels"
OUT_DIR="$ROOT/build/metallib"
OUT_METALLIB="$OUT_DIR/mlx.metallib"

# Populate .build/checkouts if missing.
if [[ ! -d "$KERNELS_DIR" ]]; then
    echo "==> mlx-swift checkout missing; running swift build to populate"
    ( cd "$PKG_DIR" && swift build -c release --product ThreadTidy )
fi
[[ -d "$KERNELS_DIR" ]] || { echo "error: kernels dir still missing at $KERNELS_DIR" >&2; exit 1; }

# JIT-required kernels (everything compiled UNCONDITIONALLY in CMakeLists,
# i.e. outside the `if(NOT MLX_METAL_JIT)` guard).
#
# Each entry: <relative-path-without-.metal-suffix>
KERNELS=(
    arg_reduce
    conv
    gemv
    layer_norm
    random
    rms_norm
    rope
    scaled_dot_product_attention
    fence
    steel/attn/kernels/steel_attention
)

# Idempotency: skip if metallib is newer than every .metal source AND
# every header in the kernels tree (the headers transitively gate
# correctness).
if [[ -f "$OUT_METALLIB" ]]; then
    newest_src=$(find "$KERNELS_DIR" \( -name '*.metal' -o -name '*.h' \) -print0 \
        | xargs -0 stat -f '%m' | sort -n | tail -1)
    metallib_mtime=$(stat -f '%m' "$OUT_METALLIB")
    if [[ "$metallib_mtime" -ge "$newest_src" ]]; then
        echo "==> mlx.metallib up to date ($OUT_METALLIB)"
        exit 0
    fi
fi

mkdir -p "$OUT_DIR"

# Match CMakeLists build_kernel_base: macOS 14+ uses metal_3_1.
METAL_FLAGS=(
    -Wall -Wextra -fno-fast-math -Wno-c++17-extensions
    -mmacosx-version-min=14.0
)
INCLUDES=(
    -I"$MLX_ROOT"
    -I"$KERNELS_DIR/metal_3_1"
)

AIR_FILES=()
for kernel in "${KERNELS[@]}"; do
    src="$KERNELS_DIR/${kernel}.metal"
    if [[ ! -f "$src" ]]; then
        echo "error: kernel source missing: $src" >&2
        exit 1
    fi
    # Flatten target name (replace / with _) for the .air path.
    air_name=${kernel//\//_}
    air="$OUT_DIR/${air_name}.air"
    # fence.metal uses Metal 3.2 features (`coherent(system)`,
    # `metal::memory_order_seq_cst`) that aren't in the default
    # language version (Metal 3.1). Force -std=metal3.2 just for it.
    extra=()
    if [[ "$kernel" == "fence" ]]; then
        extra+=(-std=metal3.2)
    fi
    echo "==> Compiling ${kernel}.metal"
    xcrun -sdk macosx metal "${METAL_FLAGS[@]}" ${extra[@]+"${extra[@]}"} "${INCLUDES[@]}" \
        -c "$src" -o "$air"
    AIR_FILES+=("$air")
done

echo "==> Linking mlx.metallib"
# xcrun -find metallib is unreliable on some installations; the `metal`
# driver itself links .air → .metallib when given multiple inputs and an
# .metallib output path.
xcrun -sdk macosx metal "${AIR_FILES[@]}" -o "$OUT_METALLIB"

size_kb=$(($(stat -f%z "$OUT_METALLIB") / 1024))
echo "Built: $OUT_METALLIB (${size_kb} KB)"
