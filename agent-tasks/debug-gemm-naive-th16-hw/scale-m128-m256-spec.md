# GEMM_NAIVE M128/M256 Accumulator Read Scheduling

## Goal

Make `fpint_gemm_ffn_hw_naive` complete correctly for `M=128` and `M=256`
with `K=256`, `N=256` in the exact th16/b32 XRT-VCS configuration.

## Scope

- `hw/rtl/core/gemm/VX_gemm_unit.sv`
- Exact-config `xrt-vcs-sim` verification for M128 and M256
- M64/K256/N256 regression coverage for the existing PSUM streaming fix

## Observed Failure

The M128 test reaches accumulator address `0x20000` and fails because
`get_acc_mem_idx()` decodes bank 2 while the read scheduler still reports bank
0. The per-parity read addresses advance independently, but
`acc_mem_accum_rd_group` is captured only at command start and never follows
the group bit of the selected address.

## Design Decisions

- Derive the scheduled physical read bank from the selected read address so
  the group bit changes naturally at every accumulator-memory boundary.
- Preserve the two parity schedulers, round-robin selection, per-parity FIFO
  and credit accounting, PSUM LMEM tags, and almost-full startup policy.
- Do not alter output layout/DMA fixes or non-naive behavior beyond the common
  bank decode invariant.

## Constraints and Assumptions

- Use `configs/naive_gemm_th16_b32_tcol32_hwexp_dcache_sxbar_f16.sh`.
- Use a fresh configured build and verify compile defines include
  `GEMM_NAIVE`, `NUM_THREADS=16`, `L1_MEM_PORTS=2`, and `MXU_COL_TILE=32`.
- Required blackbox gates are M128/K256/N256, M256/K256/N256, and the existing
  M64/K256/N256 regression.
- Treat timeout, FIFO underflow/overflow, bank mismatch, data mismatch, or
  assertion failure as a failed iteration.

## Confirmed Specification

Replace the command-static accumulator read group selection with address-based
physical bank decoding while keeping parity-based FIFO scheduling intact. The
change is successful only when both requested larger-M cases and the M64
regression pass fresh exact-config XRT-VCS simulation.

## Iteration 8 Implementation

- `acc_mem_accum_rd_bank` is decoded from the currently selected parity
  stream's address with `get_acc_mem_idx()`.
- The command-static `acc_mem_accum_rd_group` register was removed.
- The simulation invariant now checks that the decoded bank parity still
  matches `acc_mem_accum_rd_sel`; physical group changes are expected.
- PSUM response tags continue carrying the full physical bank, while FIFO and
  credit accounting continue using the parity bit.
