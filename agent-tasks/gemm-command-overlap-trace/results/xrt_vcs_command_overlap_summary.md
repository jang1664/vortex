# GEMM Command Overlap Summary

## Workloads

| Workload | Cycles | Commands | Max logical concurrency | Compute pipeline cycles |
|---|---:|---:|---:|---:|
| M4 | 273 | 22 | 4 | 76 |
| M256 | 1809 | 44 | 7 | 1257 |
| M384 | 2527 | 66 | 8 | 1940 |

## Tile overlap

All values are raw cycles. Logical command overlap does not imply simultaneous DMA descriptor execution.

| Workload | Tile | Preload-next ∩ compute | Preload tail | Ready slack | Store ∩ next compute | Store ∩ next load | Store ∩ any later load | Store tail | Final store drain |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 37 |
| M256 | 0 | 117 | 0 | 488 | 58 | 0 | 0 | 0 | 0 |
| M256 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 324 |
| M384 | 0 | 121 | 0 | 484 | 209 | 0 | 181 | 0 | 0 |
| M384 | 1 | 179 | 0 | 298 | 58 | 0 | 0 | 0 | 0 |
| M384 | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 324 |
