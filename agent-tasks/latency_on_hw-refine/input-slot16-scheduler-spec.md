# 16-slot Input Scheduler Specification

Status: **confirmed**

## Goal

Remove the scheduler's fixed eight-slot assumption so the improve GEMM design can use a 16-entry Input DMA response-slot pool. Verify with `xrt-vcs-sim` that the representative GEMM cycle count decreases, then run PnR for the improved configuration.

## Scope

- Parameterize the Input slot-count width and budget in:
  - `hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv`
  - `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
  - `hw/rtl/core/gemm/VX_gemm_node.sv`
  - `hw/rtl/mem/VX_tmem_subsystem.sv`
- Add `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_v2.sh` as a copy of the existing improve configuration with the GEMM Input outstanding-slot override set to 16.
- Keep the general LMEM and Weight DMA response-slot settings at 8.

## Design decisions

- `I_LMEM_DMA_RD_OUTSTANDING_SLOTS` is the single configuration source for the GEMM Input DMA queue and scheduler budget.
- Occupancy widths use `$clog2(INPUT_SLOTS + 1)` so the full state (including 16 occupied slots) is representable.
- The existing configuration remains an 8-slot compatibility case. The new `_v2` file selects 16 slots without changing the original file.
- Scheduler policy, priorities, and all non-Input queues remain unchanged.

## Verification and acceptance

1. RTL verification passes through `tools/verify_rtl.py` from a configured build directory.
2. The original 8-slot configuration retains the established cycle result for the same workload.
3. The `_v2` 16-slot configuration passes `xrt-vcs-sim` and reduces GEMM/core cycles for the representative M=256, K=512, N=512 workload; use M=4 as a quicker initial check.
4. After a measured reduction, launch PnR using the `_v2` configuration and retain the job/output location.

## Constraints

- Run simulations and implementation only after sourcing the selected config.
- Run blackbox tests from a configured build directory through `ci/run_black.sh xrt-vcs-sim`.
- Do not alter the original improve configuration or unrelated GEMM behavior.
