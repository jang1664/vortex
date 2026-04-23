# 03 — weight_regs on BRAM/URAM

## Target

- `hw/rtl/core/gemm/VX_gemm_weight_regs_v1.sv` (`u_weight_regs`,
  36,358 LUTs, inside `VX_gemm_unit`)

## Problem

`u_weight_regs` consumes ~36 k LUT. The name implies a weight register
file feeding the PE tree. If implemented as a flat flop array of weights,
it uses O(W × D) FFs and a big read multiplexer in LUTs for the output
port — hence the LUT footprint despite being "just registers".

## Change

Replace the flop array with a memory-backed register file:

- If the read/write pattern is "write once (load), read many (broadcast
  to PEs)", use a BRAM or URAM dual-port configuration:
  - Port A: slow write from DMA / LSU
  - Port B: fast read broadcast to PE tree
- If the weight file is deep (≥ 4K entries × 72 b), URAM fits natively.
  Otherwise BRAM.
- Keep a small flop "stage register" between the RAM output and the PE
  tree to give the synthesizer freedom to pack the RAM output register.

Decision gate: read the module and measure
- number of simultaneously read weights (broadcast fan-out)
- write bandwidth
- total depth × width

If broadcast fan-out is very high (say, 32 PE columns reading unique
weights per cycle), a single-port RAM cannot service all reads; either
**replicate** the RAM per fan-out group, or add a **shift register
broadcast** layer.

## Expected savings

- Rough: 30 k LUT recovered if the register file collapses into BRAM/URAM.
  Costs ~1–4 BRAM (or 1 URAM) depending on depth × width.

## Risks

- High fan-out reads: RAM cannot deliver N independent reads per cycle.
  Mitigation — bank the RAM per PE group.
- Weight load latency: moving from flop to RAM adds 1-cycle read latency
  for the PE tree input.
- Requires reading the actual module before estimating precisely.

## Next steps

1. Read `VX_gemm_weight_regs_v1.sv`; document the access pattern.
2. Identify which signals fan out to which PE columns.
3. Prototype the replacement with `VX_sp_ram` (sync read) or
   `VX_dp_ram` / `XPM_MEMORY_SDPRAM`.
