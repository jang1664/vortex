# FPFP 8x16, WLOAD1 VCS regression

Status: complete.

All three cases passed: M=1,4,256; K=N=256; xrt-vcs-sim; perf class 3.

| M | Core cycles | GEMM cycles |
|---:|---:|---:|
| 1 | 14,433 | 6,547 |
| 4 | 14,958 | 7,080 |
| 256 | 158,808 | 150,873 |

See RESULTS.md for configuration, verification and comparisons.
The previous 16x16/WLOAD4 results remain in the parent directory.
