# Focused MXU16 compatibility verification

Latest final-source compatibility check (2026-09-05 18:41): **the MXU16
`gemm_unit_v2` full suite passes after the final MXU input-data TX/RX
preservation change**, including three-row RAW and five-row ACC write-stall
coverage. Earlier end-to-end and other focused results below remain historical
evidence; this final follow-up is explicitly a module-level rerun.

Date: 2026-09-05 15:46 KST.

All four independent VCS suites returned deterministic `status: pass` from
`tools/verify_rtl.py`. No RTL or test fixes were made during these runs.

## Build and source identity

- Source HEAD: `5d8fc73fbaae62cb5cebbd3320b5e8dc5ef0836e`, plus the current
  uncommitted SLR pipeline implementation.
- Dedicated build: `build_slr_compat` (not the primary blackbox build).
- Config: `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`:
  TH16, MXU16, W4, sixteen 32-byte TMEM arrays, eight HBM DMA channels.
- Additional RTL define: `GEMM_SLR_PIPELINE`.
- Configured with `../configure --xlen=64 --tooldir=/opt/vortex
  --prefix=$HOME/tools/vortex` after sourcing the config.
- Simulator: VCS W-2024.09-SP1; host compilers `/usr/bin/gcc` and
  `/usr/bin/g++`; verification runner `/usr/bin/python3`.
- Pair-adapter and 16-array switch Makefiles do not consume `CONFIGS`.
  Their `DEFINES` variable was overridden through `MAKEFLAGS` to include the
  sourced configuration plus `SIMULATION`, `NDEBUG`, `XLEN_64`, and
  `GEMM_SLR_PIPELINE`. Compile logs confirm these exact defines. No generated
  or source Makefile was edited for this override.
- Referenced `harness/rules/testbench.md`, `harness/skills/run-test/SKILL.md`,
  and `harness/skills/add-test-case/SKILL.md` were absent; existing configured
  VCS Makefiles and the required deterministic runner were used.

## Results

| Suite | Runner status | Evidence |
|---|---|---|
| `gemm_unit_v2` | pass | Complete suite, including both nonzero QCOL/QROW reference cases, independent resource indices, three-row d=3 RAW, five-row read/write arbitration, forwarding, constrained random, output backpressure and reset flush |
| `gemm_tmem_dma_ctrl` | pass | Nonzero start-channel wrap, same-edge prepared chaining, high-priority acceptance against fallback, descriptor chunking, exact completion tags and final idle drain |
| `tmem_dma_pair_adapter` | pass | Existing paired 64-byte aggregate to two 32-byte lane compatibility suite |
| `tmem_switch_16bank` | pass | Existing `NUM_BANKS=16`, `DATA_SIZE=32` switch suite |

GEMM unit markers:

- `M3_D3_RAW_STALL_PASSED | rows=3 qdir=row stalls=1 early=0 nominal=3 writes=6`
- `M5_ACC_READ_WRITE_ARBITRATION_PASSED | rows=5 qdir=row write_stalls=2 writes=10`
- `NONLAST_QCOL_CONSUMER_METADATA_PASS qcol_bank=0 held_qrow_bank=1`
- Final scoreboard: admissions 161, retires 160, writes 147, reads 80,
  coincident reads 2, immediate/history forwards 4/4, early holds 19,
  output reads/responses 20/20, stalled input cycles 9. These are the suite's
  reported counters, including its reset-flush scenario, not a blackbox
  performance measurement.

Backend markers:

- `TMEM_START_CHANNEL_WRAP_PASS start_ch=4 words=9 wrapped_channels=0xf`
- `TMEM_DMA_PHASE6_CHAIN_PASS completion_to_activate=0 cache=hit id=0`
- `TMEM_DMA_PHASE6_CACHE_MISS_PASS ... late_high_suppressed_fallback=1`
- `TMEM_DMA_PHASE7_SKEW_PRIORITY_PASS ... late_high_blocks_prepared_fallback=1 no_partial_cfg=1`
- `TMEM_DMA_EXACT_COMPLETION_PASS dma_done_pulses=41 store_done_pulses=17 notify_removed=1`

Logs are under `build_slr_compat/hw/unittest/<suite>/logs/compile.log` and
`logs/sim.log`. The four runner invocations used this pattern from the
configured build, after sourcing the config and appending the SLR define:

```sh
python3 ../tools/verify_rtl.py unittest \
  --path /home/jaeyongjang/project.local/vortex_fpint/build_slr_compat/hw/unittest/gemm_unit_v2 \
  --sim vcs --timeout 600
```

## Simulation executable SHA-256

| Suite | SHA-256 |
|---|---|
| `gemm_unit_v2` | `305d076b721daffc13d4899ec364b4ea001bfb247f4b2a9427a3af8ae48282c7` |
| `gemm_tmem_dma_ctrl` | `6a29b3dcb14e405368477913be76118b80f32f5670300001b34b5a832adb2dbf` |
| `tmem_dma_pair_adapter` | `c35f0d9697f0d84cd89f08f845fa072780bdf263c57aaed6f51499ac0610ed30` |
| `tmem_switch_16bank` | `621b1ea32d07c078ddc0254040919d1bf7dede7697beca3ea0450aafe93dd3ae` |

## Scope limitations

The initial four results above are module-level regressions, not a primary
MXU32 performance comparison or physical signoff. The subsequent MXU16
end-to-end results are recorded separately below.
The backend suite directly tests the unchanged SLR0 scheduler; complete
controller-to-backend transport behavior is additionally covered by the new
bridge test and system-level verification owned by the primary task.
No synthesis or PnR was launched by this compatibility verification step.

## MXU16 end-to-end follow-up after early RAM-slot release

Date: 2026-09-05 16:00 KST. Both cases passed numerical reference checking
through `ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --debug 3` from
`build_slr_compat`. This was that build's first xrt-vcs image, compiled fresh
with the SLR pipeline and early Weight RAM-slot release implementation.

| Case | Arguments | Status | Host PERF cycles |
|---|---|---|---:|
| Original nonzero-start-channel wrap / QCOL odd-tail reproducer | `-m 18 -n 78 -k 22 -q 32 -t 1 -d 0 -r 1` | pass | 6325 |
| QROW small odd dimensions | `-m 3 -n 33 -k 33 -q 32 -t 1 -d 1 -r 1` | pass | 5957 |

The compile command contains `MXU_ROW=16`, `MXU_COL=16`, `MXU_COL_TILE=16`,
`MXU_WLOAD_NUM=4`, and `GEMM_SLR_PIPELINE`; application banners independently
confirm `MXU_KT=16`, `MXU_NT=16`, requested dimensions, WTRANS and QDIR. The
same sourced MXU16 config was used for both host/kernel and RTL. Eight RAM
response slots remain unchanged.

`measure_gemm.py` was imported with only its runtime case table replaced by
the two cases above. Its explicit `--config` argument selected the MXU16
config, `--configs-extra=-DGEMM_SLR_PIPELINE` enabled the pipeline, and the
shared vendor simulation library was read from
`/home/jaeyongjang/project.local/vortex_fpint/build/vcs_simlib`. The helper
retained its normal debug flags and `DISABLE_FSDB`; the optional legacy
`DBG_TRACE_GEMM_CMD_PERF` ledger was not enabled. Environment
`GEMM_SLR_FLOORPLAN=0` was used for this simulation-only run.

Both application runs returned zero and printed `PASSED`. The helper's
`tools/verify_rtl.py` pass/failure checks found zero trace failures in the
complete RTL logs. First-case build plus run took 87.8 seconds; the second
case took 5.7 seconds on the same image. These single-sample cycle values
are observations, not an MXU16 2% performance acceptance claim.

Artifacts are retained in `build_slr_compat/compat-integration-results/`:
`summary.json`, per-case `.wrapper.log`, `.app.log`, and `.simv.log.gz`.

| Artifact | SHA-256 |
|---|---|
| `simv` | `f6366af3eb488eb03ab9e6e68659c9899c922d7323c478c81fe163b6d38532ff` |
| `simv.daidir/_1234726_archive_1.so` | `57c81bfd3bc2e3fbb22a8169503d104c60c157d634c2ced001194a908f656509` |
| `simv.daidir/rmapats.so` | `1211e5fd864adc9a7472b6f4d205d129d6cf838f00ab69a14a446cea92387261` |
| `kernel.vxbin` | `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177` |
| `fpint_gemm_ffn_hw` | `3434285b992aeb5d0afb2a469eda6161e7d645e94c03796b9d9a073bdf7e035d` |

Early-release slot trace summaries:

- QCOL: 40 allocations/responses/releases, peak occupancy 8, zero slot-full
  stalls; request-to-response exactly 8 cycles and allocation-to-release
  9–40 cycles (mean 26.2).
- QROW: 36 allocations/responses/releases, peak occupancy 8, zero slot-full
  stalls; request-to-response exactly 8 cycles and allocation-to-release
  exactly 9 cycles.
- Neither small integration case required same-edge slot recycling; the
  dedicated early-release TB supplies that coverage.

No RTL/test fixes, synthesis, or PnR were performed during this follow-up.

## Final candidate: ordered response-stage bypass

Date: 2026-09-05 16:17 KST. The two MXU16 integration cases were rerun after
enabling `RESPONSE_STAGE_BYPASS` for SLR/RAM Weight DMA. Both passed with the
same final-candidate image and no assertion, numerical, or trace failure.

| Case | Final candidate cycles | Ordered response bypass captures | RAM-stage captures |
|---|---:|---:|---:|
| `M18 N78 K22 t1 d0 q32 r1` | 6328 | 9 | 31 |
| `M3 N33 K33 t1 d1 q32 r1` | 5952 | 33 | 3 |

The complete trace contains exactly 40/40/40 and 36/36/36 Weight slot
allocations/responses/releases, respectively. Both reach physical RAM slot
occupancy eight, have zero slot-full stalls, and pass the measurement helper's
complete-and-balanced accounting check. QROW allocation-to-release latency
is 8–9 cycles (mean 8.0833); the preceding early-release-only image required
9 cycles throughout this case. No MXU16 performance threshold is asserted.

The build was reconfigured after sourcing the MXU16 config. The preceding
image and its entire `simv.daidir` were preserved under
`build_slr_compat/compat-integration-results/image/`; the previous target was
renamed `simv.pre_bypass` so the final `simv` target was rebuilt. VCS may reuse
unchanged compiled module archives; the full final executable/shared-object
hash set is retained. The old logs and results were not overwritten.

New artifacts: `build_slr_compat/compat-integration-bypass/summary.json` and
the two sets of wrapper/application/compressed RTL logs. Explicit MXU16/W4
compiler defines and `MXU_KT=16 MXU_NT=16` application banners were checked
again. The helper uses `tools/verify_rtl.py` deterministic checks and reports
`status: pass`, `trace_failures: []` for both runs.

| Final image artifact | SHA-256 |
|---|---|
| `simv` | `b6b48e582e4cad2c2c713317fdab642c4c9aa9c5dac1ea4eef643fa586afa070` |
| `simv.daidir/_1463082_archive_1.so` | `46a950b2e4dca203929cf4b002c64bfd4486d2f381a60095d8ae1d8188823175` |
| `simv.daidir/_prev_archive_1.so` | `8f1880f38f6a928dd7202dbc94d653402329af5bf04ac95a33db5ae5f2abd437` |
| `simv.daidir/rmapats.so` | `1211e5fd864adc9a7472b6f4d205d129d6cf838f00ab69a14a446cea92387261` |

Host executable and kernel SHA-256 remain the same as the preceding
early-release integration table. No RTL edits or synthesis were performed by
this verification follow-up.

## Final MXU input-data preservation: fresh MXU16 unit regression

Date: 2026-09-05 18:41 KST. The final source separates MXU input control from
data and preserves the input data TX/RX FFs against DSP register absorption.
No RTL edits were made by this verification step.

- Fresh independent configured build: `build_slr_final_mxu16_verify`.
- Sourced `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`, then
  appended `-DGEMM_SLR_PIPELINE`; configured XLEN64 using the standard
  `../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`.
- Compile log confirms MXU row/column/tile 16, W4, sixteen 32-byte TMEM arrays
  and the SLR define. The existing unit flow uses its default `FPU_FPNEW`
  numerical model, system GCC/G++, and VCS W-2024.09-SP1.
- Deterministic invocation from that configured build:
  `python3 ../tools/verify_rtl.py unittest --path hw/unittest/gemm_unit_v2
  --sim vcs --timeout 1800`.
- Result: **PASS**, no numerical or assertion failure. Explicit markers:
  `M3_D3_RAW_STALL_PASSED | rows=3 qdir=row stalls=1 early=0 nominal=3 writes=6`,
  `M5_ACC_READ_WRITE_ARBITRATION_PASSED | rows=5 qdir=row write_stalls=2 writes=10`,
  and `VX_gemm_unit_v2 unittest PASSED`.
- Unit `simv` SHA256:
  `9b6ee9b33555237bd36c3a7989297823c59a2f2dc940686283ffe865de0fd3b7`.
- Evidence: `build_slr_final_mxu16_verify/gemm-unit-v2-verification.json` and
  `build_slr_final_mxu16_verify/hw/unittest/gemm_unit_v2/logs/compile.log`
  / `logs/sim.log`. All preceding builds and images remain preserved.

The primary MXU32 version of the same final-source unit suite also passes in
`build_slr_final_verify`, with identical RAW/write-stall event counts and unit
image SHA256
`8b358a6b14f7850d6feb1c3c75686ba130e357588aff5b1ff088db946c54a225`.
Its full-system performance matrix is reported in `simulation-results.md`.

This final MXU16 follow-up does not rerun the two earlier MXU16 blackbox cases
or claim a new MXU16 performance/PnR sign-off. It verifies the modified shared
compute module at the compatibility geometry, including the ACC hazards that
must remain correctly aligned through the crossing pipeline.

## Reset-extraction attributes: fresh MXU16 ACC regression

Date: 2026-09-05 20:04 KST. The final source additionally marks ten existing
resettable crossing-register declarations with `EXTRACT_RESET="yes"`.
Sequential assignments, reset behavior and pipeline depth are unchanged.

- Fresh configured build: `build_slr_reset_mxu16_verify`.
- Sourced the same TH16/MXU16/W4 config and appended
  `-DGEMM_SLR_PIPELINE` before standard XLEN64 configuration.
- Full `gemm_unit_v2` VCS suite through `tools/verify_rtl.py`: **PASS**.
  Its existing default `FPU_FPNEW` unit numerical model is unchanged.
- Explicit RAW marker: `M3_D3_RAW_STALL_PASSED | rows=3 qdir=row stalls=1
  early=0 nominal=3 writes=6`.
- Explicit arbitration marker: `M5_ACC_READ_WRITE_ARBITRATION_PASSED |
  rows=5 qdir=row write_stalls=2 writes=10`.
- Unit image SHA256:
  `676edb0b88c371d2fb4aeef7fce8d747ddde024841a5b982bc829639ccb6d3eb`.
- Evidence: `build_slr_reset_mxu16_verify/gemm-unit-verification.json`,
  plus `hw/unittest/gemm_unit_v2/logs/compile.log` and `logs/sim.log` under
  that build. No attribute-related VCS warning or compilation failure was found.

The matching primary unit suite also passes, image SHA256
`780fc2d39d52f0cd8ef04126b23cb72d5b7f882f3ace8620e5ef890bdfe243e7`.
The new primary twelve-launch full-system matrix passes the per-sample 2%
host threshold; exact results are in `simulation-results.md`.
This is a new shared-compute compatibility check, not a rerun of the earlier
MXU16 blackboxes or a claim of physical reset-pin extraction/SLR closure.
Earlier build images and evidence remain intact.
