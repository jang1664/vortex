# FSDB Follow-up: GEMM Input Bus After LDMA Prefetch and WR Bypass

## Scope

Run:
- `build/ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_improve --args "-m 128 -n 128 -k 128"`

Artifacts:
- `build/sim/xrtsim_vcs/vcs_cosim.fsdb`
- `build/sim/xrtsim_vcs/simv.log`

Analyzed hierarchy:
- `/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem/u_ldma_input`
- `/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_VX_gemm_unit`

## What Was Limiting Throughput

FSDB before the latest patch showed:
- `ldma_in` source reads already issuing every cycle
- GEMM consumer `in_flight` staying high
- but `u_ldma_input.gemm_bus_if.req_valid` still dropping periodically

The remaining bubble was in the WR side of [`VX_lmem_dma_misal.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_lmem_dma_misal.sv):
- `wr_pull_slot` could fetch a ready response slot
- but `wr_has_data` and `wr_data` were computed from the old `wr_win_r / wr_win_valid_r`
- so a cycle that refilled the write window could not also issue a write

That created a periodic refill bubble even after `RD_PREFETCH_DEPTH=4` was enabled.

## Fix

Added a same-cycle WR bypass in [`VX_lmem_dma_misal.sv`](/home/jaeyongjang/project.local/vortex/hw/rtl/core/gemm/VX_lmem_dma_misal.sv):
- build a combinational `wr_win_pre / wr_win_valid_pre / wr_src_drop_pre`
- append `slot_data_r[wr_expect_slot_r]` when `wr_pull_slot` is true
- compute `wr_has_data` and `wr_data` from the post-pull view instead of the old registered window

This lets a newly available response slot feed the destination write in the same cycle.

## Current Result

With:
- `RD_PREFETCH_DEPTH=4` on input LDMA
- same-cycle WR bypass enabled

the `GEMM_INPUT_VALID` timestamps in steady state are now continuous at `10ns` spacing.

Example window from `simv.log`:
- `143055000`
- `143065000`
- `143075000`
- `143085000`
- `143095000`
- `143105000`
- ...

Diffs:
- `10000ps` repeated for the whole sampled window

That means:
- no remaining `20ns` or `40ns` cadence in steady state
- input bus is now effectively one beat per cycle in this workload window

## Key FSDB Evidence

`GEMM_INPUT_VALID` from `simv.log` over `143.055us .. 143.245us`:
- all adjacent diffs are `10000ps`

`in_pipe_valid_out` from FSDB over `143.050us .. 143.250us`:
- stays asserted through the sampled window

Interpretation:
- the LDMA no longer inserts periodic refill bubbles
- GEMM input pipeline remains fed continuously in steady state

## Notes

- To get a valid comparison FSDB, `simv` must be rebuilt with the same `CONFIGS` used by `run_black.sh`.
- `STACK_BASE_ADDR=8585740288` is still passed as an unsized decimal define in this flow; VCS warns and truncates it. That issue is independent of the LDMA throughput fix.
