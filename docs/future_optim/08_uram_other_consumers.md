# 08 — URAM-ize other LUTRAM consumers

## Target

Any other module that currently uses `VX_sp_ram` / `VX_dp_ram` /
`VX_async_ram_patch` with `OUT_REG = 0` or large distributed-RAM
footprints.

## Problem

`LUT as Memory = 266,536` in the baseline utilization report. After
[01_uram_tensor_mem.md](01_uram_tensor_mem.md), 262 k of those (the
RAMS64E1 tensor-bank primitives) are removed. The remaining
~4 k LUTRAM is small — but before declaring victory, scan for any
other OUT_REG=0 instantiations that might be silently landing on
LUTRAM.

## Candidates to audit

Search the repo for `OUT_REG (0)` in `VX_sp_ram` / `VX_dp_ram`
instantiations, plus any direct `reg [X-1:0] mem [0:D-1]` arrays
without a `(* ram_style = ... *)` attribute and with width ≥ 32 b.

Prime suspects (based on inventory, not confirmed):
- `hw/rtl/mem/VX_local_mem.sv` — the per-core local memory
- `hw/rtl/mem/VX_mem_streamer.sv`
- FIFO / queue libraries in `hw/rtl/libs/` — if any expose an async-
  read path
- BHF (`hw/rtl/tcu/bhf/`) storage arrays

## Change

For each candidate:
1. Confirm current mapping via `report_utilization -hierarchical`
   showing `LUT as Memory` or `RAMS*` primitives at the instance.
2. If depth × width justifies block RAM, set `OUT_REG = 1` and
   accept the +1-cycle read latency. Fix up the consumer pipeline
   if necessary (same pattern as the tensor_mem_bank change).
3. If depth × width justifies URAM (≥ 4 K × 72 b), set
   `USE_URAM = 1` and follow the URAM inference rules in
   `docs/sram_doc.md`.

## Expected savings

Unknown without the audit. Bounded above by the remaining `LUT as
Memory` count in the post-[01] synthesis report.

## Risks

Each consumer may rely on zero-cycle read. Re-pipelining must
preserve flow-control semantics (back-pressure, stall).
