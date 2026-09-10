# URAM / BRAM source-based PnR

Started: 2026-09-08 21:54 KST. Requested monitoring interval: 30 minutes.
Postfix: `spread_v1`. No automatic retries or RTL/directive changes.

Both runs source their exact config before configure and `run_hw.sh`:

- `configs/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_uram.sh`
- `configs/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_bram.sh`

Settings: Vivado/Vitis 2025.1, U55C, 100 MHz, full-SLR floorplan and pipeline,
GEMM_TIMING_CUTS=1, WLOAD=4, SSI_SpreadSLLs, AlternateCLBRouting,
ultrathreads disabled, congestion early-fail disabled (SLR checks retained).
TMEM mapping is the only configuration difference; ACC/local memories are unchanged.

Independent fresh source-build roots:

| Memory | Build directory |
| --- | --- |
| URAM | `build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1` |
| BRAM | `build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1` |

Each root contains `hw/syn/xilinx/xrt/<config-stem>_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/`.
The expected binary is `bin/vortex_afu.xclbin` underneath that output directory;
it does not exist until a run succeeds.

Run evidence:

`build_timing_cuts_pnr_artifacts/th32_tcol32_m32_bigmem_hbm4_tmem8_<uram|bram>_spread_v1/`

- `state.json`: process identity, timestamps, terminal result and exact paths.
- `build.log`: configure and full hardware build output.
- `sources.json`: SHA-256 manifest, including inherited source configs.
- `worktree.patch`: tracked dirty RTL/build/config changes relative to HEAD.

Read-only monitoring (never loads a DCP):

```bash
python3 agent-tasks/u55c-slr-floorplan-pipeline/tmem-pnr/status.py
```

Snapshots are appended under
`build_timing_cuts_pnr_artifacts/tmem_spread_v1_monitor/history.jsonl`.
Check final routing status, setup and hold reports, achieved frequency, and TMEM
primitive mapping after completion. A failed-route timing report is diagnostic,
not signoff. Existing focused VCS tests passed before launch; this task does not
claim a new exact-config xrt-vcs-sim blackbox result.
