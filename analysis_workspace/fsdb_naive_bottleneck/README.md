# GEMM_NAIVE FSDB analysis

Configuration: `configs/naive_gemm_tcol32.sh`, one core, eight threads, QBLK=32,
WTRANS=0, QDIR=0.

## Runs

| Workload | Result | Kernel cycles | Waveform |
|---|---:|---:|---|
| generation: M=1, K=256, N=256 | PASSED | 33,662 | `naive_generation_m1_k256_n256_gemm.fsdb` |
| prefill: M=1024, K=256, N=256 | PASSED | 717,729 | `prefill_checkpoint/vcs_cosim.fsdb` |

The generation waveform is a complete GEMM-only FSDB. The prefill waveform is
a readable checkpoint through tile 16 of 32. It contains all eight M tiles for
the first half of the N/K tile traversal and 256 completed GEMM operations.
Keep every `prefill_checkpoint/vcs_cosim.fsdb*` sidecar together.

The files under `interrupted_unfinalized/` are retained only as records of the
initial full-scope run. They are not valid standalone FSDB inputs.

## Analyze

```bash
python3 analysis_workspace/fsdb_naive_bottleneck/analyze_naive_gemm.py \
  analysis_workspace/fsdb_naive_bottleneck/naive_generation_m1_k256_n256_gemm.fsdb

python3 analysis_workspace/fsdb_naive_bottleneck/analyze_naive_gemm.py \
  analysis_workspace/fsdb_naive_bottleneck/prefill_checkpoint/vcs_cosim.fsdb \
  --partial
```

## Key measurements

| Metric | Generation | Prefill checkpoint |
|---|---:|---:|
| GEMM unit busy / FSM window | 7.78% | 44.89% |
| Weight 16B-side valid stall | 50.4% | 57.8% |
| Weight lane-0 8B-side valid stall | 1.4% | 17.8% |
| Input 64B-side valid stall | 0.0% | 0.0% |
| Weight DMA read-ahead maximum | 1 | 1 |

The 16B weight stream is split into two 8B requests and routed only through
LMEM lane 0. In prefill, the fixed-priority lane arbiter also gives input lane 0
priority over weight traffic, which explains the additional narrow-side stall.
