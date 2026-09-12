# Verification results

Status: Complete. All six required cases passed on baseline, K1 and K2
(18 selected runs), with exit 0 and complete total/node cycle comparisons.
No synthesis, place-and-route, or hardware cost analysis was performed.

## Cycle comparisons

All numeric entries below have exit 0, numerical PASS, and archived simulation
logs without fatal/static-assertion errors. All selected logs were validated by the strict comparison script.
Negative differences mean fewer cycles.

| Case | Cycle metric | Baseline | K1 | K2 | K2 vs baseline | K2 vs K1 |
| --- | --- | ---: | ---: | ---: | --- | --- |
| vecadd n4096 | total | 68471 | 43322 | 43261 | -25210 (-36.82%) | -61 (-0.14%) |
| softmax rev2_shuffle_grouped | total | 100660 | 82636 | 82096 | -18564 (-18.44%) | -540 (-0.65%) |
| improve fpint M32 K128 N32 | total | 6188 | 6122 | 6121 | -67 (-1.08%) | -1 (-0.02%) |
| improve fpint M32 K128 N32 | node | 334 | 334 | 334 | +0 (+0.00%) | +0 (+0.00%) |
| improve fpint M256 K256 N256 | total | 23665 | 23600 | 23599 | -66 (-0.28%) | -1 (-0.00%) |
| improve fpint M256 K256 N256 | node | 17827 | 17827 | 17827 | +0 (+0.00%) | +0 (+0.00%) |
| naive fpint M32 K128 N32 | total | 11115 | 10888 | 10887 | -228 (-2.05%) | -1 (-0.01%) |
| naive fpint M32 K128 N32 | node | 1952 | 1947 | 1947 | -5 (-0.26%) | +0 (+0.00%) |
| naive fpint M256 K256 N256 | total | 106967 | 97376 | 97375 | -9592 (-8.97%) | -1 (-0.00%) |
| naive fpint M256 K256 N256 | node | 97762 | 88452 | 88444 | -9318 (-9.53%) | -8 (-0.01%) |

The complete case-to-log mapping is [cycle-manifest.json](cycle-manifest.json).
Final complete tables are produced with `compare-cycles.py cycle-manifest.json`
from the repository root (supply the task-directory prefixes for both script and manifest).

K1 vecadd and softmax already improve substantially versus the old scalar
adapter/remap/demux path. Their additional K1-to-K2 improvement is smaller.
Do not attribute the entire baseline delta solely to doubling intermediate ports.

## Metric and numerical-check definitions

Total cycles are the final `PERF: instrs=..., cycles=..., IPC=...` snapshot.
FPINT uses `--perf 3`; node cycles are `total_cycles` in the MXU section.
The node forwards the controller counter that counts
`invocation_active_q || gemm_unit_computing`. Both FPINT apps use REPS=1,
QBLK=32, WTRANS=0, QDIR=0. The 256 shape compares all 65536 logical outputs.

The raw `jobs` field is currently accumulator-write count, not invocation
count. Matching dimensions and REPS establish matching invocations. Improve
compute/stall/MAC counters are unpopulated and are not used. Busy and total
kernel counters are sampled by separate CSR instructions. Softmax prints the
same final snapshot twice; the parser accepts identical duplicates only.

## Focused production verification

`tools/verify_rtl.py` reports PASS for production iteration 2. Nine cases cover
K1/2/4/8, single-input/destination bypass, direct/compressed tags, a one-entry
tag buffer and zero requested buffering. Tests check arithmetic address maps
and high bits, tag exhaustion/reuse, reordered response identity, AW/W pairing,
independent stalls, exact-once delivery, stable stalled payloads, and drain.

| P/H/K | Steady interval | Read requests / responses | Write AW / W | Bytes/cycle |
| --- | ---: | ---: | ---: | ---: |
| 2/8/1 | 64 cycles | 64 / 64 | 64 / 64 | 64 |
| 2/8/2 | 64 cycles | 128 / 128 | 128 / 128 | 128 |

Read and write measurements are separate phases at the adapter boundary,
before DMA arbitration. They do not claim application throughput of 128B/cycle.
The valid geometry control and five rejection cases passed: K3/H8, K16/H8,
K1/H3, output address 32 with platform 34, and DATA_WIDTH=1024/DATA_SIZE=64.
The width probes compile successfully and trigger the specific assertions.
Evidence: [production unittest logs](logs/unittest-production/iteration-2/).

## Automatic defaults

Both no-override runs report `CACHE_AXI_TOPOLOGY: P=2 K=2 H=8 AXI_BYTES=64`.
Improve vecadd passes at 43261 cycles; naive small FPINT passes at 10887 kernel
and 1947 node cycles, matching their explicit K2 runs.
Logs: [improve default](logs/improve-default/vecadd-1/),
[naive default](logs/naive-default/small-1/).

## Baseline prerequisites and reproducibility

The naive profile requires explicit `-DLMEM_NUM_PORTS=32 -DLMEM_NUM_BANKS=32`
for the current split-PSUM RTL. All naive variants use those settings, TH16,
and HBM8. Improve uses the planned HBM8/TMEM8 profile. Configurations and
commands are archived per run by `run-case.sh`.

Two existing naive verification issues were minimally corrected before its
baseline: move an assertion after its referenced wire declaration, and guard
a simulation-only checker on known-low reset to avoid speculative VCS tmerge
diagnostics before registered reset relays initialize. Operational assertions
remain enabled. See [baseline prerequisite patch](baseline-prerequisites.patch).

All 335 pre-change RTL files were copied and hash-verified before production
application. The snapshot includes those same prerequisites; later baseline
retries use its RTL_DIR. See [baseline hash manifest](baseline-rtl-sha256.json).
The first naive large attempt timed out at 300s; logs and waveform are retained.
Waveform analysis established finite tile advancement. The 1800s attempt then
printed numerical PASS (106967 kernel cycles, 97762 node cycles), but its
post-run collector failed because the executing shell script had been edited.
Its wrapped-command exit status was not saved, so that attempt is excluded
from the final table. The identical immutable-runner retry completed with exit 0 and numerical PASS,
reproducing 106967 kernel cycles and 97762 node cycles. That successful attempt
(`naive-baseline/large-3`) supplies the final table; the failed collector attempt
remains excluded.
