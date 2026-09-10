# All-BRAM memory experiment

## Confirmed scope

The user selected BRAM after the TMEM-only comparison and requested an experiment
using BRAM for the remaining SRAMs currently forced into URAM. Adopt
`TMEM_USE_URAM=0` as the default. Add numeric `GEMM_ACC_USE_URAM` and
`LMEM_USE_URAM` selections, defaulting to 1 for compatibility outside the new
experiment. The all-BRAM config explicitly selects zero for all three.

Cover the active GEMM ACC backend, legacy GEMM ACC implementation, and core local
memory. Keep capacity, width, ports, byte enables, read-during-write behavior,
and registered read latency unchanged. Leave small FF/LUTRAM queues and platform
internal memories unchanged. Do not change floorplan ownership or pipeline RTL.

## Configuration and verification

- Derive `improve_th32_tcol32_m32_bigmem_hbm4_tmem8_all_bram.sh` from the existing
  TMEM-only BRAM config; retain full SLR hooks/pipeline, 100 MHz,
  SSI_SpreadSLLs, AlternateCLBRouting, and WLOAD_NUM=4.
- Run focused VCS verification through `tools/verify_rtl.py`, configuration/ini
  integration checks, and fpint GEMM through `ci/run_black.sh xrt-vcs-sim`.
- Configure fresh build directories after sourcing the exact config. Preserve
  completed URAM and TMEM-only BRAM runs as comparison evidence.
- Launch fresh source synthesis/PnR, not a DCP retry. Report completion, setup
  WNS, achieved frequency, routing status, per-SLR RAM utilization, and remaining
  URAM users. Continue 30-minute progress updates during PnR.

## Risks and interpretation

The completed TMEM-only BRAM run achieved 95.4 MHz with WNS -0.472 ns at 100 MHz.
It retained 92 URAMs: 60 in ACC and 32 in core local memory, both in SLR1.
SLR1 already uses 200/672 BRAM tiles. Converting these memories could place
SLR1 around 85-87% BRAM utilization (geometry estimate, not a synthesis result).
BRAM conversion may therefore increase routing pressure; improvement is not
assumed. Behavioral simulation proves functionality, not primitive mapping.
