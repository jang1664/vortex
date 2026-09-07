# Preserve separate local and SLR MXU block-index registers

Status: confirmed by the user on 2026-09-07.

## Goal and implementation contract

- Under `GEMM_SLR_PIPELINE`, keep the local prealign block-index state and
  the dedicated MXU input TX state as physically separate FFs. Prevent
  merging in either direction; only crossing FFs receive `USER_SLL_REG`.
- Preserve the existing local delay and unconditional data sampling, valid
  reset semantics, and direct TX Q-to-RX D connection. Add no pipeline cycle.
- Keep non-SLR behavior unchanged. Prefer a local, narrowly scoped change
  over preservation of a whole module or all generic pipeline registers.
- Do not weaken strict ownership, TX/RX, boundary or Laguna checks.

## Verification and physical scope

- Run directed VCS checks for local/transport data and reset/valid timing,
  and xrt-vcs-sim GEMM on current TH32/t4 and TH32/t8 configs. Compare cycles
  with recorded pre-change cases, distinguishing host-cycle sampling noise.
- Use the exact source configs `improve_th32_tcol32_m32_t{4,8}_bigmem.sh`.
  WLOAD_NUM remains 4; MXU32x32, full-SLR floorplan, Explore placement,
  AlternateCLBRouting, no ultrathreads, 100 MHz, no early congestion exit.
- After simulation preflight, run two fresh source builds (including
  configure and synthesis), using a new unique postfix. Do not reuse or
  overwrite the historical `slr_v1` or robust-hook DCP evidence.
- Inspect post-init/post-opt/post-place hook results, physical SLR/Laguna
  checks, terminal PnR/bitstream result and timing. Success requires actual
  evidence, not merely launching the jobs or passing Tcl mocks.
- Record source/config hashes and durable process state. Historical simulation
  manifests for old RTL must not be presented as verification of this change.
- No commit, push, placement-seed search or existing-DCP PnR retry.

## Known failure and limits

Both original source checkpoints have exactly 160 MXU input RX block-index
bits driven by unmarked local prealign FFs. Equivalent-state merging is
consistent with RTL and DCP connectivity. Preserving separate state should
restore roughly 160 FFs relative to the merged result; actual utilization
and physical success must be measured from the new builds.
