# Naive ACC minimum-16 buffering

The confirmed scope is in [spec.md](spec.md). The three `_acc.sh` configs now directly select the validated FIFO4 profile.
Historical `current_*` wrappers reconstruct the earlier defaults from the
matching non-ACC configs plus `GEMM_NAIVE_USE_ACC_MEM`. Six wrappers in `configs/` select current or minimum16 capacities
for LMEM16/BW64, LMEM32/BW64 and LMEM32/BW256. Source from the repository root.

The only RTL changes expose existing input/qparam module parameters through
four naive-specific defines and make their occupancy widths parameter-dependent.
Defaults remain input16/8 and qparam8/4. FIFO16 is accepted by the existing
qparam transport; its simulation tag-range assertion also supports the exact
minimum tag width. No parallel implementation or cache changes are introduced.

| Config define | Current effective value | Minimum16 |
|---|---:|---:|
| `DMA_NODE_RD_OUTSTANDING_SLOT` | 32 | 32 |
| `DMA_SPLIT_RSP_DEPTH` | 8 | 16 |
| `W_LMEM_DMA_RD_OUTSTANDING_SLOTS` | 8 | 16 |
| `O_LMEM_DMA_RD_OUTSTANDING_SLOTS` | 16 | 16 |
| `GEMM_NAIVE_INPUT_RESPONSE_SLOTS` | 16 | 16 |
| `GEMM_NAIVE_INPUT_LANE_FIFO_DEPTH` | 8 | 16 |
| `GEMM_NAIVE_QPARAM_RESPONSE_SLOTS` | 8 | 16 |
| `GEMM_NAIVE_QPARAM_LANE_FIFO_DEPTH` | 4 | 16 |

The last four defines are naive-only. Qparam settings apply to both scale and
zero engines. The old generic I/SZ outstanding parameters remain unused in
these naive executors; using their general defaults would alter the existing
quant8slot configuration. Output prefetch depth remains compatibility-only.
Command queues and request/response pipeline holding stages are unchanged.

Before a run, source the wrapper and configure a distinct build:

```bash
source agent-tasks/naive-acc-min16/configs/min16_l16_bw64.sh
mkdir -p build_naive_acc_min16_min16_l16_bw64_vcs
cd build_naive_acc_min16_min16_l16_bw64_vcs
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
cd ..
python3 agent-tasks/naive-acc-select/run.py on \
  --config agent-tasks/naive-acc-min16/configs/min16_l16_bw64.sh \
  --label min16_compare_min16_l16_bw64 \
  --build build_naive_acc_min16_min16_l16_bw64_vcs \
  --cases m4 m256 --rebuild
```

Substitute `current` and/or another topology for other comparisons. Improve
uses this task's `configs/improve.sh`, runner mode `improve`, label
`min16_compare_improve` and build `build_naive_acc_min16_improve_vcs`.
The existing runner refuses to overwrite evidence and uses
`ci/run_black.sh xrt-vcs-sim` plus deterministic `tools/verify_rtl.py` helpers.

`report.py` requires all14 blackbox runs to pass, checks fresh current/improve
cycle identity, and consolidates comparison evidence. `check_identity.py`
compares improve with a Git-restored baseline including headers; generated
baseline RTL and raw logs/waveforms remain local and ignored.

## FIFO4 follow-up

The named `_acc.sh` configs are equivalent to the measured FIFO4 wrappers.
`configs/fifo4_{l16_bw64,l32_bw64,l32_bw256}.sh` source the matching
minimum16 wrapper, then replace only input/qparam lane FIFO16 with FIFO4.
Input/scale/zero response paths are `lane response -> FIFO -> tag-indexed
OOO response RAM -> output stage`. All slots retain their minimum16 settings.
No RTL changes are needed. `verification/fifo4_config_audit.json` records the
exact two define changes for each topology.

Use the same run command above with config `fifo4_<topology>.sh`, label
`min16_compare_fifo4_<topology>` and configured build
`build_naive_acc_min16_fifo4_<topology>_vcs`. The report preserves the original
comparison and appends FIFO16/FIFO4 GEMM and core results.
