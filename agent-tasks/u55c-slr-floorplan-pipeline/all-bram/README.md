# All-BRAM experiment

Completed result: [results.md](results.md). The xclbin was generated, with zero
routing errors, but 100 MHz setup still fails (95.8 MHz achieved, WNS -0.437 ns).
All URAMs were removed at the cost of 370 additional BRAM tiles versus the
TMEM-only BRAM baseline. Monitoring has ended.

Config: `configs/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_all_bram.sh`.

| SRAM | TMEM-only BRAM baseline | All-BRAM experiment |
| --- | --- | --- |
| TMEM, 8 x 64 KiB | BRAM | BRAM |
| GEMM ACC, 4 x 1024 x 1024 bits | URAM | BRAM |
| Core local memory, 1 MiB | URAM | BRAM |

The numeric selects are `TMEM_USE_URAM`, `GEMM_ACC_USE_URAM`, and
`LMEM_USE_URAM`. The experiment sets all three to zero. Global defaults are
0, 1, and 1 respectively; the explicit URAM TMEM config remains available.
Both active and legacy ACC SRAM implementations honor the ACC selection.
This does not convert small register/LUTRAM queues or platform-internal IP.

Only memory mapping changes. Geometry, read latency, read-first behavior,
byte enables, WLOAD=4, full-SLR floorplan/pipeline, 100 MHz target,
SSI_SpreadSLLs placement, and AlternateCLBRouting remain unchanged.

## Verification and launch

See `STATUS.yaml` for live verification and physical-run results. Focused VCS
tests use `tools/verify_rtl.py`; fpint GEMM uses the existing `measure_gemm.py`
driver through `ci/run_black.sh xrt-vcs-sim` in a fresh configured build.
Simulation does not establish primitive mapping or physical timing closure.

After passing verification, the fresh source PnR command is:

```bash
python3 agent-tasks/u55c-slr-floorplan-pipeline/timing-cuts-pnr/run.py \
  --config configs/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_all_bram.sh \
  --postfix spread_v1 --monitor-interval 1800
```

The runner sources the exact config before configure and records source hashes.
It refuses existing build/evidence directories, and does not retry from DCP.
`--monitor-interval` records metadata; the assistant's monitoring loop schedules
the actual 30-minute snapshots using `all-bram/status.py`.

Artifacts use prefix
`build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_all_bram_spread_v1`;
runner state/logs are in
`build_timing_cuts_pnr_artifacts/th32_tcol32_m32_bigmem_hbm4_tmem8_all_bram_spread_v1`.

## Comparison criteria

Compare with the completed TMEM-only BRAM run in `../tmem-pnr/results.md`:
95.4 MHz achieved, setup WNS -0.472 ns at 100 MHz, zero routing errors,
879.5 BRAM tiles, and 92 URAMs (placed utilization).
Check all-BRAM primitive mapping, per-SLR BRAM occupancy, route completion,
setup/hold slack, achieved frequency, and worst-path identity. Do not assume
that removing URAM improves congestion: ACC/local conversion puts additional
pressure on SLR1 BRAM sites and routing.
