# Vortex RV64 Zfh/LP64F Toolchain

This document defines the software-toolchain flow for a 64-bit Vortex target
with native half-precision instructions, single-precision floating-point
registers, and no hardware double-precision extension:

```text
-march=rv64imaf_zfh -mabi=lp64f
RTL: EXT_D_DISABLE
```

The packaging follows the component split used by
[vortex-toolchain-prebuilt](https://github.com/vortexgpgpu/vortex-toolchain-prebuilt)
and the upstream Vortex
[toolchain build guide](https://github.com/vortexgpgpu/vortex/blob/master/docs/building_toolchain.md):

| Component | Compiler | Purpose in this profile |
|---|---|---|
| Vortex LLVM/Clang | Host compiler | Kernel code generation and Vortex split/join lowering |
| RISC-V GNU toolchain | Host GCC | Binutils, GCC driver, headers, sysroot, and baseline libraries |
| musl libc | Vortex Clang | The libc and math implementation actually linked into GPU kernels |
| compiler-rt | Vortex Clang | Integer, half conversion, and software-double helper routines |
| `libvortex.a` | Repository build | Vortex startup, syscall, spawn, and `_Exit` implementation |

The important distinction is that the GNU toolchain is not the final GPU
libc. Copying GNU newlib's `libc.a` or `libm.a` into `libc64` produces ordinary
RISC-V branches inside library routines. Those routines do not contain the
Vortex divergence split/join operations required when different lanes take
different paths. The `libc64` package must therefore be musl compiled with
Vortex Clang.

The GNU toolchain itself is still built in the normal way with the host
compiler; it is not rebuilt *by* Vortex Clang. Vortex Clang consumes its
target sysroot and binutils through `--sysroot` and `--gcc-toolchain`. Only
code that executes as part of a GPU kernel needs Vortex-aware divergence
lowering.

## What `EXT_D_DISABLE` Means for Software

`EXT_D_DISABLE` removes the RISC-V `D` extension from the hardware
configuration. Every linked object must consequently use `lp64f`, not
`lp64d`, and its ISA attributes must not include `D`.

This does **not** remove the C/C++ `double` type. `double` remains a 64-bit
language type. Any double operation in musl or user code is implemented by
compiler-rt software helpers such as `__adddf3` when the target lacks `D`.
For this reason compiler-rt must be rebuilt for `rv64imaf_zfh/lp64f`; reusing
the prebuilt `lp64d` archive is not valid.

`Zfh` provides native half-precision arithmetic and conversion instructions.
Clang defines `__riscv_zfh`, `__riscv_zfhmin`, `__riscv_flen=32`, and
`__riscv_float_abi_single` for the selected ISA/ABI. The latter macro is also
used by the musl assembly patch described below.

## Prerequisites

Install the same host packages required by the upstream Vortex toolchain
guide. At minimum the build needs Git, Make, Ninja, CMake 3.20 or newer, and
the dependencies of `riscv-gnu-toolchain`.

An installed Vortex LLVM is required before running the profile builder. The
script supports both Vortex compiler generations:

- Current Vortex v3 LLVM uses `+xvortex`.
- The LLVM 18 toolchain currently installed at `/opt/vortex/llvm-vortex` uses
  the older `+vortex` spelling.

The script probes the compiler and selects the supported spelling. It also
extracts the LLVM commit from `clang --version` and checks out matching
compiler-rt sources. Set `LLVM_SRC_DIR` and `LLVM_REF` explicitly when the
installed compiler does not report its source commit.

## Build the Profile

The default installation is `/opt/vortex_profiles/rv64imaf_zfh_lp64f` and the
default managed build workspace is
`$HOME/tools/src_vortex_rv64imaf_zfh_lp64f`. Override both when necessary:

```bash
export PROFILE_ROOT=$HOME/tools/vortex-profiles/rv64imaf_zfh_lp64f
export WORK_ROOT=$HOME/tools/src_vortex_rv64imaf_zfh_lp64f
export LLVM_PREFIX=/opt/vortex/llvm-vortex

ci/build_software_vortex_lp64f.sh
```

The script produces:

```text
$PROFILE_ROOT/
├── riscv64-gnu-toolchain/
│   └── riscv64-unknown-elf/       GNU baseline sysroot
├── libc64/                        Vortex-Clang-built musl
│   ├── include/
│   └── lib/libc.a
└── libcrt64/                      Vortex-Clang-built compiler-rt
    └── lib/baremetal/libclang_rt.builtins-riscv64.a
```

Useful incremental options are:

```bash
# Reuse sources without fetching.
ci/build_software_vortex_lp64f.sh --skip-clone

# Reuse a previously built GNU sysroot and rebuild GPU libraries only.
ci/build_software_vortex_lp64f.sh --skip-gnu

# Rebuild only compiler-rt after changing LLVM sources.
ci/build_software_vortex_lp64f.sh --skip-gnu --skip-musl
```

`PROFILE_ROOT` must either be empty or contain the manifest created by an
earlier invocation of this script. An interrupted build can therefore resume,
while an unmanaged directory is rejected to prevent accidental mixing with
prebuilt `rv64imafd/lp64d` files.

## Output and Overwrite Policy

On a successful first run, the persistent outputs are split between the
installation profile and the managed build workspace:

| Path | Contents | First run | Later run |
|---|---|---|---|
| `$PROFILE_ROOT/riscv64-gnu-toolchain` | GCC, binutils, GNU sysroot | Created | Updated unless `--skip-gnu` |
| `$PROFILE_ROOT/libc64` | Vortex musl headers and archives | Created | Updated unless `--skip-musl` |
| `$PROFILE_ROOT/libcrt64` | Vortex compiler-rt archives and CRT objects | Created | Updated unless `--skip-compiler-rt` |
| `$PROFILE_ROOT/.vortex-rv64imaf-zfh-lp64f` | Profile configuration and completion state | Created | Overwritten on every invocation |
| `$WORK_ROOT/riscv-gnu-toolchain` | Managed GNU source checkout | Cloned | Checkout verified; fetching is skipped by `--skip-clone` |
| `$WORK_ROOT/musl` | Managed musl source plus the LP64F patch | Cloned/patched | Reused and patch-checked |
| `$WORK_ROOT/llvm-vortex` | Matching compiler-rt source | Cloned | Checkout verified; fetching is skipped by `--skip-clone` |
| `$WORK_ROOT/build-*` | Incremental configure and object files | Created | Reused and regenerated by Make/CMake |
| `$WORK_ROOT/verify-rv64imaf-zfh-lp64f` | Extracted objects used by validation | Created | Overwritten by validation |

The script does not replace `/opt/vortex` symlinks, does not write hardware
RTL/configuration files, and does not change a configured Vortex build tree.
Those paths are only referenced after the profile has been built.

### Automatic backup

Before a later run installs over an existing managed profile, the script
backs up each component that the current invocation will rebuild. The default
location is outside the profile:

```text
$PROFILE_ROOT.backups/YYYYMMDD-HHMMSS-PID/
├── backup-info.txt
├── .vortex-rv64imaf-zfh-lp64f
├── riscv64-gnu-toolchain/   # present when GNU will be rebuilt
├── libc64/                  # present when musl will be rebuilt
└── libcrt64/                # present when compiler-rt will be rebuilt
```

The copy uses `cp -a --reflink=auto`: it uses copy-on-write storage when the
filesystem supports it and otherwise makes a normal independent copy. It does
not create hard links. If a backup fails, the script exits before changing
the installed profile. Existing component paths that are symbolic links are
rejected so installation cannot follow a link and overwrite another toolchain.

Skipped components are neither overwritten nor backed up. Build/source files
under `WORK_ROOT` are reproducible working data and are not included in the
profile backup.

Use a different backup location when the profile filesystem has limited
space:

```bash
ci/build_software_vortex_lp64f.sh \
  --backup-root /data/toolchain-backups/vortex-lp64f
```

Automatic backup can be disabled explicitly, although this is not recommended
for an existing profile:

```bash
ci/build_software_vortex_lp64f.sh --no-backup
```

After a failed rebuild, the safest non-destructive recovery is to point the
affected Vortex variable directly at the backed-up component while inspecting
the new output:

```bash
export BACKUP_DIR=/data/toolchain-backups/vortex-lp64f/YYYYMMDD-HHMMSS-PID
export LIBC_VORTEX=$BACKUP_DIR/libc64
export LIBCRT_VORTEX=$BACKUP_DIR/libcrt64
export RISCV_TOOLCHAIN_PATH=$BACKUP_DIR/riscv64-gnu-toolchain
```

Only set variables for components present in that backup. The selected paths
are listed in `backup-info.txt`. Backups are never deleted automatically.

### Stage 1: GNU Baseline

The script configures the official RISC-V GNU toolchain as follows:

```bash
../configure \
  --prefix=$PROFILE_ROOT/riscv64-gnu-toolchain \
  --with-arch=rv64imaf_zfh \
  --with-abi=lp64f \
  --with-cmodel=medany \
  --disable-gdb \
  --disable-multilib
make -j$(nproc) newlib
```

Only the `binutils`, `gcc`, and `newlib` submodules needed by this target are
initialized. The full recursive checkout would also download Linux libc,
QEMU, LLVM, and other sources that are not used by `make newlib`.

The upstream `.gitmodules` points binutils and newlib at Sourceware. To avoid
Sourceware HTTP 429 failures, the script uses these mirrors by default:

```text
binutils: https://gnu.googlesource.com/binutils-gdb
newlib:   https://github.com/mirror/newlib-cygwin.git
gcc:      https://github.com/gcc-mirror/gcc.git
```

Submodule initialization is shallow, parallel, and retried three times. The
mirror URLs and retry settings can be overridden with
`BINUTILS_GIT_MIRROR`, `NEWLIB_GIT_MIRROR`, `GIT_RETRY_COUNT`, and
`GIT_SUBMODULE_JOBS`. A recursive clone interrupted by an earlier network
failure can be reused; the script ignores submodule commit-state noise while
still rejecting changes to top-level tracked files.

This creates an internally consistent GCC/sysroot baseline, but its newlib
archives are not copied into `libc64`. GCC does not need to understand Vortex
intrinsics because it is not used to compile the GPU-facing musl and
compiler-rt code.

Headers such as `math.h` are not precompiled GPU implementations. Their
macros and inline functions are compiled as part of the kernel by Vortex
Clang. Out-of-line functions such as `sinf` come from the Vortex-Clang-built
musl `libc.a`, which is where split/join lowering matters.

### Stage 2: Vortex musl

The script checks out musl v1.2.5, applies
[`musl-riscv64-lp64f.patch`](../../ci/musl-riscv64-lp64f.patch),
and compiles it with Vortex Clang using the exact ISA and ABI.

The default source is the `ifduyue/musl` GitHub mirror rather than
`git.musl-libc.org`, which is frequently unreachable from restricted build
networks. It carries the same upstream v1.2.5 tag. Override `MUSL_REPO` if a
different trusted mirror is required. Clone and fetch operations use the same
`GIT_RETRY_COUNT` policy as GNU submodule initialization.

Upstream musl's riscv64 `setjmp.S` and `longjmp.S` use `fsd` and `fld` for
every non-soft-float ABI. That is incorrect for `lp64f`, where only 32-bit
floating-point loads/stores are available. The patch selects `fsw` and `flw`
when `__riscv_float_abi_single` is defined while retaining the existing
eight-byte jmp-buffer slots.

The installed `libm.a` may be very small or empty. This is normal for musl:
the math implementation objects are included in `libc.a`, while the `libm`
archive is retained for link-line compatibility.

### Stage 3: Vortex compiler-rt

compiler-rt must come from the same Vortex LLVM revision as the installed
Clang. It is built with the same target flags and Vortex target feature as
musl. In particular, the archive must provide both:

- Half helpers such as `__extendhfsf2` and `__truncsfhf2`, used when an
  operation cannot be emitted directly as Zfh.
- Software-double helpers such as `__adddf3`, used because hardware `D` is
  disabled.

Both kinds of helper can contain control flow, so compiling this archive with
ordinary GCC is not a safe substitute for Vortex Clang.

For the LLVM 18 compiler-rt source used by the installed Vortex Clang,
`COMPILER_RT_DEFAULT_TARGET_ONLY=ON` derives the target from
`CMAKE_C_COMPILER_TARGET=riscv64-unknown-elf`. Do not also cache
`COMPILER_RT_DEFAULT_TARGET_TRIPLE`; LLVM 18 treats that combination as a
configuration error. The build script removes a stale triple entry from an
existing CMake cache, so the failed build directory can be reused without
deleting it.

## `_Exit`, `_exit`, and Startup Files

Do not inject an `_exit` shim into GNU newlib and do not use GNU newlib as the
kernel libc.

The intended Vortex link path is:

```text
kernel main returns
  -> musl exit
  -> musl _Exit reference
  -> strong _Exit in libvortex.a
  -> performance dump, exit-code MMIO write, fence, thread-mask clear
```

`kernel/src/vx_start.S` supplies Vortex `_start` and `_Exit`, and
`kernel/src/vx_syscalls.c` supplies musl's `__funcs_on_exit` hook. Generic
newlib follows a different `_Exit`/`_exit` contract, which is why merely
changing ABI flags against a stock newlib archive led to startup/runtime link
failures.

Kernel links should keep the current Vortex order:

```text
libvortex.a -L$LIBC_VORTEX/lib -lm -lc \
  $LIBCRT_VORTEX/lib/baremetal/libclang_rt.builtins-riscv64.a
```

The Vortex flow uses `-nostartfiles -nostdlib`; it must not silently pull the
GNU startup files or the default `lp64d` libraries from another sysroot.

## Integrate the Profile with Vortex

Configure a separate 64-bit Vortex build directory. Keep the installed
Vortex LLVM under the normal tool root and override the three profile paths
at Make invocation time:

```bash
mkdir -p build-rv64-zfh-lp64f
cd build-rv64-zfh-lp64f
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex

export LP64F_PROFILE=$HOME/tools/vortex-profiles/rv64imaf_zfh_lp64f
export RISCV_TOOLCHAIN_PATH=$LP64F_PROFILE/riscv64-gnu-toolchain
export LIBC_VORTEX=$LP64F_PROFILE/libc64
export LIBCRT_VORTEX=$LP64F_PROFILE/libcrt64
```

The repository variables use `?=`, so environment or command-line overrides
select this profile without replacing `/opt/vortex` symlinks.

### Build without hardware double precision

Always source the hardware configuration used for the simulation or build,
then append `EXT_D_DISABLE`:

```bash
source ../configs/naive_simd.sh
export CONFIGS="$CONFIGS -DEXT_D_DISABLE"

make -C kernel \
  CONFIGS="$CONFIGS" \
  RISCV_TOOLCHAIN_PATH="$RISCV_TOOLCHAIN_PATH" \
  LIBC_VORTEX="$LIBC_VORTEX" \
  LIBCRT_VORTEX="$LIBCRT_VORTEX"
```

For regression tests, pass the same `CONFIGS` and profile variables from the
configured build directory. RTL blackbox testing in this repository must use
the configured `xrt-vcs-sim` flow, for example:

```bash
ci/run_black.sh xrt-vcs-sim --app APP_NAME --args "..."
```

`EXT_D_DISABLE` makes the current kernel and regression Makefiles choose
`lp64f`, but those files currently spell the ISA as `rv64imaf`. Before an
FP16 kernel can emit native Zfh instructions, their `EXT_D_DISABLE` branches
must be changed to `rv64imaf_zfh`. Keep the ISA string identical across kernel
objects, musl, compiler-rt, and application objects.

The hardware work is separate from this software profile: the decoder must
accept Zfh opcodes and the selected FPU implementation must enable FP16
datapaths. The toolchain build succeeding only proves that software can emit
and link the instructions.

## Validation

The build script automatically checks representative archive members for:

- ELF64 and the RISC-V single-float ABI flag.
- A `zfh` architecture attribute and no `d` architecture attribute.
- `vx_split`/`vx_join` instructions in musl `sinf.o`.
- No `fld`/`fsd` instructions in musl setjmp/longjmp.
- The compiler-rt half conversion helper and Vortex-lowered software-double
  helper.
- An unresolved musl `_Exit` reference to be satisfied by `libvortex.a`.

An independent compiler probe can be run with:

```bash
cat > /tmp/zfh_probe.c <<'EOF'
_Float16 addh(_Float16 a, _Float16 b) { return a + b; }
float widen(_Float16 a) { return (float)a; }
EOF

$LLVM_PREFIX/bin/clang \
  --target=riscv64-unknown-elf \
  -march=rv64imaf_zfh -mabi=lp64f \
  -Xclang -target-feature -Xclang +vortex \
  -S /tmp/zfh_probe.c -o -
```

Use `+xvortex` instead of `+vortex` with Vortex v3 LLVM. The assembly should
contain Zfh operations such as `fadd.h` and `fcvt.s.h` and must not contain
double-precision operations such as `fadd.d`, `fld`, or `fsd`.

Finally, inspect the linked kernel rather than only individual archives:

```bash
$LLVM_PREFIX/bin/llvm-readelf -h path/to/kernel.elf
$LLVM_PREFIX/bin/llvm-readelf -A path/to/kernel.elf
$LLVM_PREFIX/bin/llvm-objdump -d path/to/kernel.elf | \
  rg 'f(add|sub|mul|div)\.h|fcvt\.[a-z]+\.h|vx_(split|join)'
```

The ELF header must report `single-float ABI`, the architecture attributes
must include `zfh` and exclude `d`, and no input object should trigger a
single-float/double-float ABI linker mismatch.
