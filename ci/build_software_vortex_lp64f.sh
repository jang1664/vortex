#!/usr/bin/env bash
set -euo pipefail

# Build a Vortex rv64imaf_zfh/lp64f software profile.
#
# The GNU toolchain is the baseline sysroot/binutils provider. The GPU-facing
# musl libc and compiler-rt builtins are compiled separately with Vortex Clang
# so divergent control flow is lowered to Vortex split/join instructions.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SKIP_CLONE=0
SKIP_GNU=0
SKIP_MUSL=0
SKIP_COMPILER_RT=0
AUTO_BACKUP=1
CMAKE_BIN="${CMAKE_BIN:-}"

usage() {
  cat <<'USAGE'
Usage: ci/build_software_vortex_lp64f.sh [options]

Builds a self-contained rv64imaf_zfh/lp64f profile with:
  riscv64-gnu-toolchain  baseline GCC/binutils/sysroot
  libc64                 musl compiled by Vortex Clang
  libcrt64               compiler-rt compiled by Vortex Clang

Options:
  --skip-clone        Reuse local source checkouts without fetching.
  --skip-gnu          Skip the RISC-V GNU toolchain build.
  --skip-tool-chain   Compatibility alias for --skip-gnu.
  --skip-musl         Skip the Vortex musl build.
  --skip-compiler-rt  Skip the Vortex compiler-rt build.
  --skip-rt           Compatibility alias for --skip-compiler-rt.
  --no-backup         Do not back up components that will be overwritten.
  --backup-root PATH  Override the backup directory.
  --cmake PATH        Use a specific CMake executable (version 3.20+).
  -h, --help          Show this help.

Important environment variables:
  PROFILE_ROOT           Installation root
  BACKUP_ROOT            Backup root (default: PROFILE_ROOT.backups)
  WORK_ROOT              Managed source/build root
  LLVM_PREFIX            Installed Vortex LLVM/Clang
  LLVM_SRC_DIR           Existing matching Vortex LLVM source (optional)
  LLVM_REF               LLVM source ref when cloning (auto-detected if unset)
  RISCV_GNU_REF          riscv-gnu-toolchain ref (default: origin/master)
  BINUTILS_GIT_MIRROR    binutils mirror (default: GNU Gitiles)
  NEWLIB_GIT_MIRROR      newlib mirror (default: GitHub mirror)
  MUSL_REPO              musl mirror (default: GitHub ifduyue/musl)
  GIT_RETRY_COUNT        Git clone/fetch/submodule attempts (default: 3)
  GIT_SUBMODULE_JOBS     Parallel submodule jobs (default: 3)
  VORTEX_TARGET_FEATURE  vortex or xvortex (auto-detected if unset)
  JOBS                    Parallel build jobs
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-clone)
      SKIP_CLONE=1
      shift
      ;;
    --skip-gnu|--skip-tool-chain)
      SKIP_GNU=1
      shift
      ;;
    --skip-musl)
      SKIP_MUSL=1
      shift
      ;;
    --skip-compiler-rt|--skip-rt)
      SKIP_COMPILER_RT=1
      shift
      ;;
    --no-backup)
      AUTO_BACKUP=0
      shift
      ;;
    --backup-root)
      [[ $# -ge 2 ]] || { echo "ERROR: --backup-root requires a path" >&2; exit 2; }
      BACKUP_ROOT="$2"
      shift 2
      ;;
    --cmake)
      [[ $# -ge 2 ]] || { echo "ERROR: --cmake requires a path" >&2; exit 2; }
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
      exit 2
      ;;
  esac
done

PROFILE_ROOT="${PROFILE_ROOT:-/opt/vortex_profiles/rv64imaf_zfh_lp64f}"
BACKUP_ROOT="${BACKUP_ROOT:-${PROFILE_ROOT}.backups}"
WORK_ROOT="${WORK_ROOT:-${HOME}/tools/src_vortex_rv64imaf_zfh_lp64f}"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/vortex/llvm-vortex}"
LLVM_SRC_DIR="${LLVM_SRC_DIR:-}"
LLVM_REPO="${LLVM_REPO:-https://github.com/vortexgpgpu/llvm.git}"
LLVM_REF="${LLVM_REF:-}"
RISCV_GNU_REPO="${RISCV_GNU_REPO:-https://github.com/riscv-collab/riscv-gnu-toolchain.git}"
RISCV_GNU_REF="${RISCV_GNU_REF:-origin/master}"
BINUTILS_GIT_MIRROR="${BINUTILS_GIT_MIRROR:-https://gnu.googlesource.com/binutils-gdb}"
NEWLIB_GIT_MIRROR="${NEWLIB_GIT_MIRROR:-https://github.com/mirror/newlib-cygwin.git}"
GIT_RETRY_COUNT="${GIT_RETRY_COUNT:-3}"
GIT_SUBMODULE_JOBS="${GIT_SUBMODULE_JOBS:-3}"
MUSL_REPO="${MUSL_REPO:-https://github.com/ifduyue/musl.git}"
MUSL_REF="${MUSL_REF:-v1.2.5}"
VORTEX_TARGET_FEATURE="${VORTEX_TARGET_FEATURE:-}"
JOBS="${JOBS:-$(nproc)}"

readonly TARGET_TRIPLE=riscv64-unknown-elf
readonly TARGET_ARCH=rv64imaf_zfh
readonly TARGET_ABI=lp64f
readonly CODE_MODEL=medany
readonly GNU_PREFIX="$PROFILE_ROOT/riscv64-gnu-toolchain"
readonly GNU_SYSROOT="$GNU_PREFIX/$TARGET_TRIPLE"
readonly LIBC_PREFIX="$PROFILE_ROOT/libc64"
readonly LIBCRT_PREFIX="$PROFILE_ROOT/libcrt64"
readonly MUSL_PATCH="$REPO_ROOT/ci/musl-riscv64-lp64f.patch"
readonly PROFILE_MANIFEST="$PROFILE_ROOT/.vortex-rv64imaf-zfh-lp64f"
LAST_BACKUP_DIR=""

log() {
  printf '[vortex-lp64f] %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

cmake_version_ok() {
  local major
  local minor
  read -r major minor < <(
    "$1" --version 2>/dev/null |
      sed -n '1{s/[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p;q;}'
  )
  [[ -n "${major:-}" && -n "${minor:-}" ]] &&
    (( major > 3 || (major == 3 && minor >= 20) ))
}

run_with_retry() {
  local description="$1"
  local attempt
  shift

  for ((attempt = 1; attempt <= GIT_RETRY_COUNT; ++attempt)); do
    if "$@"; then
      return 0
    fi
    if [[ "$attempt" -lt "$GIT_RETRY_COUNT" ]]; then
      log "WARNING: $description failed (attempt $attempt/$GIT_RETRY_COUNT); retrying"
      sleep $((attempt * 2))
    fi
  done
  die "$description failed after $GIT_RETRY_COUNT attempts"
}

ensure_checkout() {
  local repo_url="$1"
  local repo_dir="$2"
  local repo_ref="$3"
  local recursive="$4"
  local allowed_patch="${5:-}"
  local ignore_submodules="${6:-0}"
  local clone_args=()
  local dirty_ok=0
  local status

  if [[ ! -d "$repo_dir/.git" ]]; then
    [[ ! -e "$repo_dir" ]] || die "$repo_dir exists but is not a Git checkout"
    [[ "$recursive" == 1 ]] && clone_args+=(--recursive)
    log "Cloning $repo_url"
    run_with_retry "clone of $repo_url" \
      git clone "${clone_args[@]}" "$repo_url" "$repo_dir"
  elif [[ "$SKIP_CLONE" == 0 ]]; then
    log "Updating refs in $repo_dir"
    run_with_retry "fetch in $repo_dir" \
      git -C "$repo_dir" fetch --tags origin
  fi

  if [[ "$ignore_submodules" == 1 ]]; then
    status=$(git -C "$repo_dir" status --porcelain --ignore-submodules=all)
  else
    status=$(git -C "$repo_dir" status --porcelain)
  fi
  if [[ -n "$allowed_patch" ]] &&
     git -C "$repo_dir" apply --reverse --check "$allowed_patch" >/dev/null 2>&1 &&
     [[ "$status" == $' M src/setjmp/riscv64/longjmp.S\n M src/setjmp/riscv64/setjmp.S' ]]; then
    dirty_ok=1
  fi
  if [[ "$dirty_ok" == 0 && -n "$status" ]]; then
    die "managed checkout has local changes: $repo_dir"
  fi
  git -C "$repo_dir" checkout --detach "$repo_ref"
  if [[ "$recursive" == 1 ]]; then
    git -C "$repo_dir" submodule update --init --recursive
  fi
}

prepare_gnu_submodules() {
  local gnu_src="$1"
  local attempt

  log "Configuring GNU submodule mirrors"
  git -C "$gnu_src" submodule sync -- binutils gcc newlib
  git -C "$gnu_src" config submodule.binutils.url "$BINUTILS_GIT_MIRROR"
  git -C "$gnu_src" config submodule.newlib.url "$NEWLIB_GIT_MIRROR"

  for ((attempt = 1; attempt <= GIT_RETRY_COUNT; ++attempt)); do
    log "Initializing GNU build submodules (attempt $attempt/$GIT_RETRY_COUNT)"
    if git -C "$gnu_src" -c protocol.version=2 submodule update \
        --init --depth 1 --jobs "$GIT_SUBMODULE_JOBS" -- binutils gcc newlib; then
      return 0
    fi
    if [[ "$attempt" -lt "$GIT_RETRY_COUNT" ]]; then
      log "WARNING: submodule update failed; retrying"
      sleep $((attempt * 2))
    fi
  done

  die "failed to initialize binutils/gcc/newlib submodules after $GIT_RETRY_COUNT attempts"
}

detect_llvm_ref() {
  local version_text
  local commit

  [[ -n "$LLVM_REF" ]] && return
  version_text=$("$LLVM_PREFIX/bin/clang" --version)
  commit=$(sed -n '1{s/.* \([0-9a-f]\{40\}\)).*/\1/p;}' <<<"$version_text")
  if [[ -n "$commit" ]]; then
    LLVM_REF="$commit"
  else
    LLVM_REF=vortex_3.x
    log "WARNING: could not extract the installed LLVM commit; using $LLVM_REF"
  fi
}

feature_is_supported() {
  local feature="$1"
  local output
  local status

  set +e
  output=$(printf '' | "$LLVM_PREFIX/bin/clang" \
    --target="$TARGET_TRIPLE" -march="$TARGET_ARCH" -mabi="$TARGET_ABI" \
    -Xclang -target-feature -Xclang "+$feature" \
    -c -x c -o /dev/null - 2>&1)
  status=$?
  set -e
  [[ $status == 0 ]] || return 1
  ! grep -Eqi 'not a recognized feature|unknown target feature|unsupported' <<<"$output"
}

detect_vortex_feature() {
  if [[ -n "$VORTEX_TARGET_FEATURE" ]]; then
    feature_is_supported "$VORTEX_TARGET_FEATURE" ||
      die "Vortex Clang does not support +$VORTEX_TARGET_FEATURE"
    return
  fi

  if feature_is_supported xvortex; then
    VORTEX_TARGET_FEATURE=xvortex
  elif feature_is_supported vortex; then
    VORTEX_TARGET_FEATURE=vortex
  else
    die "installed Clang supports neither +xvortex nor +vortex"
  fi
}

validate_profile_destination() {
  local existing
  if [[ -f "$PROFILE_MANIFEST" ]]; then
    grep -qx 'arch=rv64imaf_zfh' "$PROFILE_MANIFEST" ||
      die "profile manifest has a different architecture: $PROFILE_MANIFEST"
    grep -qx 'abi=lp64f' "$PROFILE_MANIFEST" ||
      die "profile manifest has a different ABI: $PROFILE_MANIFEST"
    grep -qx "vortex_feature=$VORTEX_TARGET_FEATURE" "$PROFILE_MANIFEST" ||
      die "profile was built with a different Vortex target feature: $PROFILE_MANIFEST"
    return
  fi

  if [[ -d "$PROFILE_ROOT" ]]; then
    existing=$(find "$PROFILE_ROOT" -mindepth 1 -maxdepth 1 -print -quit)
    [[ -z "$existing" ]] || die \
      "PROFILE_ROOT is non-empty and is not an existing managed lp64f profile: $PROFILE_ROOT"
  fi
}

write_profile_manifest() {
  local profile_state="$1"
  {
    printf 'arch=%s\n' "$TARGET_ARCH"
    printf 'abi=%s\n' "$TARGET_ABI"
    printf 'vortex_feature=%s\n' "$VORTEX_TARGET_FEATURE"
    printf 'llvm_ref=%s\n' "$LLVM_REF"
    printf 'musl_ref=%s\n' "$MUSL_REF"
    printf 'state=%s\n' "$profile_state"
  } > "$PROFILE_MANIFEST"
}

copy_for_backup() {
  local source="$1"
  local destination="$2"
  local cp_help
  cp_help=$(cp --help 2>&1 || true)
  if grep -q -- '--reflink' <<<"$cp_help"; then
    cp -a --reflink=auto "$source" "$destination"
  else
    cp -a "$source" "$destination"
  fi
}

backup_existing_profile() {
  local timestamp
  local relative_path
  local component_count=0
  local backup_paths=()
  local resolved_backup_root
  local resolved_profile_root

  if [[ "$AUTO_BACKUP" == 0 ]]; then
    log "Automatic profile backup is disabled"
    return 0
  fi
  if [[ ! -f "$PROFILE_MANIFEST" ]]; then
    log "No existing managed profile; backup is not needed"
    return 0
  fi

  if [[ "$SKIP_GNU" == 0 && -e "$GNU_PREFIX" ]]; then
    [[ ! -L "$GNU_PREFIX" ]] || die "refusing to overwrite symlinked GNU profile: $GNU_PREFIX"
    backup_paths+=(riscv64-gnu-toolchain)
    ((component_count += 1))
  fi
  if [[ "$SKIP_MUSL" == 0 && -e "$LIBC_PREFIX" ]]; then
    [[ ! -L "$LIBC_PREFIX" ]] || die "refusing to overwrite symlinked libc profile: $LIBC_PREFIX"
    backup_paths+=(libc64)
    ((component_count += 1))
  fi
  if [[ "$SKIP_COMPILER_RT" == 0 && -e "$LIBCRT_PREFIX" ]]; then
    [[ ! -L "$LIBCRT_PREFIX" ]] || die "refusing to overwrite symlinked compiler-rt profile: $LIBCRT_PREFIX"
    backup_paths+=(libcrt64)
    ((component_count += 1))
  fi
  if [[ "$component_count" -eq 0 ]]; then
    log "No selected existing components require backup"
    return 0
  fi

  resolved_profile_root=$(realpath -m "$PROFILE_ROOT")
  resolved_backup_root=$(realpath -m "$BACKUP_ROOT")
  if [[ "$resolved_backup_root" == "$resolved_profile_root" ||
        "$resolved_backup_root" == "$resolved_profile_root/"* ]]; then
    die "BACKUP_ROOT must be outside PROFILE_ROOT"
  fi

  timestamp=$(date '+%Y%m%d-%H%M%S')
  LAST_BACKUP_DIR="$BACKUP_ROOT/${timestamp}-$$"
  mkdir -p "$LAST_BACKUP_DIR"
  backup_paths+=(.vortex-rv64imaf-zfh-lp64f)

  log "Backing up components before overwrite: $LAST_BACKUP_DIR"
  for relative_path in "${backup_paths[@]}"; do
    copy_for_backup "$PROFILE_ROOT/$relative_path" "$LAST_BACKUP_DIR/"
  done
  {
    printf 'source_profile=%s\n' "$PROFILE_ROOT"
    printf 'created_at=%s\n' "$timestamp"
    printf 'components='
    printf '%s ' "${backup_paths[@]:0:component_count}"
    printf '\n'
  } > "$LAST_BACKUP_DIR/backup-info.txt"
}

apply_musl_patch() {
  local musl_src="$1"
  if git -C "$musl_src" apply --reverse --check "$MUSL_PATCH" >/dev/null 2>&1; then
    log "musl lp64f setjmp patch is already applied"
  else
    git -C "$musl_src" apply --check "$MUSL_PATCH" ||
      die "musl lp64f patch does not apply cleanly to $MUSL_REF"
    git -C "$musl_src" apply "$MUSL_PATCH"
    log "Applied riscv64 lp64f setjmp/longjmp patch"
  fi
}

find_archive_member() {
  local archive="$1"
  local pattern="$2"
  local member
  while IFS= read -r member; do
    if [[ "$member" =~ $pattern ]]; then
      printf '%s\n' "$member"
      return 0
    fi
  done < <("$LLVM_PREFIX/bin/llvm-ar" t "$archive")
  return 1
}

extract_member() {
  local archive="$1"
  local member="$2"
  local destination="$3"
  "$LLVM_PREFIX/bin/llvm-ar" p "$archive" "$member" > "$destination"
}

verify_single_float_object() {
  local object="$1"
  local label="$2"
  local header
  local attributes

  header=$("$LLVM_PREFIX/bin/llvm-readelf" -h "$object")
  attributes=$("$LLVM_PREFIX/bin/llvm-readelf" -A "$object")
  grep -q 'ELF64' <<<"$header" || die "$label is not ELF64"
  grep -q 'single-float ABI' <<<"$header" || die "$label is not tagged lp64f"
  grep -q 'zfh' <<<"$attributes" || die "$label does not advertise Zfh"
  if grep -Eq '(^|_)d[0-9]+p[0-9]+' <<<"$attributes"; then
    die "$label unexpectedly advertises the D extension"
  fi
}

verify_profile() {
  local verify_dir="$WORK_ROOT/verify-rv64imaf-zfh-lp64f"
  local libc_archive="$LIBC_PREFIX/lib/libc.a"
  local builtins_archive="$LIBCRT_PREFIX/lib/baremetal/libclang_rt.builtins-riscv64.a"
  local member
  local double_member
  local disassembly
  local nm_output

  mkdir -p "$verify_dir"

  [[ -f "$libc_archive" ]] || die "missing musl archive: $libc_archive"
  for member in sinf.o setjmp.o longjmp.o; do
    extract_member "$libc_archive" "$member" "$verify_dir/$member"
    verify_single_float_object "$verify_dir/$member" "musl $member"
  done

  disassembly=$("$LLVM_PREFIX/bin/llvm-objdump" -d "$verify_dir/sinf.o")
  grep -Eq '\bvx_split(_n)?\b' <<<"$disassembly" ||
    die "musl sinf.o has no Vortex split instruction"
  grep -q '\bvx_join\b' <<<"$disassembly" ||
    die "musl sinf.o has no Vortex join instruction"

  disassembly=$("$LLVM_PREFIX/bin/llvm-objdump" -d "$verify_dir/setjmp.o" "$verify_dir/longjmp.o")
  if grep -Eq '\b(fld|fsd)\b' <<<"$disassembly"; then
    die "musl setjmp/longjmp still contains D-extension loads or stores"
  fi

  nm_output=$("$LLVM_PREFIX/bin/llvm-nm" -A "$libc_archive")
  grep -Eq '[[:space:]]U[[:space:]]+_Exit$' <<<"$nm_output" ||
    die "musl exit path does not reference the Vortex-provided _Exit symbol"

  [[ -f "$builtins_archive" ]] || die "missing compiler-rt archive: $builtins_archive"
  member=$(find_archive_member "$builtins_archive" 'truncsfhf2.*\.o$') ||
    die "compiler-rt is missing __truncsfhf2"
  extract_member "$builtins_archive" "$member" "$verify_dir/truncsfhf2.o"
  verify_single_float_object "$verify_dir/truncsfhf2.o" "compiler-rt $member"

  double_member=$(find_archive_member "$builtins_archive" 'adddf3.*\.o$') ||
    die "compiler-rt is missing the software-double helper __adddf3"
  extract_member "$builtins_archive" "$double_member" "$verify_dir/adddf3.o"
  verify_single_float_object "$verify_dir/adddf3.o" "compiler-rt $double_member"
  disassembly=$("$LLVM_PREFIX/bin/llvm-objdump" -d "$verify_dir/adddf3.o")
  grep -Eq '\bvx_split(_n)?\b' <<<"$disassembly" ||
    die "compiler-rt $double_member has no Vortex split instruction"
  grep -q '\bvx_join\b' <<<"$disassembly" ||
    die "compiler-rt $double_member has no Vortex join instruction"
}

need_cmd git
need_cmd cp
need_cmd date
need_cmd realpath
[[ "$GIT_RETRY_COUNT" =~ ^[1-9][0-9]*$ ]] || die "GIT_RETRY_COUNT must be a positive integer"
[[ "$GIT_SUBMODULE_JOBS" =~ ^[1-9][0-9]*$ ]] || die "GIT_SUBMODULE_JOBS must be a positive integer"
if [[ "$SKIP_GNU" == 0 || "$SKIP_MUSL" == 0 ]]; then
  need_cmd make
fi
need_cmd "$LLVM_PREFIX/bin/clang"
need_cmd "$LLVM_PREFIX/bin/clang++"
need_cmd "$LLVM_PREFIX/bin/llvm-ar"
need_cmd "$LLVM_PREFIX/bin/llvm-ranlib"
need_cmd "$LLVM_PREFIX/bin/llvm-readelf"
need_cmd "$LLVM_PREFIX/bin/llvm-objdump"
need_cmd "$LLVM_PREFIX/bin/llvm-nm"
[[ -f "$MUSL_PATCH" ]] || die "missing patch: $MUSL_PATCH"

if [[ "$SKIP_COMPILER_RT" == 0 ]]; then
  need_cmd ninja
  need_cmd "$LLVM_PREFIX/bin/llvm-config"
  if [[ -z "$CMAKE_BIN" ]]; then
    CMAKE_BIN=$(command -v cmake || true)
  fi
  [[ -n "$CMAKE_BIN" && -x "$CMAKE_BIN" ]] || die "CMake is required; use --cmake PATH"
  cmake_version_ok "$CMAKE_BIN" || die "compiler-rt requires CMake 3.20 or newer"
fi

detect_llvm_ref
detect_vortex_feature
validate_profile_destination
mkdir -p "$WORK_ROOT" "$PROFILE_ROOT"

readonly VORTEX_FEATURE_FLAGS="-Xclang -target-feature -Xclang +$VORTEX_TARGET_FEATURE"
readonly COMMON_TARGET_FLAGS="--target=$TARGET_TRIPLE --sysroot=$GNU_SYSROOT --gcc-toolchain=$GNU_PREFIX -march=$TARGET_ARCH -mabi=$TARGET_ABI -mcmodel=$CODE_MODEL $VORTEX_FEATURE_FLAGS -fdata-sections -ffunction-sections"

log "Configuration"
log "  PROFILE_ROOT=$PROFILE_ROOT"
log "  WORK_ROOT=$WORK_ROOT"
log "  LLVM_PREFIX=$LLVM_PREFIX"
log "  LLVM_REF=$LLVM_REF"
log "  ISA/ABI=$TARGET_ARCH/$TARGET_ABI"
log "  Vortex feature=+$VORTEX_TARGET_FEATURE"
log "  Automatic backup=$AUTO_BACKUP"
log "  BACKUP_ROOT=$BACKUP_ROOT"

backup_existing_profile
write_profile_manifest in-progress

if [[ "$SKIP_GNU" == 0 ]]; then
  GNU_SRC="$WORK_ROOT/riscv-gnu-toolchain"
  GNU_BUILD="$WORK_ROOT/build-riscv-gnu-rv64imaf-zfh-lp64f"
  ensure_checkout "$RISCV_GNU_REPO" "$GNU_SRC" "$RISCV_GNU_REF" 0 "" 1
  prepare_gnu_submodules "$GNU_SRC"
  mkdir -p "$GNU_BUILD"
  if [[ ! -f "$GNU_BUILD/Makefile" ]]; then
    log "Configuring the baseline GNU toolchain"
    (
      cd "$GNU_BUILD"
      CFLAGS_FOR_TARGET="-Os -mcmodel=$CODE_MODEL" \
      CXXFLAGS_FOR_TARGET="-Os -mcmodel=$CODE_MODEL" \
        "$GNU_SRC/configure" \
          --prefix="$GNU_PREFIX" \
          --with-arch="$TARGET_ARCH" \
          --with-abi="$TARGET_ABI" \
          --with-cmodel="$CODE_MODEL" \
          --disable-gdb \
          --disable-multilib
    )
  fi
  log "Building the baseline GNU/newlib toolchain"
  make -C "$GNU_BUILD" -j"$JOBS" newlib
else
  log "Skipping the GNU toolchain build"
fi

[[ -d "$GNU_SYSROOT/include" ]] || die "missing GNU sysroot headers: $GNU_SYSROOT/include"
[[ -x "$GNU_PREFIX/bin/$TARGET_TRIPLE-gcc" ]] || die "missing GNU cross compiler under $GNU_PREFIX"

if [[ "$SKIP_MUSL" == 0 ]]; then
  MUSL_SRC="$WORK_ROOT/musl"
  MUSL_BUILD="$WORK_ROOT/build-musl-rv64imaf-zfh-lp64f"
  ensure_checkout "$MUSL_REPO" "$MUSL_SRC" "$MUSL_REF" 0 "$MUSL_PATCH"
  apply_musl_patch "$MUSL_SRC"
  mkdir -p "$MUSL_BUILD"

  if [[ ! -f "$MUSL_BUILD/config.mak" ]]; then
    log "Configuring musl with Vortex Clang"
    (
      cd "$MUSL_BUILD"
      CC="$LLVM_PREFIX/bin/clang --target=$TARGET_TRIPLE" \
      AR="$LLVM_PREFIX/bin/llvm-ar" \
      RANLIB="$LLVM_PREFIX/bin/llvm-ranlib" \
      CFLAGS="$COMMON_TARGET_FLAGS" \
        "$MUSL_SRC/configure" --prefix="$LIBC_PREFIX" --disable-shared
    )
  fi
  log "Building and installing Vortex musl"
  make -C "$MUSL_BUILD" -j"$JOBS"
  make -C "$MUSL_BUILD" install
else
  log "Skipping the Vortex musl build"
fi

if [[ "$SKIP_COMPILER_RT" == 0 ]]; then
  if [[ -z "$LLVM_SRC_DIR" ]]; then
    LLVM_SRC_DIR="$WORK_ROOT/llvm-vortex"
    ensure_checkout "$LLVM_REPO" "$LLVM_SRC_DIR" "$LLVM_REF" 0
  fi
  [[ -f "$LLVM_SRC_DIR/compiler-rt/CMakeLists.txt" ]] ||
    die "compiler-rt source is missing under LLVM_SRC_DIR=$LLVM_SRC_DIR"

  CRT_BUILD="$WORK_ROOT/build-compiler-rt-rv64imaf-zfh-lp64f"
  mkdir -p "$CRT_BUILD"
  log "Configuring compiler-rt with Vortex Clang"
  "$CMAKE_BIN" -S "$LLVM_SRC_DIR/compiler-rt" -B "$CRT_BUILD" -G Ninja \
    -UCOMPILER_RT_DEFAULT_TARGET_TRIPLE \
    -ULLVM_CONFIG_PATH \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$LIBCRT_PREFIX" \
    -DLLVM_CMAKE_DIR="$LLVM_PREFIX/lib/cmake/llvm" \
    -DCMAKE_C_COMPILER="$LLVM_PREFIX/bin/clang" \
    -DCMAKE_CXX_COMPILER="$LLVM_PREFIX/bin/clang++" \
    -DCMAKE_ASM_COMPILER="$LLVM_PREFIX/bin/clang" \
    -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
    -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
    -DCMAKE_ASM_COMPILER_TARGET="$TARGET_TRIPLE" \
    -DCMAKE_AR="$LLVM_PREFIX/bin/llvm-ar" \
    -DCMAKE_NM="$LLVM_PREFIX/bin/llvm-nm" \
    -DCMAKE_RANLIB="$LLVM_PREFIX/bin/llvm-ranlib" \
    -DCMAKE_SYSROOT="$GNU_SYSROOT" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_FLAGS="$COMMON_TARGET_FLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_TARGET_FLAGS -fno-rtti -fno-exceptions" \
    -DCMAKE_ASM_FLAGS="$COMMON_TARGET_FLAGS" \
    -DCOMPILER_RT_OS_DIR=baremetal \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BAREMETAL_BUILD=ON \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_CRT=ON \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_INCLUDE_TESTS=OFF

  log "Building and installing Vortex compiler-rt"
  "$CMAKE_BIN" --build "$CRT_BUILD" -j"$JOBS"
  "$CMAKE_BIN" --install "$CRT_BUILD"

  BUILTINS_ARCHIVE=$(find "$LIBCRT_PREFIX" -type f -name 'libclang_rt.builtins-riscv64.a' -print -quit)
  [[ -n "$BUILTINS_ARCHIVE" ]] || die "installed compiler-rt builtins archive was not found"
  if [[ "$BUILTINS_ARCHIVE" != "$LIBCRT_PREFIX/lib/baremetal/libclang_rt.builtins-riscv64.a" ]]; then
    install -D -m 0644 "$BUILTINS_ARCHIVE" \
      "$LIBCRT_PREFIX/lib/baremetal/libclang_rt.builtins-riscv64.a"
  fi
  install -D -m 0644 "$LIBCRT_PREFIX/lib/baremetal/libclang_rt.builtins-riscv64.a" \
    "$LIBCRT_PREFIX/lib/linux/libclang_rt.builtins-riscv64.a"
else
  log "Skipping the Vortex compiler-rt build"
fi

verify_profile

write_profile_manifest complete

log "Profile is ready: $PROFILE_ROOT"
if [[ -n "$LAST_BACKUP_DIR" ]]; then
  log "Previous components were backed up at: $LAST_BACKUP_DIR"
fi
cat <<EOF

Use these paths in a configured Vortex build:
  RISCV_TOOLCHAIN_PATH=$GNU_PREFIX
  LIBC_VORTEX=$LIBC_PREFIX
  LIBCRT_VORTEX=$LIBCRT_PREFIX

Build hardware/runtime with EXT_D_DISABLE and compile kernels with:
  -march=$TARGET_ARCH -mabi=$TARGET_ABI

Do not replace musl libc.a with the GNU/newlib libc.a, and do not inject an
_exit shim. Vortex libvortex.a provides _Exit; the Vortex-built musl exit path
references it.
EOF
