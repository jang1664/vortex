# TMEM LDMA Queue Depth Sweep Results

## Test Conditions

- Simulator: `xrt-vcs-sim`, VCS W-2024.09-SP1
- Application: `fpint_gemm_ffn_hw`
- Shape: `M=4, N=256, K=256, QBLK=32, WTRANS=0`
- Configuration: GEMM IMPROVE, TH16, 32-column tile, big memory,
  `MXU_WLOAD_NUM=4`, performance class 3
- Directions: QCOL (`QDIR=0`) and QROW (`QDIR=1`)

## XRT-VCS Results

| Case | Direction | Correctness | GEMM cycles | Baseline delta | Busy cycles | DMA+MXU overlap | IPC |
|---|---|---|---:|---:|---:|---:|---:|
| Baseline D4 / S8, W16 | QCOL | PASS | 762 | - | 6,505 | 76.437% (532/696) | 0.973278 |
| Baseline D4 / S8, W16 | QROW | PASS | 763 | - | 6,507 | 76.327% (532/697) | 0.972977 |
| D2 / all S4 | QCOL | PASS | 1,095 | +333 (+43.701%) | 6,807 | 86.789% (900/1,037) | 0.933442 |
| D2 / all S4 | QROW | PASS | 1,096 | +333 (+43.644%) | 6,806 | 86.898% (902/1,038) | 0.933579 |
| D2 / all S8 | QCOL | PASS | 762 | 0 (0.000%) | 6,505 | 76.437% (532/696) | 0.973278 |
| D2 / all S8 | QROW | PASS | 762 | -1 (-0.131%) | 6,506 | 76.437% (532/696) | 0.973127 |

All cases retained identical useful traffic: Input fire/stall 256/0, Weight
fire/stall 512/0, Output fire/stall 32/0, accumulator read/write 168/256,
and no psum underflow or read/write conflict.

The higher overlap percentage in the four-slot case does not indicate higher
performance. Its overlap numerator and measured DMA window both expand because
the reduced response capacity stretches execution by 333 cycles. Relative to
baseline, its effective GEMM throughput is about 30.4% lower. In contrast,
reducing only command depth while retaining eight response slots is cycle-neutral
for this workload.

## Focused Verification

- Common stream queue VCS test: PASS with depth 1/2/4 and Input-mode coverage.
- D2/S4 GEMM node QCOL and QROW: 1024/1024 outputs PASS; 64 commands and 256
  input packets; job done at 12,225 ns.
- D2/S8 GEMM node QCOL and QROW: 1024/1024 outputs PASS; 64 commands and 256
  input packets; job done at 8,845 ns.
- The D2/S4 occupancy-width warning found in the first pass was fixed with an
  explicit zero-extension and independently re-verified with no port-width
  mismatch.

## Reproducibility

Fresh QCOL compiles used these runner fingerprints:

| Case | Compile fingerprint |
|---|---|
| Baseline | `efd0b85d3ec1e8c18ee16bc238ff9bb5e4e8877c8f4fd918012debb8d5d62cee` |
| D2/S4 | `8be3d1ebce8b9c57dd8453757d97b6ef0c721b734d9be0876da190422b0568a7` |
| D2/S8 | `c03b4e63bf7b1d84337dd33cf486bddd23e60f8564a91b65657e8e629df9b941` |

QROW reused the matching QCOL `simv` in every case. Raw manifests, compile
logs, wrapper logs, and simulator logs are under
`build/run_logs/tmem-ldma-queue-depth-sweep/`.
