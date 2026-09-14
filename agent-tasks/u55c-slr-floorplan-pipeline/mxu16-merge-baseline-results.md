# Fresh pre-merge simulation baselines

Started: 2026-09-06 22:28 KST.
Status: complete on 2026-09-07. Current SLR matrix 12/12, incoming matrix 60/60,
and supplemental corresponding-config matrices 36/36 PASS.
Scope: U1 of `mxu16-merge-plan.md`; simulation only, no synthesis or hardware run.

## Frozen sources and build identity

Snapshot root: `/tmp/vortex-mxu16-merge-baselines-sZPa3R`.
Both sources were exported with `git archive` before the canonical merge.
No snapshot RTL points to the mutable worktree. Initialized AXI,
component_database, CVFPU, HardFloat, Ramulator, and SoftFloat dependencies were
independently archived; required AXI common_cells and Ramulator external headers
were copied, along with the unchanged prebuilt host memory-model libraries.

| Item | Current SLR baseline | Incoming non-SLR baseline |
|---|---|---|
| Revision | `692085b7c4fc93a505d31e4ecd39f9168fe66334` | `27a5cfa0a2ba2f2db2179200ed068b1cd2342a92` |
| Source below snapshot root | `current` | `incoming` |
| Config | `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh` | `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh` |
| Config SHA256 | `eb25b3f8fc154d6af16ab69ca5e9e1f61dde0149fa5bdb35cc3a794d3b33d1ca` | `b5ce4b0957e1d989bcf11682e38131e6f5dfbbdd0713434892f013682f7b9905` |
| Geometry | TH16 / MXU32 / W4 / DMA8 / TMEM8 x 64 B | TH16 / MXU16 / W4 / DMA8 / TMEM16 x 32 B |
| Mode | SLR enabled; timing cuts absent | SLR absent; C2 timing cuts enabled |
| Build below source | `build_w4` | `build_w4` |
| Response storage | RAM / 8 slots | RAM / 8 slots |

Each build sourced its exact configuration before running
`../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`.
Generated `config.mk` was checked for the correct absolute snapshot source,
XLEN64, and `/opt/vortex`; compilation paths also point to that source.

VCS is W-2024.09-SP1. Vendor-only precompiled simulation libraries are read from
`/home/jaeyongjang/project.local/vortex_fpint/build/vcs_simlib` through
`SIMLIB_DIR`. All design RTL, work libraries, and generated floating-point IP
are built independently in each snapshot. Host tools use `/usr/bin` first.
No previous simulator binary was copied.

Shared dependency SHA256:

- Ramulator: `8ebfe0d7ec93f72a5b79c8a9f1a51002f33a3933b93f4490101f972e76a05986`.
- SoftFloat: `f16bec3e8a32ab256cc3a5706c1f52b497d31ba7f7d0a59ad31b846adc66eb34`.

## Measurement method

The frozen current snapshot's `measure_gemm.py` launches every case through
`ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --debug 3`, sources the
configuration on every launch, and saves per-run simulator/application hashes,
wrapper logs, app logs, compressed RTL traces, and strict-check results.
Enabled traces are `DBG_TRACE_PIPELINE/MEM/CACHE/AFU/SCOPE/GBAR/TCU/GEMM`;
`DISABLE_FSDB` suppresses waveform files. `DBG_TRACE_GEMM_CMD_PERF` is not added:
the earlier SLR baseline report records a failure under that optional switch
on an unmodified baseline.

The current baseline uses the existing four-case suite, three launches each:
smoke QCOL, overlap QCOL, QROW, and odd-tail QCOL. The incoming baseline also
covers all 20 shape/QDIR/WTRANS fixtures from its timing-cut plan, three launches
each. A temporary helper `measure_incoming.py` only supplies these cases to the
same frozen measurement/checking implementation; it does not change RTL.

Incoming shapes `(M,K,N)` are `(4,256,256)`, `(1,256,256)`, `(16,256,256)`,
`(32,256,512)`, and `(64,512,256)`, each with `-d {0,1}` x `-t {0,1}`.
Every case uses `-q 32 -r 1`.

The first compile probes used a 300-second timeout; both finished successfully
without extension. Repeated matrices allow 1800 seconds per launch.

## Probe results

Probe arguments: `-m 2 -n 32 -k 128 -q 32 -t 0 -d 0 -r 1`.

| Baseline | Result | Host cycles | Fresh compile + run | simv SHA256 |
|---|---|---:|---:|---|
| Current SLR / MXU32 | PASS | 5800 | 96.0 s | `4af90b1becbc57778fa6af5dd04784316a2802a9c3c0ad96135286d47c1d06a2` |
| Incoming non-SLR / MXU16 | PASS | 5877 | 83.9 s | `e25cc6870d8b6639ca4ecf98a1599190aac560923cfbd5103b3cb24cc3450150` |

Both numerical checks and strict RTL trace checks passed. Current Weight slot
counters were balanced: 32 requests/responses/releases, peak occupancy 8,
14 same-cycle recycles, and 32 response-bypass releases. Incoming RTL does not
emit these slot traces, so no corresponding occupancy claim is made.

## Current SLR repeated baseline

Completed 2026-09-06 22:34 KST: **12/12 PASS**, identical simulator,
compiled-RTL shared-object, and application hashes across every repetition.
All current Weight slot conservation checks passed.

| Case | Host cycles, all three runs | Median |
|---|---|---:|
| Smoke QCOL | 5799, 5874, 5800 | 5800 |
| Overlap QCOL | 6548, 6548, 6547 | 6548 |
| QROW | 6178, 6174, 6174 | 6174 |
| Odd-tail QCOL | 5872, 5872, 5872 | 5872 |

The smoke outlier is preserved rather than discarded; the comparison gate
uses the median, with internal spans retained separately in `summary.json`.

| Case | Input-admission span | Compute-fire span | DMA total span | Final store-accept span |
|---|---|---|---|---|
| Smoke QCOL | 22, 22, 22 | 28, 28, 28 | 139, 148, 140 | 0, 0, 0 |
| Overlap QCOL | 629, 630, 633 | 626, 627, 630 | 868, 874, 872 | 108, 108, 108 |
| QROW | 222, 222, 222 | 216, 216, 216 | 519, 513, 508 | 96, 96, 96 |
| Odd-tail QCOL | 30, 30, 30 | 29, 29, 29 | 177, 177, 176 | 34, 34, 34 |

All span values are cycles, last minus first rather than inclusive counts.
The smoke outlier's compute span is unchanged.

Current repeated-matrix command (run from the repository root):

```bash
SIMLIB_DIR=/home/jaeyongjang/project.local/vortex_fpint/build/vcs_simlib \
/usr/bin/python3 /tmp/vortex-mxu16-merge-baselines-sZPa3R/current/agent-tasks/u55c-slr-floorplan-pipeline/measure_gemm.py \
  --build /tmp/vortex-mxu16-merge-baselines-sZPa3R/current/build_w4 \
  --out /tmp/vortex-mxu16-merge-baselines-sZPa3R/current/results \
  --repeat 3 --timeout 1800
```

Incoming uses the same environment and timeout, with
`/tmp/vortex-mxu16-merge-baselines-sZPa3R/measure_incoming.py`,
`--build .../incoming/build_w4`, `--out .../incoming/results`, and
`--config configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`.
Use new output directories for reproduction; the runner refuses to overwrite
retained evidence.

## Incoming M4 qdir/transpose baseline

The first 12 incoming launches passed: M4/K256/N256 in all four QDIR/WTRANS
combinations, three repetitions each, using the identical compiled image.

| QDIR (`-d`) | WTRANS (`-t`) | Host cycles, all three runs | Median | Compute-fire spans |
|---:|---:|---|---:|---|
| 0 | 0 | 7603, 7527, 7523 | 7527 | 1538, 1537, 1538 |
| 0 | 1 | 7523, 7603, 7523 | 7523 | 1537, 1537, 1537 |
| 1 | 0 | 7602, 7523, 7526 | 7526 | 1532, 1532, 1532 |
| 1 | 1 | 7600, 7523, 7599 | 7599 | 1534, 1532, 1532 |

The unchanged incoming image exhibits an approximately 75--80-cycle
run-to-run host/transport offset, while compute spans stay nearly constant.
The QDIR1/WTRANS1 median falls in the upper group; retain all repetitions and
consider this baseline noise when interpreting a candidate's small cycle
change. No repetitions were excluded or selectively rerun.

Remaining incoming shape results will be recorded when the live matrix finishes.

### Explicit parser checkpoint and equivalent fast scanner

At 2026-09-06 23:06 KST, after 32 complete incoming records, the old measurement
parser was stopped between simulation and result serialization. The exact
owned parser PID and empty child-process list were checked immediately before
SIGTERM; **no active simulation was interrupted**. The unfinished attempt was
M16/K256/N256 QDIR1/WTRANS0 repeat3. Its app log reports numerical PASS and
10539 host cycles, but the wrapper return code had not been serialized and is
therefore recorded as unknown, not fabricated as zero. Its full 281 MB RTL
trace, app log, and wrapper log are preserved alongside
`incoming/results/parser-interruption.json`.

This extra sample is explicitly labelled
`interrupted-by-harness-after-numerical-pass`, not a functional failure or an
accepted strict-check record. All 32 previously completed records remain
unchanged. `resume_incoming.py` computes missing repetition counts from that
original summary and writes only the remainder into new per-case directories
under `incoming/results-resumed/`; repeat indices in each resumed directory
are local indices, not overwrites of original attempts. Final accepted
medians combine all completed original and resumed records, with this
additional interrupted-parser sample separately disclosed.

The replacement scanner differs only by guarding the expensive slot regex
with its required literal `" SLOT_"`; failure and timestamp checks remain
unchanged. The system-verification worker confirmed exact full-metric equality
on 41 MB and 82 MB retained traces and on six crafted failures including line
numbers (`build/experiment-archive/build_mxu16_merge_system_artifacts/scanner-equivalence.json`). The
frozen external helper copy has SHA256
`edda3a2e188a31bd1ada14e36cc44c57690847dc85ad61242fb1024f7dfd0eb7`.
It is used for the resumed incoming runs and the not-yet-started MXU16 SLR
supplemental baseline. The already-running MXU32 local C2 process remains on
the original scanner until it completes. No source RTL or binary changes
accompany this measurement-only checkpoint.

## Supplemental corresponding-config baselines

Started 2026-09-06 22:55 KST, after the primary current baseline completed.
These fresh builds run sequentially alongside the unchanged incoming full
matrix, limiting this baseline task to two measurement jobs at once.
Available resources before launch: 368 GB disk and 429 GiB memory; existing
baseline snapshots/results occupied 2.9 GB.

All use M4/K256/N256 with the four `m4_k256_n256_d{0,1}_t{0,1}` cases,
three repetitions each, matching the candidate secondary gates. They use the
same frozen measurement helper and debug settings, with a 300-second per-run
timeout including each initial compilation. The launcher is
`/tmp/vortex-mxu16-merge-baselines-sZPa3R/run_supplemental.sh`.

| Variant | Frozen source | Build below source | Config wrapper SHA256 |
|---|---|---|---|
| MXU32 local cuts0 | incoming `27a5cfa0` | `build_mxu32_local_cuts0` | `6bb847f9d06311ad3786e4ccdcf180960d6bd668e312468531e55412ab9fb145` |
| MXU32 local C2 | incoming `27a5cfa0` | `build_mxu32_local_c2` | `569880fe7fe6df844e3d392faa1bbf39fda2f2b8e766c52c1fef36f55957aaa3` |
| MXU16 SLR cuts0 | current `692085b7` | `build_mxu16_slr_cuts0` | `4dc6f6c0746a596dd0057b3540d86b0ee6967336ce812dfb0d54cb50a3838fb7` |

The wrappers reside outside the immutable sources in the snapshot root's
`configs/` directory as `mxu32-local-cuts0.sh`, `mxu32-local-c2.sh`, and
`mxu16-slr-cuts0.sh`. Each sources the corresponding native geometry config,
removes any existing SLR/timing-master token, and selects explicit timing
cuts0/1. Local mode removes `GEMM_SLR_PIPELINE` entirely, not `=0`; SLR mode
adds the presence-based define. All keep W4, DMA8, and RAM8 unchanged.
No baseline RTL was changed. Generated build `config.mk` files were checked
for their intended frozen absolute source directories.

Evidence directories are `results-mxu32-local-cuts0`, `results-mxu32-local-c2`,
and `results-mxu16-slr-cuts0` below the snapshot root.

MXU32 local cuts0 completed **12/12 PASS**, with identical simulator,
compiled-RTL shared-object, and application hashes across all repetitions.
Its simv SHA256 is
`cda329402c277257299579d32380a97b1cf96a3a7a310f3b30612a0ab6d02584`.

MXU32 local C2 also completed **12/12 PASS**, with identical simulator,
compiled-RTL shared-object, and application hashes across all repetitions.
Its simv SHA256 is
`1ba4e9f1651cbf8a521e92e703b52e71feb43f54bd4ad78a22376f09ff730326`.

| Variant | M4 d0/t0 median | M4 d0/t1 median | M4 d1/t0 median | M4 d1/t1 median | Result |
|---|---:|---:|---:|---:|---|
| MXU32 local cuts0 | 6472 | 6474 | 6473 | 6475 | 12/12 PASS |
| MXU32 local C2 | 6474 | 6472 | 6473 | 6473 | 12/12 PASS |
| MXU16 SLR cuts0 | 7974 | 7979 | 7977 | 7978 | 12/12 PASS |

## Final baseline acceptance

The incoming original and resumed summaries contain exactly 20 cases with
three accepted, strict-checked repetitions each: 60/60 PASS with return code
zero and no trace failures. All 60 use the same freshly built simulator
identity, `e25cc6870d8b6639ca4ecf98a1599190aac560923cfbd5103b3cb24cc3450150`.
The separately disclosed parser-only interrupted attempt remains excluded
from accepted records, not deleted or fabricated as a complete pass.

Together with the current primary 12 runs and three supplemental matrices
of 12 each, there are **108 accepted baseline measurements**. Initial smoke
probes are additional evidence and are not counted in that total.
All baseline samples and medians are retained in the JSON paths above and in
the paired [complete comparison tables](mxu16-merge/matrix-results.md).

There is no exact pre-merge SLR+C2 baseline: that later activation must be
compared with merged SLR cuts0, not presented as an equivalent old capability.
Raw evidence is below `{current,incoming}/{probe,results}` in the snapshot root.
These configurations differ in geometry and mode: their cycle counts are not
a before/after performance comparison with one another. Each must be compared
with the corresponding merged configuration.
