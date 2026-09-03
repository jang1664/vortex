# GEMM Post-route Top-five Timing Cone Cuts Specification

Status: **confirmed**

## Objective

Apply the five RTL changes selected from the TH16 `opt_v3` post-route path
analysis, while preserving correctness and keeping end-to-end FPINT GEMM cycle
change within 2% under
`configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh` (WLOAD4).

## Required RTL changes

1. Drive the Weight DMA consume boundary from the registered synchronization
   values instead of the same-cycle `sync_*_next` reduction.
2. Register the GEMM-controller DMA-child prepare offer at the controller
   boundary, keep the queue head stable while it is pending, and do not issue
   the child until that registered offer has handshaken.
3. Specialize the fixed-direction, same-width, one-dimensional output DMA so
   its per-beat destination request/completion control uses descriptor-time
   beat/final-byte state rather than the generic `seg_size - offset` cone.
4. Remove the synthesis-time full-width equality comparison between the
   prepared command and the ordered DMA-child queue head; preserve the ordered
   head contract with simulation assertions.
5. Make the overlap DMA response input unconditionally ready under its
   allocated-slot protocol, and assert in simulation that every valid response
   is owned by a live response slot.

## Behavioral constraints

- Do not add a register to the architectural DMA-done indication.
- Preserve command ordering, same-cycle completion where already supported,
  request address/data/byte-enable behavior, and numerical results.
- A registered speculative prepare offer may add one cycle only before an
  otherwise-unprepared DMA child; it must remain hidden when preparation
  completes before the child becomes issuable.
- Preserve partial final output beats and arbitrary positive one-dimensional
  segment sizes. Do not introduce a fixed 64-byte assumption.
- Keep defensive protocol checks in simulation without rebuilding wide
  comparison/ownership feedback cones for synthesis.

## Verification

- Record a pre-change QDIR=0/1 xrt-vcs-sim baseline for M=N=K=32, QBLK=32,
  WTRANS=0, PERF=3 with the exact requested config.
- Run relevant focused VCS tests through `tools/verify_rtl.py`, including GEMM
  control, TMEM DMA control, stream DMA queue, aligned/local DMA, and GEMM-node
  integration coverage.
- Re-run the identical xrt-vcs-sim cases after the RTL changes. Both numerical
  checks must pass and each end-to-end kernel cycle delta must be at most 2%.
- Do not run OOC synthesis, Vivado synthesis, placement, or routing.
