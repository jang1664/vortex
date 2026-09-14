# MXU16 t8/t16 xrt-vcs-sim validation

Both exact configs pass all seven cases (14/14 total), completed 2026-09-07.

## Setup

- `configs/improve_th16_tcol16_m16_t8_bigmem.sh`: TH16, MXU16x16, eight
  32B TMEM arrays, four 64B HBM/DMA channels, 512KiB total TMEM.
- `configs/improve_th16_tcol16_m16_t16_bigmem.sh`: TH16, MXU16x16, sixteen
  32B TMEM arrays, eight 64B HBM/DMA channels, 512KiB total TMEM.
- Both retain WLOAD_NUM=4, GEMM_TIMING_CUTS=1, GEMM_SLR_PIPELINE and RAM slots8.
- Separate fresh builds, exact config sourced before configure and simulation,
  XLEN64, `/opt/vortex`, system GCC/G++, VCS W-2024.09-SP1, shared vendor simlib.
- Frozen RTL snapshots drive compilation via the make RTL_DIR override.
- `ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --perf 3`, one run per case,
  300-second timeout, no waveform dump. No synthesis/OOC/PnR or RTL/config edits.

## Results

All rows passed numeric output validation, process exit0 and strict simulation
log checks. QDIR is `-d`; WTRANS is `-t`. QBLK=32 and application repetitions=1.
Cycle columns record PERF class3 GEMM_TOTAL_CYC, not host or core elapsed cycles.
These single samples are functional evidence, not a repeated performance study.

| Case | M,N,K | QDIR,WTRANS | t8 cycles | t16 cycles | Result |
|---|---|---|---:|---:|---|
| smoke_qcol | 2,32,128 | 0,0 | 270 | 264 | Both PASS |
| overlap_d0_t0 | 4,256,256 | 0,0 | 2409 | 2494 | Both PASS |
| qrow | 31,64,96 | 1,1 | 1446 | 1430 | Both PASS |
| odd_tail_qcol | 3,33,33 | 0,0 | 263 | 265 | Both PASS |
| overlap_d0_t1 | 4,256,256 | 0,1 | 2409 | 2493 | Both PASS |
| overlap_d1_t0 | 4,256,256 | 1,0 | 2416 | 2444 | Both PASS |
| overlap_d1_t1 | 4,256,256 | 1,1 | 2416 | 2442 | Both PASS |

## Evidence and reproduction

Each build's `perf3-evidence/manifest.json` contains exact config/RTL hashes,
arguments, results, application/kernel hashes and performance counters.
Per-case `.wrapper.log` and `.simv.log.gz` retain raw output and assertion checks.

- `build/experiment-archive/build_gemm_depcuts_m16_t8/perf3-evidence/`
- `build/experiment-archive/build_gemm_depcuts_m16_t16/perf3-evidence/`

The task launcher reuses the previous verified snapshot/blackbox harness:

```sh
python3 agent-tasks/m16-timing-config-validation/run.py --tmem-count 8
python3 agent-tasks/m16-timing-config-validation/run.py --tmem-count 16
```

Those build directories now exist; the launcher deliberately refuses to overwrite
them. Use a new variant name in the harness for a future fresh run.

Both profiles executed identical frozen RTL and their source config hashes were
unchanged at completion. During the run, a separate worktree edit prepended a
16-line explanatory block comment to `VX_gemm_fsm.sv`. The remaining file was
verified byte-identical to the tested snapshot; all other source files matched.
That existing edit was preserved and no functional difference was found.

Passing RTL simulation does not establish physical floorplan, timing or routing
closure for either profile.
