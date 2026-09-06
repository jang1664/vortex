# DMA4 / HBM4 / TMEM8 at fixed 512 KiB

Status: confirmed by user on 2026-09-06. The user requested reducing DMA
channels to four and increasing bank depth to retain total TMEM capacity,
continuing the MXU16 versus MXU32 configuration/performance comparison.

## Goals and constraints

- Both profiles: thread16, HBM4, DMA4, TMEM8, total TMEM 512 KiB.
- MXU16: 32-byte physical bank words, 64 KiB per bank, depth 2048.
- MXU32: 64-byte physical bank words, 64 KiB per bank, depth 1024.
- HBM DMA beats stay 64 bytes. Keep C2 timing cuts enabled in both profiles.
- Do not change the external HBM AXI fabric to support DMA8/HBM4.
- Preserve the existing direct DMA8/TMEM8/MXU32 and paired
  DMA8/TMEM16/MXU16 paths, including write-ACK filtering.
- No PnR, hardware launch, or commit in this task.

## Implementation scope

`VX_tmem_subsystem.sv` currently equates banks per DMA channel with the
HBM/physical width ratio. Extend routing to support ratio1 with two banks
per channel: select one owned bank per 64-byte request based on the
channel-local address, and remove its bank-select bit from the bank row.
With four channels and eight banks, flat 64-byte bank interleaving maps
channel c to banks c and c+4; verify this against descriptor address formation.
Do not split one 64-byte beat into two 64-byte banks. MXU16 retains the
existing simultaneous 64-to-2x32-byte adapter.

Preserve tag-based response association and backpressure. Determine whether
ordering metadata is actually necessary from the DMA read-return contract;
avoid a broad crossbar or unnecessary data reorder buffers. Consume TMEM
write ACKs before returning read responses as in the committed C2 repair.

Update GEMM-node parameter assertions to permit these organizations and
2048-word depth while retaining meaningful geometry/capacity checks. Check
address widths and kernel/runtime layout assumptions for the new geometry.
If a new adapter module is introduced, add a focused directed test.

Configuration files: update the existing m16/hbm4/tmem8 config to 64 KiB
per bank and add an m32 counterpart. Keep unrelated settings identical.

## Verification and measurement

1. Directed RTL tests for old direct/paired paths and new two-bank selection:
   both bank choices, row/depth boundaries, independent bank backpressure,
   delayed/out-of-order responses if permitted by DMA contract, write ACKs,
   and subsequent read association.
2. Fresh configured builds and sourced configs, no stale simulator reuse.
3. `ci/run_black.sh xrt-vcs-sim --perf 3 --app fpint_gemm_ffn_hw` with
   M=1,4,256; K=N256; q32/d0/t0; three launches per shape and profile.
4. Compare only GEMM-node `total_cycles` (median and range), not generic
   processor cycles or host time. Any app mismatch or simulator Error/Fatal
   invalidates the measurement even if the app prints PASSED and exits0.
5. Record exact defines, source and simulator hashes, logs and results.
