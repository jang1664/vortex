# FPFP GEMM regression and rev7 C4 cycle comparison

Status: complete.

- Dedicated FPFP app and FPFP-only 16x16 WLOAD4 configuration implemented.
- All six xrt-vcs-sim runs passed with perf class 3: M=1,4,256; K=N=256.
- FPFP M256: core 91,233 / GEMM 83,317 cycles, all 65,536 outputs bit-exact.
- C4 M256: core 79,660 / GEMM 72,375 cycles.
- Results, reproduction commands and comparison limitations: RESULTS.md.
- The existing earlier RTL changes are preserved; no RTL changes were made for this app task.
- Long-run timeout extension and actual test exit status: m256_timeout_extension.json.
  The controller-only 124 is preserved separately; the actual test exited 0 and passed.
