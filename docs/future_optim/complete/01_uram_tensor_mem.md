# 01 — URAM for tensor_mem_bank

## Target

- `hw/rtl/mem/VX_tensor_mem_bank.sv`
- `hw/rtl/libs/VX_sp_ram.sv`

## Problem

Each of 8 `g_bank[N].u_bank` instances consumes ~35,270 LUTs; ~34,323 LUTs
of that is the inner `VX_sp_ram` going through `VX_async_ram_patch`
(`g_async.g_bram.async_ram_patch`) because the bank used `OUT_REG = 0`
(async read), which Vivado cannot map to BRAM/URAM. The array is implemented
as LUTRAM (`RAMS64E1`, 262,144 primitives → 262 k distributed-RAM LUTs).

Per-bank shape: 64 entries × 512 bits = 32 Kbit, `WRENW = 64` (byte enable),
single port, mutually exclusive R/W.

## Change (in progress)

1. `VX_tensor_mem_bank.sv`: `OUT_REG = 1`, `RDW_MODE = "R"` (moot for
   single-port, but needed to enter the URAM branch),
   `USE_URAM = 1` (force URAM — auto-threshold is 256 Kbit, bank is 32 Kbit).
   External `rsp_data_r` removed; data comes directly from `sram_rdata`,
   which is held stable during `rsp_stall` because `req_fire = 0` freezes
   `read` / `write` and the URAM `rdata_r` register.
2. `VX_sp_ram.sv`: drop the `WRENW == 1` guard from `URAM_COMPATIBLE`
   (URAM has native 9-bit BWE at 8-bit granularity, which matches our
   byte-enable exactly), add `g_wren` variants to the URAM `g_read_first`
   and `g_no_change` branches that mirror the BRAM `g_wren` templates with
   `USE_ULTRA_BRAM` attribute.

## Expected savings

- LUT: ~35 k → < 1 k per bank. Eight banks: **~280 k LUT**.
- URAM: +64 (8 banks × 8 URAMs-wide for 512-bit words), total 6.7 % of
  device. BRAM count unchanged.

## Risks

- URAM read path has no combinational output: 1 extra cycle of pipeline
  latency could appear if Vivado does not fold the external register into
  the URAM OREG. Timing review after synth.
- Depth-padding waste: only 64 of 4096 URAM entries used (1.56 %). Fine on
  U55C since 900+ URAM blocks are free.
- RDW_MODE change from "W" to "R" — verify via rtlsim that no caller
  depends on write-first semantics. For single-port with mutex R/W this
  must be a no-op, but confirm.

## Verification

- `hw/unittest/tensor_mem_bank` — existing directed tests.
- After synth: `hier_utilization.rpt` for `VX_tensor_mem_bank` should drop
  to hundreds of LUTs, URAM column should show 8 per bank.

## Dependencies / follow-ups

- If LUT recovery is still insufficient, move **other LUTRAM consumers** to
  URAM (see [08_uram_other_consumers.md](08_uram_other_consumers.md)).
