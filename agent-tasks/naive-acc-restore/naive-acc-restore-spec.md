# Restore selectable naive ACC memory

Status: confirmed by the user on 2026-09-29.

## Goal and source

Combine the internal-ACC naive implementation at `f4c65cc86` (the parent of
`4c426bae1`) with the current naive implementation. Do not import the
`feat/gemv` refactor or substitute the improve FSM. Preserve newer fixes.

## Required behavior

- `GEMM_NAIVE_USE_ACC_MEM` defined: internal FP32 ACC for all partial and final
  sums. Undefined: retain current LMEM PSUM and direct final FP16 write paths.
- C2/C3 default ON, depth 512 (256 KiB), and 2 MiB LMEM. Keep software ABI,
  PSUM allocation, and current configuration registers unchanged.
- Restore naive opcode `OP_O_ACC2LMEM=0x23`, output child routing, relative ACC
  addresses, and output copy shape from the historical naive implementation.
  Source strides are FP32 bytes; preserve the naive unit's 64-byte output
  address decoding. Destination remains NT-padded row-major FP16 LMEM.
- Preserve bank decoding, edge-tile effective dimensions, descriptor latching,
  PSUM tag widths, current LMEM/FPU fixes, and output progress reporting.
- Restore RID_O sequence: wait `2*s` before overwriting the LMEM output buffer;
  copy ACC to LMEM; set/wait `2*s+1`; issue HBM STORE and increment notification;
  advance to next compute tile without waiting for this STORE. Final job waits
  for `2*store_count`. ACC OFF retains its existing single-step sequence.
- Strengthen ACC copy completion with actual LMEM write commits. Keep ordinary
  output lane routing; count narrow output request handshakes and actual bank
  commits identified by existing routing tags. Return commit signals through
  mem unit/core. Require output DMA completion/idle, empty output split lanes,
  and zero outstanding writes before output-copy completion notification.
  Gate this machinery to ACC ON; preserve memory bus packet layout.
- Add simulation checks for ACC bounds/alignment, output counter accounting,
  copy-before-STORE, and no ACC overwrite during an active output copy.

## Implementation scope

Primary modules: VX_gemm_unit, VX_gemm_fsm_naive, VX_gemm_sync_naive,
VX_gemm_node_naive. Supporting configuration guards and actual-write feedback
in VX_local_mem, VX_mem_unit, VX_core. Existing external DMA controller remains
the current implementation. No new standalone RTL module is required.

## Verification

Use separate configured build directories for C3 ON and OFF, sourcing
`configs/th32_c1_naive_m32_tcol32.sh` before builds/runs. OFF removes only
`GEMM_NAIVE_USE_ACC_MEM`. Configure with `--xlen=64 --tooldir=/opt/vortex
--prefix="$HOME/tools/vortex"`; use /usr/bin/gcc and /usr/bin/g++ as host compilers.

Run the repository `ci/run_black.sh xrt-vcs-sim` wrapper from each build with
app `fpint_gemm_ffn_hw_naive` and arguments
`-m M -k 256 -n 256 -q 32 -t 0 -d 0 -r 1`, for M=1,16,256 (six cases).
Require exit zero, PASSED, and no RTL assertion errors. Preserve configurations,
commands and per-case application/simulator logs. Inspect M256 sequencing.
Use `--debug 1` and append `-DDBG_TRACE_GEMM -DDEBUG_LEVEL=1` identically in all
six final runs, with `VCS_CPPFLAGS=-DDEBUG_LEVEL=1` for DPI compilation.
The wrapper appends its standard debug defines. Unconditional simulation-only
ACC copy/STORE/overlap markers and immediate assertions retain ordering
evidence without the expensive per-lane FP traces at debug level 3.
C2 compile uses its normal NDEBUG configuration.
Compile/elaborate C2 ON separately with `make -C sim/xrtsim_vcs simv`.
No synthesis, FPGA run, or hw_emu is required by the agreed scope.

## Constraints

- Preserve unrelated pre-existing worktree changes. Do not commit automatically.
- Avoid simulation binary reuse across macro settings and stale incremental RTL.
- Historical passing logs are reference evidence, not verification of this port.
- The legacy verify_rtl.py blackbox CLI hardcodes build/ and bypasses the required
  wrapper. Use the wrapper in isolated builds and its deterministic log/report
  helpers for result classification; do not alter test infrastructure for this.
