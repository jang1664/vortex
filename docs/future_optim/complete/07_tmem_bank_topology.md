# 07 — Tensor-mem bank count / topology

## Target

- `hw/rtl/mem/VX_tmem_subsystem.sv` — `u_tmem_subsystem`, 772,024 LUTs
- `hw/rtl/mem/VX_tensor_mem_bank.sv`, `VX_mem_arb`

## Problem

`u_tmem_subsystem` holds 67.6 % of `gemm_node`'s area even though the
stored data is only 32 KB total (8 banks × 4 KB). The bulk of the area
is in:
- 8 × `g_bank.u_bank` (tensor memory) — ~35 k LUT each (addressed by
  [01_uram_tensor_mem.md](01_uram_tensor_mem.md))
- 8 × `g_channel.u_dma_unit` in `u_dma_engine` — ~44 k LUT each
  (addressed by [05_dma_engine_slim.md](05_dma_engine_slim.md))
- arbiters, mem-bus plumbing between them

## Research items (no concrete change yet)

1. **Can the bank count be reduced?** 8 banks = 8× replication. If the
   PE tree's aggregate read bandwidth per cycle is, say, 4 × 512 b
   = 256 B / cycle, only 4 banks may be needed — halving banks and
   channels nets ~175 k LUT savings even before [01] and [05].
2. **Can several requestors (DMA / input_read / weight_read / sz_read
   / output_write) share a port instead of hitting the per-bank
   5-to-1 arbiter?** Every saved requestor drops one leg of `VX_mem_arb`
   per bank.
3. **Can bank size grow** to make URAM padding less wasteful? 4 KB
   banks on URAM use 1.56 % of URAM depth. Growing to 256 KB banks
   (4 K entries × 64 B) would saturate a URAM column and also reduce
   bank count.

## Expected savings

Depends heavily on the answers above, but plausibly
**50 k – 150 k LUT** on top of [01] + [05].

## Dependencies

- Requires agreement with the compiler / runtime side on bank count
  and size. Coordinate with the `kernel/` GEMM layout.
- Revisit after [01] + [05] ship, since the baseline area will be
  very different.
