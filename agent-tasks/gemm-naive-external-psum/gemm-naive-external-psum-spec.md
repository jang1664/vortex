# GEMM_NAIVE External PSUM Memory Specification

## Status

Confirmed 2026-07-27.

## Goal

Move `GEMM_NAIVE` partial-sum storage from the internal GEMM accumulator
memory to local memory. Preserve the existing internal accumulator memory for
`GEMM_IMPROVE`.

## Scope

- Remove the naive-only ACC-memory-to-LMEM output command.
- Add a tile-local FP32 PSUM allocation and descriptor base address.
- Route GEMM_NAIVE PSUM reads and writes through local memory.
- Give PSUM requests fixed priority over ordinary local-memory requests at
  both physical-lane and local-memory-bank arbitration.
- Verify with `fpint_gemm_ffn_hw_naive`.

## Design decisions

- The PSUM region is one `GEMM_FSM_MT x GEMM_FSM_NT` FP32 tile.
- The naive descriptor uses registers 40 and 41 for its 64-bit PSUM base;
  register 43 remains the output-progress register.
- `GEMM_NAIVE` no longer emits `OP_O_ACC2LMEM` or its notify/wait states.
- On the final accumulation, the GEMM unit writes the FP32 PSUM region and
  directly writes the converted FP16 result to `lmem_obuf`; no follow-up
  ACC-memory output command is used.
- The GEMM unit receives no new back-pressure, retry, or PSUM hazard protocol.
  Any inability to accept the existing PSUM traffic is corrected in the memory
  system.
- Same-bank arbitration is strict: PSUM beats ordinary GEMM, DMA, and CPU
  traffic.

## Constraints

- Do not change the `GEMM_IMPROVE` internal ACC-memory implementation.
- Do not change `configs/naive_gemm_th32_tcol32_hwexp_dcache.sh`.
- Start with small functional inputs; final blackbox PASS cases are
  `-m 1 -k 256 -n 256` and `-m 32 -k 256 -n 256`.
