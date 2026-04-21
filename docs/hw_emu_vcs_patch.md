# hw_emu with VCS — Patch Log

Record of every patch applied to get `v++ --target hw_emu` working with Synopsys
VCS as the RTL simulator (instead of xsim) in this repo. Read top-to-bottom;
each section documents one issue we hit, in the order it surfaced.

## Environment

- Host: Ubuntu 24.04, GCC 13.3.0 system-wide, binutils 2.42
- Vivado / Vitis: 2025.1 (`/tool/Program/Xilinx/2025.1/`)
- VCS: W-2024.09-SP1 (`/tool/Program/synopsys/vcs/W-2024.09-SP1/`)
- Platform: `xilinx_u55c_gen3x16_xdma_3_202210_1` (Alveo U55C)
- Clock: 300 MHz

## Project-Side Changes (tracked in git)

These are in the repo. No manual action needed once the branch is checked out.

### 1. `hw/syn/xilinx/xrt/gen_vitis_ini.py`

Added `--simulator {xsim,vcs}` selection and VCS-specific vivado props:

- `[advanced]`
  - `param=hw_emu.simulator=VCS`
  - `param=project.alignLibraryPathEnvForVCS=true`
- `[vivado]`
  - `prop=project.__CURRENT__.simulator.vcs_install_dir=$(VCS_INSTALL_DIR)`
  - `prop=project.__CURRENT__.compxlib.vcs_compiled_library_dir=$(VCS_SIMLIB_DIR)`
  - `prop=project.__CURRENT__.simulator.vcs_gcc_install_dir=$(VCS_GCC_INSTALL_DIR)`
  - `prop=fileset.sim_1.vcs.compile.vlogan.more_options={-timescale=1ns/1ps +define+XSIM}`
  - (DEBUG only) `prop=fileset.sim_1.vcs.elaborate.vcs.more_options={-debug_access+all}`

`-kdb -lca` are intentionally omitted from the elab options: they require every
prior stage (vlogan, vhdlan, compile_simlib) to also use `-kdb`, which Vivado's
generated compile.sh does not do. Mixing them triggers
`Error-[ANA-KDB-ICS] Incompatible VHDL database Found` at elaborate. `-kdb`
only accelerates Verdi's interactive database load and is not required for
post-sim FSDB analysis — `-debug_access+all` alone is sufficient for
`fsdbDumpvars` in the pre-sim UCLI script. If Verdi interactive debug is ever
needed, the entire pipeline (simlib + vlogan + vhdlan + elab) must be rebuilt
with `-kdb` uniformly.

`+define+XSIM` is kept even for VCS because RTL (e.g. `VX_fp16_mul.sv`,
`fpnew_pkg.sv`) treats `XSIM` as "Vivado simulation context → use Xilinx FP IP",
not as "xsim binary specifically".

### 2. `hw/syn/xilinx/xrt/Makefile`

New user-facing variables:

```make
SIMULATOR          ?= vcs
VCS_INSTALL_DIR    ?= /tool/Program/synopsys/vcs/W-2024.09-SP1/bin
VCS_SIMLIB_DIR     ?= $(VORTEX_HOME)/build/vcs_simlib
VG_GNU_PACKAGE     ?= /tool/Program/synopsys/vcs_gnu/W-2024.09-SP1/linux
VCS_GCC_INSTALL_DIR ?= $(VG_GNU_PACKAGE)/gcc-9.2.0_64-shared/xbin
GUI                ?=
```

- `vcs-simlib` target: one-time `compile_simlib -simulator vcs` run into
  `$(VCS_SIMLIB_DIR)`, producing `synopsys_sim.setup`. Xclbin build depends on
  this stamp when `SIMULATOR=vcs`.
- v++ link recipe prefixes the env so the sub-flow can find VCS and vg_gnu:
  `PATH=$(VCS_INSTALL_DIR):$$PATH VG_GNU_PACKAGE=$(VG_GNU_PACKAGE) VCS_ARCH_OVERRIDE=linux`
- `$(BIN_DIR)/xrt.ini` recipe emits a simulator-aware xrt.ini next to the
  xclbin. When `SIMULATOR=vcs` + `DEBUG` set, it points `user_pre_sim_script`
  at `runtime/xrt/vcs_fsdb.tcl`. `GUI=1` switches `debug_mode=batch→gui`.
- `CONFIG_FINGERPRINT` extended with all new knobs for change detection.

### 3. `runtime/xrt/vcs_fsdb.tcl` (new)

UCLI Tcl that runs before `run`. Dumps full-hierarchy FSDB when DEBUG set:

```tcl
fsdbDumpfile "vortex.fsdb"
fsdbDumpvars 0 /
fsdbDumpMDA
```

Requires `-kdb -debug_access+all -lca` at VCS elaboration (already injected by
`gen_vitis_ini.py` when DEBUG is set).

### 4. `tests/regression/common.mk` & `tests/opencl/common.mk`

`XRT_INI_PATH` now prefers the xclbin-colocated `xrt.ini` when it exists, with
fallback to the static `runtime/xrt/xrt.ini`:

```make
XRT_INI_PATH=$(if $(wildcard $(FPGA_BIN_DIR)/xrt.ini),$(FPGA_BIN_DIR)/xrt.ini,$(VORTEX_RT_PATH)/xrt/xrt.ini)
```

`run-xrt` for `TARGET=hw_emu` now uses a `HW_EMU_LD_PATHS` variable that
prepends everything simv needs at runtime:

```make
VCS_SIMLIB_DIR       ?= $(VORTEX_HOME)/build/vcs_simlib
VCS_SIMLIB_LD_PATH   := $(shell ls -d $(VCS_SIMLIB_DIR)/*/ ... | tr '\n' ':')
HW_EMU_LD_PATHS      := /usr/lib/x86_64-linux-gnu:$(XILINX_XRT)/lib:$(XILINX_VIVADO)/lib/lnx64.o:$(VCS_SIMLIB_LD_PATH):$(VORTEX_RT_PATH):$(LD_LIBRARY_PATH)
```

Rationale:
- `/usr/lib/x86_64-linux-gnu` prepended — simv has vg_gnu's gcc-9.2.0
  libstdc++ on DT_RUNPATH. System libprotobuf.so.32 requires `GLIBCXX_3.4.32`
  (gcc-11+), missing from that old libstdc++. System libstdc++ from gcc-13
  has all old symbols plus the new ones, so prepending makes simv pick it up.
- `$(XILINX_VIVADO)/lib/lnx64.o` — provides `librdizlib.so` and friends that
  simv's emulation runtime loads but are not on its RUNPATH.
- `$(VCS_SIMLIB_DIR)/*` — every per-library subdir under our compiled simlib
  provides a `lib*.so` (e.g. `libsim_qdma_cpp_v1_0.so`) that simv needs at
  startup. simv only stores bare `-l<name>` references, no dir paths.

### 5. `hw/syn/xilinx/kill_sim.sh`

Extended to kill VCS processes (`simv`, `vcs`, `vlogan`, `vcsd`) alongside
existing `xsim`/`xsimk`.

## Host / Tool-Install Patches (sudo, outside repo)

These modify shared install trees. Run once per host; preserved across builds.
Each section lists backup + apply + verify + rollback.

### P1. Install Synopsys `vg_gnu` bundle

Vivado's generated `compile.sh` sources `$VG_GNU_PACKAGE/source_me_gcc920_64.sh`
which ships inside the Synopsys `vg_gnu` package.

```bash
SRC=/tool/SETUP/synopsys/vcs_gnu_vW-2024.09-SP1
DST=/tool/Program/synopsys/vcs_gnu/W-2024.09-SP1
sudo mkdir -p $DST
for f in linux_gcc920_default linux_extra_scripts linux_extra_tools; do
  sudo tar xzf $SRC/$f.tar.gz -C $DST
done
```

Verify: `$DST/linux/source_me_gcc920_64.sh` and
`$DST/linux/gcc-9.2.0_64-shared/bin/gcc` must exist.

### P2. Multiarch `asm/` symlink for Ubuntu 24.04

Ubuntu 24.04's `linux-libc-dev` places asm headers under
`/usr/include/x86_64-linux-gnu/asm/`. Vivado/vg_gnu's bundled gcc does not
search the multiarch path, so `<asm/errno.h>` includes (via `<linux/errno.h>`
in SystemC libs) fail. `sys/`, `bits/`, `gnu/` already exist at
`/usr/include/`; only `asm/` is missing.

```bash
sudo ln -s x86_64-linux-gnu/asm /usr/include/asm
```

Verify: `ls /usr/include/asm/errno.h` must print the file.

Rollback: `sudo rm /usr/include/asm`.

### P3. Replace vg_gnu's old `ld` with system `ld`

vg_gnu ships binutils 2.33.1 (2019). Ubuntu 24.04's glibc uses DT_RELR
relocations (glibc 2.36+), which pre-2.37 binutils cannot read:

```
binutils-2.33.1/bin/ld: /lib/x86_64-linux-gnu/libm.so.6:
  unknown type [0x13] section `.relr.dyn'
```

Replace only `ld` (keep `as`, `ar`, etc. from vg_gnu intact):

```bash
cd /tool/Program/synopsys/vcs_gnu/W-2024.09-SP1/linux/binutils-2.33.1_64/bin
sudo mv ld ld.orig
sudo ln -s /usr/bin/ld ld
```

Verify: `ld --version` in that dir must print `2.42` (system).

Rollback: `sudo mv ld.orig ld` in that dir.

### P4. `sim_qdma_sc_v1_0` — add `vcs:linux` to SIMULATOR_PLATFORM

Vivado 2025.1's `compile_simlib -simulator vcs -library all` silently skips
`sim_qdma_sc_v1_0` because its metadata omits `vcs`. Peer libs include `vcs`;
this is an AMD metadata bug (public thread 0D74U000008uowpSAA reports it has
existed since 2023.2). Without this library, v++ hw_emu compile fails with:

```
pfm_top_sim_qdma_0_0_sc.cpp:52:10: fatal error: sim_qdma.h: No such file or directory
```

```bash
FILE=/tool/Program/Xilinx/2025.1/Vivado/data/systemc/simlibs/sim_qdma_sc/sim_qdma_sc_v1_0/file_info.dat
sudo cp $FILE ${FILE}.orig
sudo sed -i 's|^xsim:linux,questa:linux,riviera:linux$|xsim:linux,questa:linux,riviera:linux,vcs:linux|' $FILE
```

Verify:
```bash
grep -A1 SIMULATOR_PLATFORM $FILE
# Expect: xsim:linux,questa:linux,riviera:linux,vcs:linux
```

Rollback: `sudo cp ${FILE}.orig $FILE`.

### P5. Synopsys SystemC `tlm_fifo.h` — stop requiring `operator<<` for arbitrary T

Synopsys VCS-bundled SystemC 2.3.3's `tlm_fifo.h` unconditionally streams
elements in its debug methods. Xilinx HBM IP (`hbmChannel.h:170`) declares
`tlm::tlm_fifo< std::pair<uint64_t, Fx> > cmdQueue;`. Something triggers
instantiation of the debug methods, which then fail because `std::pair` has
no `operator<<`:

```
tlm_fifo.h:320:36: error: no match for 'operator<<'
  (operand types are 'std::basic_ostream<char>' and 'const std::pair<long unsigned int, Fx>')
```

Three debug-only methods are affected. Replace the offending stream of `elem`
with a placeholder string — the methods remain callable, only the debug output
loses the element value.

```bash
FILE=/tool/Program/synopsys/vcs/W-2024.09-SP1/include/systemc233/tlm_core/tlm_1/tlm_req_rsp/tlm_channels/tlm_fifo/tlm_fifo.h
sudo cp $FILE ${FILE}.orig
sudo sed -i '303s|os << elem << ::std::endl;|os << "<elem>" << ::std::endl;|' $FILE
sudo sed -i '320s|<< elem <<|<< "<elem>" <<|' $FILE
sudo sed -i '332s|s << buf\[ix\];|s << "<elem>";|' $FILE
```

Verify `diff ${FILE}.orig $FILE` shows exactly three hunks on lines 303, 320, 332.

Rollback: `sudo cp ${FILE}.orig $FILE`.

### P6. Install `libncurses5` + `libtinfo5` for VCS-bundled clang

VCS ships a 2014-era `clang-3.4.2` under
`$VCS_HOME/linux64/clang-3.4.2/bin/clang`, which it uses internally to compile
the C code generated from VHDL sources during elaborate. This clang dynamically
links against `libncurses.so.5` and `libtinfo.so.5`, which Ubuntu 24.04
does not ship (only v6 is installed). Elaborate fails in `c.obj/vh/gc.log`:

```
clang-3.4.2/bin/clang: error while loading shared libraries:
  libncurses.so.5: cannot open shared object file: No such file or directory
```

`apt` on Noble doesn't carry these packages directly. Install the jammy
(Ubuntu 22.04) versions manually:

```bash
cd /tmp
wget http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.1_amd64.deb
wget http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libncurses5_6.3-2ubuntu0.1_amd64.deb
ls libtinfo5_*.deb libncurses5_*.deb   # confirm both files landed in cwd
sudo dpkg -i libtinfo5_*.deb libncurses5_*.deb
```

Both packages live under `universe/n/ncurses/` (not `main/`). `security.ubuntu.com`
and `archive.ubuntu.com` mirror the same content; either works. If `wget` returns
404, fall back to browsing `https://packages.ubuntu.com/jammy/amd64/libtinfo5/download`
and `https://packages.ubuntu.com/jammy/amd64/libncurses5/download` to get the
current mirror URL.

Verify:
```bash
ls /usr/lib/x86_64-linux-gnu/libncurses.so.5 /usr/lib/x86_64-linux-gnu/libtinfo.so.5
ldd /tool/Program/synopsys/vcs/W-2024.09-SP1/linux64/clang-3.4.2/bin/clang | grep "not found"
# expected: no "not found" lines
```

Rollback: `sudo apt remove libncurses5 libtinfo5`.

Do NOT substitute via `ln -s libncurses.so.6 libncurses.so.5` — ncurses v5 and
v6 are not ABI-compatible and a symlink may cause subtle runtime failures.

### P7. Hide Vivado's fake `libtinfo.so.5`

Vivado 2025.1 ships a fallback for hosts that lack `libtinfo.so.5`:

```
/tool/Program/Xilinx/2025.1/Vivado/lib/lnx64.o/Ubuntu/24/libtinfo.so.5
/tool/Program/Xilinx/2025.1/Vivado/lib/lnx64.o/Ubuntu/24/libtinfo.so.6.4
```

Both files are byte-identical (a copy of tinfo6 renamed as tinfo5). Vivado
silently adds this directory to `LD_LIBRARY_PATH`, so even when the real
libtinfo5 is installed system-wide (P6), the fake one gets loaded first.
The fake exposes only `NCURSES6_TINFO_*` symbols; the real libncurses5 needs
`NCURSES_TINFO_*`. Result at elaborate:

```
clang-3.4.2: .../Vivado/lib/lnx64.o/Ubuntu/24/libtinfo.so.5:
  version `NCURSES_TINFO_5.6.20061217' not found
  (required by /lib/x86_64-linux-gnu/libncurses.so.5)
```

Replace the fake with a symlink that points at the system libtinfo5 (P6).
Keeping the path populated (symlink, not deletion) is safer than relying on
ld.so fallback to a different directory, and keeps the fix visible in `ls`.

```bash
cd /tool/Program/Xilinx/2025.1/Vivado/lib/lnx64.o/Ubuntu/24
sudo mv libtinfo.so.5 libtinfo.so.5.fake-disabled
sudo ln -s /usr/lib/x86_64-linux-gnu/libtinfo.so.5 libtinfo.so.5
```

Leave `libtinfo.so.6.4` and other files in that directory untouched — they
serve real tinfo6 consumers.

Verify the symlink resolves to the real libtinfo5 and exposes the correct
symbol namespace:

```bash
ls -la /tool/Program/Xilinx/2025.1/Vivado/lib/lnx64.o/Ubuntu/24/libtinfo.so.5
# → libtinfo.so.5 -> /usr/lib/x86_64-linux-gnu/libtinfo.so.5

readelf -V /tool/Program/Xilinx/2025.1/Vivado/lib/lnx64.o/Ubuntu/24/libtinfo.so.5 \
  | grep "Name:" | head -3
# expected: libtinfo.so.5, NCURSES_5.*, NCURSES_TIC_5.* (not NCURSES6_*)
```

Rollback:
```bash
cd /tool/Program/Xilinx/2025.1/Vivado/lib/lnx64.o/Ubuntu/24
sudo rm libtinfo.so.5
sudo mv libtinfo.so.5.fake-disabled libtinfo.so.5
```

If a future Vivado patch overwrites this directory, the symlink will be
replaced by a new bundled fake and elaborate will start failing again — a
clearly diagnosable event. Re-apply P7 after each Vivado upgrade.

## Order of Operations (First-Time Setup)

1. Project checkout (gets the tracked changes in the repo).
2. P1 — install `vg_gnu`.
3. P2 — `asm/` symlink.
4. P3 — `ld` replacement.
5. P4 — `sim_qdma_sc` metadata patch.
6. P5 — `tlm_fifo.h` patch.
7. P6 — install `libncurses5` + `libtinfo5`.
8. P7 — hide Vivado's fake `libtinfo.so.5`.
9. `rm -rf $VORTEX_HOME/build/vcs_simlib` to discard any partially-built cache.
8. Build: `TARGET=hw_emu PLATFORM=<xpfm> NUM_CORES=1 CONFIGS=... make -C hw/syn/xilinx/xrt all`.
   - First invocation compiles Xilinx simlib for VCS (~20 min, cached).
   - Subsequent xclbin builds reuse the simlib.
9. Run: existing test Makefiles pick up the colocated `$(FPGA_BIN_DIR)/xrt.ini`
   automatically. Use `DEBUG=3` for FSDB dump, `GUI=1` for Verdi/DVE.

## Upstream Bug Reports

- **P4** (`sim_qdma_sc_v1_0 SIMULATOR_PLATFORM`) — AMD. Exists since Vivado 2023.2
  per thread `0D74U000008uowpSAA` on AMD Adaptive Support. File as "metadata
  omission" — request `vcs:linux` be added in a Vivado patch.
- **P5** (`tlm_fifo.h`) — Synopsys. Report as "VCS SystemC 2.3.3 `tlm_fifo`
  debug methods require `operator<<` for arbitrary T; breaks when T is
  non-streamable (e.g. `std::pair`) even if methods are never called by user
  code." Xilinx can also be looped in because `hbmChannel.h` is the code that
  triggers it.

## Error → Patch Quick-Reference

| Symptom in log | Root cause | Patch |
|---|---|---|
| `source_me_gcc920_64.sh: No such file` | vg_gnu not installed | P1 |
| `/usr/include/linux/errno.h: fatal error: asm/errno.h: No such file` | Ubuntu multiarch | P2 |
| `ld: libm.so.6: unknown type [0x13] section .relr.dyn` | Old binutils 2.33 vs glibc 2.36+ | P3 |
| `pfm_top_sim_qdma_0_0_sc.cpp: fatal error: sim_qdma.h: No such file` | `sim_qdma_sc_v1_0` skipped for VCS | P4 |
| `tlm_fifo.h: error: no match for 'operator<<' ... 'const std::pair<...>'` | SystemC debug method over-instantiation | P5 |
| `Error-[ANA-KDB-ICS] Incompatible VHDL database Found` at elaborate | `-kdb` at elab without matching `-kdb` at compile/vhdlan/simlib | (project) gen_vitis_ini.py now uses only `-debug_access+all` at elab, not `-kdb -lca` |
| `clang-3.4.2: error while loading shared libraries: libncurses.so.5` in `c.obj/vh/gc.log` during `Error-[VHDL-CODE-COMP]` | VCS bundles 2014-era clang that requires ncurses v5; Ubuntu 24.04 only ships v6 | P6 |
| `libtinfo.so.5: version 'NCURSES_TINFO_5.6.20061217' not found` at elaborate (after P6) | Vivado's `Ubuntu/24/libtinfo.so.5` is a renamed libtinfo6 (NCURSES6_TINFO_* symbols only), shadowing the real libtinfo5 | P7 |
| `./pfm_top_wrapper_simv: error while loading shared libraries: librdizlib.so / libsim_qdma_cpp_v1_0.so / libcommon_cpp_v1_0.so: No such file` at test runtime | LD_LIBRARY_PATH missing Vivado + VCS simlib dirs | (project) `tests/*/common.mk` `HW_EMU_LD_PATHS` prepends `/usr/lib/x86_64-linux-gnu`, Vivado lib, and every `$(VCS_SIMLIB_DIR)/*/` |
| `libstdc++.so.6: version 'GLIBCXX_3.4.32' not found (required by libprotobuf.so.32)` at test runtime | simv's DT_RUNPATH pins vg_gnu's gcc-9.2.0 libstdc++; system libprotobuf (built against gcc-13) needs newer GLIBCXX | (project) `HW_EMU_LD_PATHS` prepends `/usr/lib/x86_64-linux-gnu` so system libstdc++ wins |
| Test PASSED but no `vortex.fsdb` produced and `[HW-EMU 08-2] None of the Kernels compiled in waveform enabled mode` warning | Vitis propagates `user_pre_sim_script` via `USER_PRE_SIM_SCRIPT` env var for xsim but NOT for VCS | (project) `HW_EMU_ENV` in `tests/*/common.mk` extracts `user_pre_sim_script` from the colocated `xrt.ini` and exports `USER_PRE_SIM_SCRIPT` + `VITIS_LAUNCH_WAVEFORM_BATCH=1` |

## Notes

- `VCS_GCC_INSTALL_DIR` points at vg_gnu's `xbin` (Ubuntu-safe wrapper), not
  `bin`. The wrapper unsets `CPATH`-like env vars before invoking the real gcc.
- The Vivado precompiled SystemC simmodel at
  `Vivado/data/simmodels/vcs/W-2024.09-SP1/lnx64/9.2.0/` is built against
  gcc-9.2.0, so `VCS_GCC_INSTALL_DIR` must be gcc-9.x to keep libstdc++ ABI
  consistent between simlib and simv.
- `VCS_ARCH_OVERRIDE=linux` suppresses the VCS "Ubuntu 24.04 unsupported" warning.
