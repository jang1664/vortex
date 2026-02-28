#!/usr/bin/env bash
set -euo pipefail

# Build lp64f software stack for Vortex without modifying Vortex Makefiles.
# Outputs a profile containing:
#   - riscv64-gnu-toolchain
#   - libc64
#   - libcrt64 (with libclang_rt.builtins-riscv64.a)
#
# Design choice:
#   - TOOLCHAIN_ARCH: arch used to build riscv-gnu-toolchain/newlib
#   - CRT_ARCH:       arch used to build compiler-rt builtins
# This lets you mirror Vortex prebuilt behavior (toolchain vs libcrt arch not identical)
# while keeping ABI=lp64f.

SKIP_CLONE=0
SKIP_TOOLCHAIN=0
SKIP_RT=0
INJECT_EXIT_SHIM=1
CMAKE_BIN="${CMAKE_BIN:-}"

usage() {
  cat <<'USAGE'
Usage: build_software_vortex_lp64f.sh [options]
Options:
  --skip-clone       If repositories already exist under WORK_ROOT, reuse them.
                     If missing, clone is still performed.
  --skip-tool-chain  Skip riscv-gnu-toolchain build step.
  --skip-rt          Skip compiler-rt (LLVM) build step.
  --skip-exit-shim   Do not inject _exit shim into lp64f libc.a.
  --cmake <path>     Use a specific CMake binary for compiler-rt (needs >= 3.20).
  -h, --help         Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-clone)
      SKIP_CLONE=1
      shift
      ;;
    --skip-tool-chain)
      SKIP_TOOLCHAIN=1
      shift
      ;;
    --skip-rt)
      SKIP_RT=1
      shift
      ;;
    --skip-exit-shim)
      INJECT_EXIT_SHIM=0
      shift
      ;;
    --cmake)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --cmake requires a path argument" >&2
        exit 1
      fi
      CMAKE_BIN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# -----------------------
# Configurable variables
# -----------------------
PROFILE_ROOT=${PROFILE_ROOT:-/opt/vortex_profiles/lp64f}
WORK_ROOT=${WORK_ROOT:-/home/jaeyongjang/tools/src_lp64f}

LLVM_PREFIX=${LLVM_PREFIX:-/opt/vortex/llvm-vortex}
LLVM_REPO=${LLVM_REPO:-https://github.com/vortexgpgpu/llvm.git}
LLVM_REF=${LLVM_REF:-c2516577cb9104f53aaef095c1c3a1d2517cec36}

RISCV_GNU_REPO=${RISCV_GNU_REPO:-https://github.com/riscv-collab/riscv-gnu-toolchain.git}
JOBS=${JOBS:-$(nproc)}

RISCV_PREFIX=riscv64-unknown-elf
RISCV_TC_PREFIX="$PROFILE_ROOT/riscv64-gnu-toolchain"
RISCV_SYSROOT="$RISCV_TC_PREFIX/$RISCV_PREFIX"

LIBC_DST="$PROFILE_ROOT/libc64"
LIBCRT_DST="$PROFILE_ROOT/libcrt64"

# Match prebuilt style, except ABI switched to lp64f.
TOOLCHAIN_ARCH=${TOOLCHAIN_ARCH:-rv64imaf_zicsr}
CRT_ARCH=${CRT_ARCH:-rv64imaf_zicsr_zicond}
ABI=${ABI:-lp64f}
CODE_MODEL=${CODE_MODEL:-medany}

# -----------------------
# Helpers
# -----------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command '$1'" >&2
    exit 1
  }
}

log() {
  echo "[lp64f-build] $*"
}

cmake_version_ok() {
  local bin="$1"
  "$bin" --version 2>/dev/null | awk '
    NR == 1 {
      split($3, v, ".");
      major = v[1] + 0;
      minor = v[2] + 0;
      if (major > 3 || (major == 3 && minor >= 20)) exit 0;
      exit 1;
    }
    END {
      if (NR == 0) exit 1;
    }
  '
}

inject_exit_shim() {
  local libc_archive="$LIBC_DST/lib/libc.a"
  local cc_bin="$RISCV_TC_PREFIX/bin/$RISCV_PREFIX-gcc"
  local ar_bin="$RISCV_TC_PREFIX/bin/$RISCV_PREFIX-ar"
  local ranlib_bin="$RISCV_TC_PREFIX/bin/$RISCV_PREFIX-ranlib"
  local nm_bin="$RISCV_TC_PREFIX/bin/$RISCV_PREFIX-nm"

  if [[ ! -f "$libc_archive" ]]; then
    echo "ERROR: libc archive not found: $libc_archive" >&2
    exit 1
  fi

  need_cmd "$cc_bin"
  need_cmd "$ar_bin"
  need_cmd "$ranlib_bin"
  need_cmd "$nm_bin"

  if "$nm_bin" -A "$libc_archive" 2>/dev/null | grep -Eq '[[:space:]]T[[:space:]]_exit$'; then
    log "libc.a already defines _exit, skipping shim injection"
    return
  fi

  local tmpd
  tmpd=$(mktemp -d "$WORK_ROOT/.tmp_exit_shim.XXXXXX")
  local asm_file="$tmpd/vx_exit_shim_lp64f.S"
  local obj_file="$tmpd/vx_exit_shim_lp64f.o"

  cat > "$asm_file" <<'EOF'
  .section .text
  .globl _exit
  .type  _exit, @function
_exit:
  tail _Exit
  .size _exit, .-_exit
EOF

  if ! "$cc_bin" -c "$asm_file" -o "$obj_file" \
      -march="$TOOLCHAIN_ARCH" -mabi="$ABI" -mcmodel="$CODE_MODEL"; then
    log "WARNING: failed to build _exit shim with -march=$TOOLCHAIN_ARCH, retrying with -march=rv64imaf"
    "$cc_bin" -c "$asm_file" -o "$obj_file" \
      -march=rv64imaf -mabi="$ABI" -mcmodel="$CODE_MODEL"
  fi

  "$ar_bin" d "$libc_archive" "$(basename "$obj_file")" >/dev/null 2>&1 || true
  "$ar_bin" r "$libc_archive" "$obj_file"
  "$ranlib_bin" "$libc_archive"

  if "$nm_bin" -A "$libc_archive" 2>/dev/null | grep -Eq '[[:space:]]T[[:space:]]_exit$'; then
    log "Injected _exit shim into $libc_archive"
  else
    echo "ERROR: failed to verify _exit shim injection in $libc_archive" >&2
    exit 1
  fi

  rm -rf "$tmpd"
}

# -----------------------
# Preconditions
# -----------------------
if [[ "$SKIP_TOOLCHAIN" -eq 0 || "$SKIP_RT" -eq 0 ]]; then
  need_cmd git
fi
if [[ "$SKIP_TOOLCHAIN" -eq 0 ]]; then
  need_cmd make
fi
if [[ "$SKIP_RT" -eq 0 ]]; then
  if [[ -z "$CMAKE_BIN" ]]; then
    CMAKE_BIN=$(command -v cmake || true)
  fi
  if [[ -z "$CMAKE_BIN" ]]; then
    echo "ERROR: cmake not found. Provide one via --cmake <path>." >&2
    exit 1
  fi
  if [[ ! -x "$CMAKE_BIN" ]]; then
    echo "ERROR: cmake binary is not executable: $CMAKE_BIN" >&2
    exit 1
  fi
  if ! cmake_version_ok "$CMAKE_BIN"; then
    FOUND_VER=$("$CMAKE_BIN" --version 2>/dev/null | head -n1 || true)
    echo "ERROR: compiler-rt requires CMake >= 3.20 (found: ${FOUND_VER:-unknown})" >&2
    echo "ERROR: rerun with --cmake <path-to-cmake-3.20+>" >&2
    exit 1
  fi
  need_cmd ninja
  need_cmd "$LLVM_PREFIX/bin/clang"
  need_cmd "$LLVM_PREFIX/bin/llvm-config"
  need_cmd "$LLVM_PREFIX/bin/llvm-ar"
  need_cmd "$LLVM_PREFIX/bin/llvm-ranlib"
  need_cmd "$LLVM_PREFIX/bin/llvm-readelf"
fi

mkdir -p "$WORK_ROOT" "$PROFILE_ROOT"

log "Config:"
log "  PROFILE_ROOT=$PROFILE_ROOT"
log "  WORK_ROOT=$WORK_ROOT"
log "  TOOLCHAIN_ARCH=$TOOLCHAIN_ARCH"
log "  CRT_ARCH=$CRT_ARCH"
log "  ABI=$ABI"
log "  CODE_MODEL=$CODE_MODEL"
log "  SKIP_CLONE=$SKIP_CLONE"
log "  SKIP_TOOLCHAIN=$SKIP_TOOLCHAIN"
log "  SKIP_RT=$SKIP_RT"
log "  INJECT_EXIT_SHIM=$INJECT_EXIT_SHIM"
if [[ "$SKIP_RT" -eq 0 ]]; then
  log "  CMAKE_BIN=$CMAKE_BIN"
fi

# -----------------------
# 1) Build riscv-gnu-toolchain (newlib) for lp64f
# -----------------------
if [[ "$SKIP_TOOLCHAIN" -eq 0 ]]; then
  cd "$WORK_ROOT"
  if [[ -d riscv-gnu-toolchain ]]; then
    if [[ "$SKIP_CLONE" -eq 1 ]]; then
      log "--skip-clone: reusing existing $WORK_ROOT/riscv-gnu-toolchain"
    else
      log "Using existing riscv-gnu-toolchain at $WORK_ROOT/riscv-gnu-toolchain"
    fi
  else
    log "Cloning riscv-gnu-toolchain"
    git clone --recursive "$RISCV_GNU_REPO" riscv-gnu-toolchain
  fi

  cd "$WORK_ROOT/riscv-gnu-toolchain"
  log "Configuring riscv-gnu-toolchain (arch=$TOOLCHAIN_ARCH abi=$ABI)"
  CFLAGS_FOR_TARGET="-Os -mcmodel=$CODE_MODEL" \
  CXXFLAGS_FOR_TARGET="-Os -mcmodel=$CODE_MODEL" \
  ./configure \
    --prefix="$RISCV_TC_PREFIX" \
    --with-arch="$TOOLCHAIN_ARCH" \
    --with-abi="$ABI" \
    --with-cmodel="$CODE_MODEL" \
    --disable-multilib

  log "Building riscv-gnu-toolchain/newlib"
  make -j"$JOBS" newlib
else
  log "Skipping riscv-gnu-toolchain build (--skip-tool-chain)"
fi

# -----------------------
# 2) Package libc64 from sysroot
# -----------------------
if [[ ! -d "$RISCV_SYSROOT/include" || ! -d "$RISCV_SYSROOT/lib" ]]; then
  echo "ERROR: missing sysroot at $RISCV_SYSROOT" >&2
  echo "ERROR: run without --skip-tool-chain once, or point PROFILE_ROOT to an existing toolchain profile" >&2
  exit 1
fi

log "Packaging libc64 from $RISCV_SYSROOT"
rm -rf "$LIBC_DST"
mkdir -p "$LIBC_DST"
cp -a "$RISCV_SYSROOT/include" "$LIBC_DST/"
cp -a "$RISCV_SYSROOT/lib" "$LIBC_DST/"

if [[ "$INJECT_EXIT_SHIM" -eq 1 ]]; then
  log "Injecting _exit shim into lp64f libc.a"
  inject_exit_shim
else
  log "Skipping _exit shim injection (--skip-exit-shim)"
fi

if [[ "$SKIP_RT" -eq 0 ]]; then
  # -----------------------
  # 3) Build compiler-rt builtins for riscv64/lp64f
  # -----------------------
  cd "$WORK_ROOT"
  if [[ -d llvm-vortex-src ]]; then
    if [[ "$SKIP_CLONE" -eq 1 ]]; then
      log "--skip-clone: reusing existing $WORK_ROOT/llvm-vortex-src"
    else
      log "Using existing llvm source at $WORK_ROOT/llvm-vortex-src"
    fi
  else
    log "Cloning llvm source"
    git clone "$LLVM_REPO" llvm-vortex-src
  fi

  LLVM_SRC_DIR="$WORK_ROOT/llvm-vortex-src"
  cd "$LLVM_SRC_DIR"
  log "Checking out LLVM ref: $LLVM_REF"
  git fetch --all --tags --quiet
  # Detached HEAD is intended here.
  git checkout "$LLVM_REF"

  CRT_SRC_DIR="$LLVM_SRC_DIR/compiler-rt"
  BUILD_DIR="$LLVM_SRC_DIR/build-crt-rv64-lp64f"
  mkdir -p "$BUILD_DIR"
  if [[ ! -f "$CRT_SRC_DIR/CMakeLists.txt" ]]; then
    echo "ERROR: missing compiler-rt source at $CRT_SRC_DIR/CMakeLists.txt" >&2
    exit 1
  fi
  if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
    CACHED_SRC=$(sed -n 's#^CMAKE_HOME_DIRECTORY:INTERNAL=##p' "$BUILD_DIR/CMakeCache.txt" | head -n 1)
    if [[ -n "${CACHED_SRC:-}" && "$CACHED_SRC" != "$CRT_SRC_DIR" ]]; then
      log "Detected stale CMake cache (source=$CACHED_SRC), resetting $BUILD_DIR"
      rm -f "$BUILD_DIR/CMakeCache.txt"
      rm -rf "$BUILD_DIR/CMakeFiles"
    fi
  fi
  log "Configuring compiler-rt builtins (arch=$CRT_ARCH abi=$ABI)"
  "$CMAKE_BIN" -S "$CRT_SRC_DIR" -B "$BUILD_DIR" -G Ninja \
    -DLLVM_CONFIG_PATH="$LLVM_PREFIX/bin/llvm-config" \
    -DCMAKE_C_COMPILER="$LLVM_PREFIX/bin/clang" \
    -DCMAKE_CXX_COMPILER="$LLVM_PREFIX/bin/clang++" \
    -DCMAKE_AR="$LLVM_PREFIX/bin/llvm-ar" \
    -DCMAKE_RANLIB="$LLVM_PREFIX/bin/llvm-ranlib" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCOMPILER_RT_BAREMETAL_BUILD=ON \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCMAKE_C_COMPILER_TARGET="$RISCV_PREFIX" \
    -DCMAKE_ASM_COMPILER_TARGET="$RISCV_PREFIX" \
    "-DCMAKE_C_FLAGS=--sysroot=$RISCV_SYSROOT --gcc-toolchain=$RISCV_TC_PREFIX -march=$CRT_ARCH -mabi=$ABI -mcmodel=$CODE_MODEL" \
    "-DCMAKE_ASM_FLAGS=--sysroot=$RISCV_SYSROOT --gcc-toolchain=$RISCV_TC_PREFIX -march=$CRT_ARCH -mabi=$ABI -mcmodel=$CODE_MODEL"

  log "Building compiler-rt builtins"
  "$CMAKE_BIN" --build "$BUILD_DIR" --target builtins -j"$JOBS"

  BUILTINS_SRC=$(find "$BUILD_DIR" -name 'libclang_rt.builtins-riscv64.a' | head -n 1)
  if [[ -z "${BUILTINS_SRC:-}" ]]; then
    echo "ERROR: libclang_rt.builtins-riscv64.a not found under $BUILD_DIR" >&2
    exit 1
  fi

  # -----------------------
  # 4) Package libcrt64
  # -----------------------
  log "Packaging libcrt64"
  rm -rf "$LIBCRT_DST"
  mkdir -p "$LIBCRT_DST/lib/baremetal" "$LIBCRT_DST/lib/linux" "$LIBCRT_DST/include"
  cp "$BUILTINS_SRC" "$LIBCRT_DST/lib/baremetal/libclang_rt.builtins-riscv64.a"
  cp "$BUILTINS_SRC" "$LIBCRT_DST/lib/linux/libclang_rt.builtins-riscv64.a"

  # Pull crtbegin/crtend only from the freshly built lp64f toolchain.
  # Do not copy from /opt/vortex to avoid ABI/ISA mixing with lp64d artifacts.
  CRTBEGIN_SRC=$(find "$RISCV_TC_PREFIX/lib/gcc/$RISCV_PREFIX" -type f -name "crtbegin.o" | head -n 1 || true)
  CRTEND_SRC=$(find "$RISCV_TC_PREFIX/lib/gcc/$RISCV_PREFIX" -type f -name "crtend.o" | head -n 1 || true)

  if [[ -n "${CRTBEGIN_SRC:-}" && -n "${CRTEND_SRC:-}" ]]; then
    cp "$CRTBEGIN_SRC" "$LIBCRT_DST/lib/baremetal/clang_rt.crtbegin-riscv64.o"
    cp "$CRTEND_SRC" "$LIBCRT_DST/lib/baremetal/clang_rt.crtend-riscv64.o"
    cp "$CRTBEGIN_SRC" "$LIBCRT_DST/lib/linux/clang_rt.crtbegin-riscv64.o"
    cp "$CRTEND_SRC" "$LIBCRT_DST/lib/linux/clang_rt.crtend-riscv64.o"
  else
    log "WARNING: crtbegin/crtend not found under $RISCV_TC_PREFIX/lib/gcc/$RISCV_PREFIX"
    log "WARNING: links requiring start/end files may fail unless they are provided separately"
  fi

  # Optional headers
  if [[ -d /opt/vortex/libcrt64/include ]]; then
    cp -a /opt/vortex/libcrt64/include/. "$LIBCRT_DST/include/"
  fi

  # -----------------------
  # 5) Quick ABI/feature check
  # -----------------------
  log "Verifying builtins arch attributes"
  TMPD=$(mktemp -d)
  trap 'rm -rf "$TMPD"' EXIT
  cd "$TMPD"
  "$LLVM_PREFIX/bin/llvm-ar" x "$LIBCRT_DST/lib/baremetal/libclang_rt.builtins-riscv64.a" fp_mode.c.o || true
  if [[ -f fp_mode.c.o ]]; then
    ATTRS=$("$LLVM_PREFIX/bin/llvm-readelf" -A fp_mode.c.o 2>/dev/null || true)
    echo "$ATTRS" | grep -q "rv64" || { echo "ERROR: builtins is not rv64" >&2; exit 1; }

    # lp64f profile must not include D.
    if echo "$ATTRS" | grep -q "d2p2"; then
      echo "ERROR: builtins still contains D extension (d2p2), expected lp64f-compatible build" >&2
      exit 1
    fi

    # Optional feature consistency checks based on CRT_ARCH string.
    if [[ "$CRT_ARCH" == *zicsr* ]] && ! echo "$ATTRS" | grep -q "zicsr"; then
      echo "ERROR: expected zicsr in builtins attributes" >&2
      exit 1
    fi
    if [[ "$CRT_ARCH" == *zicond* ]] && ! echo "$ATTRS" | grep -q "zicond"; then
      echo "ERROR: expected zicond in builtins attributes" >&2
      exit 1
    fi
  fi
else
  log "Skipping compiler-rt build and libcrt64 packaging (--skip-rt)"
fi

log "Done. lp64f profile created at: $PROFILE_ROOT"
log "Contents:"
log "  - $RISCV_TC_PREFIX"
log "  - $LIBC_DST"
if [[ "$SKIP_RT" -eq 0 ]]; then
  log "  - $LIBCRT_DST"
else
  log "  - $LIBCRT_DST (unchanged: --skip-rt)"
fi

log "To use it with Vortex (no Makefile changes):"
cat <<USE
ln -sfn $RISCV_TC_PREFIX /opt/vortex/riscv64-gnu-toolchain
ln -sfn $LIBC_DST /opt/vortex/libc64
ln -sfn $LIBCRT_DST /opt/vortex/libcrt64
USE
