# Pre-reference-fix MXU SLR kernel verification

Historical matrix: **38 PASS and 4 baseline-equivalent FAIL** across 42 cases. The user subsequently requested a reference correction and retest; this report is not final task acceptance.

All 6 final variant RTL SHA-256 values match the current `VX_gemm_unit.sv`: `55a40a71e8e434a7e0973d57c1895d7dec07b7728645b25487b1ee9e495dfb90`. Individual hashes, configurations, commands, and logs are preserved in [summary.json](summary.json) and each variant metadata file.

| Variant | PASS | Baseline FAIL | Per-case application evidence |
|---|---:|---:|---|
| [naive_acc_slr0](results/final2_naive_acc_slr0/metadata.json) | 7 | 0 | [M1:P](results/final2_naive_acc_slr0/m1_t0_d0_r1.attempt1.app.log), [M16:P](results/final2_naive_acc_slr0/m16_t0_d0_r1.attempt1.app.log), [M256:P](results/final2_naive_acc_slr0/m256_t0_d0_r1.attempt2.app.log), [T:P](results/final2_naive_acc_slr0/m16_t1_d0_r1.attempt1.app.log), [Q:P](results/final2_naive_acc_slr0/m16_t0_d1_r1.attempt1.app.log), [TQ:P](results/final2_naive_acc_slr0/m16_t1_d1_r1.attempt1.app.log), [M33x2:P](results/final2_naive_acc_slr0/m33_t0_d0_r2.attempt1.app.log) |
| [naive_acc_slr1](results/final2_naive_acc_slr1/metadata.json) | 7 | 0 | [M1:P](results/final2_naive_acc_slr1/m1_t0_d0_r1.attempt1.app.log), [M16:P](results/final2_naive_acc_slr1/m16_t0_d0_r1.attempt1.app.log), [M256:P](results/final2_naive_acc_slr1/m256_t0_d0_r1.attempt2.app.log), [T:P](results/final2_naive_acc_slr1/m16_t1_d0_r1.attempt1.app.log), [Q:P](results/final2_naive_acc_slr1/m16_t0_d1_r1.attempt1.app.log), [TQ:P](results/final2_naive_acc_slr1/m16_t1_d1_r1.attempt1.app.log), [M33x2:P](results/final2_naive_acc_slr1/m33_t0_d0_r2.attempt1.app.log) |
| [naive_noacc_slr0](results/final2_naive_noacc_slr0/metadata.json) | 7 | 0 | [M1:P](results/final2_naive_noacc_slr0/m1_t0_d0_r1.attempt1.app.log), [M16:P](results/final2_naive_noacc_slr0/m16_t0_d0_r1.attempt1.app.log), [M256:P](results/final2_naive_noacc_slr0/m256_t0_d0_r1.attempt2.app.log), [T:P](results/final2_naive_noacc_slr0/m16_t1_d0_r1.attempt1.app.log), [Q:P](results/final2_naive_noacc_slr0/m16_t0_d1_r1.attempt1.app.log), [TQ:P](results/final2_naive_noacc_slr0/m16_t1_d1_r1.attempt1.app.log), [M33x2:P](results/final2_naive_noacc_slr0/m33_t0_d0_r2.attempt1.app.log) |
| [naive_noacc_slr1](results/final2_naive_noacc_slr1/metadata.json) | 7 | 0 | [M1:P](results/final2_naive_noacc_slr1/m1_t0_d0_r1.attempt1.app.log), [M16:P](results/final2_naive_noacc_slr1/m16_t0_d0_r1.attempt1.app.log), [M256:P](results/final2_naive_noacc_slr1/m256_t0_d0_r1.attempt2.app.log), [T:P](results/final2_naive_noacc_slr1/m16_t1_d0_r1.attempt1.app.log), [Q:P](results/final2_naive_noacc_slr1/m16_t0_d1_r1.attempt1.app.log), [TQ:P](results/final2_naive_noacc_slr1/m16_t1_d1_r1.attempt1.app.log), [M33x2:P](results/final2_naive_noacc_slr1/m33_t0_d0_r2.attempt1.app.log) |
| [improve_slr0](results/final2_improve_slr0/metadata.json) | 5 | 2 | [M1:P](results/final2_improve_slr0/m1_t0_d0_r1.attempt1.app.log), [M16:P](results/final2_improve_slr0/m16_t0_d0_r1.attempt1.app.log), [M256:P](results/final2_improve_slr0/m256_t0_d0_r1.attempt2.app.log), [T:P](results/final2_improve_slr0/m16_t1_d0_r1.attempt1.app.log), [Q:F](results/final2_improve_slr0/m16_t0_d1_r1.attempt1.app.log), [TQ:F](results/final2_improve_slr0/m16_t1_d1_r1.attempt1.app.log), [M33x2:P](results/final2_improve_slr0/m33_t0_d0_r2.attempt1.app.log) |
| [improve_slr1](results/final2_improve_slr1/metadata.json) | 5 | 2 | [M1:P](results/final2_improve_slr1/m1_t0_d0_r1.attempt1.app.log), [M16:P](results/final2_improve_slr1/m16_t0_d0_r1.attempt1.app.log), [M256:P](results/final2_improve_slr1/m256_t0_d0_r1.attempt2.app.log), [T:P](results/final2_improve_slr1/m16_t1_d0_r1.attempt1.app.log), [Q:F](results/final2_improve_slr1/m16_t0_d1_r1.attempt1.app.log), [TQ:F](results/final2_improve_slr1/m16_t1_d1_r1.attempt1.app.log), [M33x2:P](results/final2_improve_slr1/m33_t0_d0_r2.attempt1.app.log) |

All cases use K=N=256,q32. T means M16/t1/d0; Q means M16/t0/d1; TQ means M16/t1/d1. Other cases use t0/d0; M33x2 repeats twice. P=PASS; F=baseline-equivalent raw failure. Simulator log paths for every case are included in `summary.json`.

## Baseline and regression evidence

- Immutable commit `73664e653b20cb0b0497d8627fa9c20cea786f8e`: [all 3 M16 baseline kernels passed](results/baseline_summary.json) for naive ACC ON/OFF and improve.
- The first SLR implementation caused LMEM PSUM FIFO underflow for naive ACC OFF/SLR ON at M256 and M33x2. [Original failing logs](results/final_naive_noacc_slr1/results.json) remain archived. Both cases now pass on final RTL, including M256 at 364.31s and M33x2 at 102.60s.
- Every final M256 first attempt hit 300s while compilation/simulation were progressing. All 6 passed their 1800s retry; actual retry duration was 257.27–364.31s. Earlier timeouts are retained in [the 48-attempt report](results/final2_summary.json) and do not override successful last attempts.
- Obsolete pre-fix long runs were stopped only through their owned process groups and [marked superseded](results/old_final_superseded.json), not regression failures.

## Improve QROW failures before reference correction

Both t0/d1 and t1/d1 fail numerically for improve SLR OFF/ON. The same 2 cases fail on the immutable baseline: 30/4096 mismatches, first `(m=0,n=35)` got `0x2500` (0.019531), expected `0x2519` (0.019913). All 10 emitted mismatch lines and total counts match across baseline, pre-fix, and final OFF/ON runs; SHA-256 is `224a63f273e4bbf2854fbf717a6dee7f029a44353b4e58188c9512c7018bb037`. The application emits only the first 10 failures, so the hash covers those diagnostics rather than every output element.

[Baseline/current comparison](results/qdir_comparison.json) and [baseline reproduction results](results/baseline_qdir_summary.json) retain the evidence. `FP16_TOL=0.01` and the relative-error comparison are unchanged; the sample error is approximately 1.916%. The user initially deferred this issue, then explicitly requested correcting the reference and retesting. The earlier deferral no longer determines acceptance.

## Execution and outcome

Runs used configured independent build directories, sourced captured configs, `/usr/bin/gcc`, `/usr/bin/g++`, `ci/run_black.sh xrt-vcs-sim --debug 1`, and `VCS_CPPFLAGS=-DDEBUG_LEVEL=1`. Final builds uniformly add the testbench-only `DISABLE_FSDB` switch. No simulator binary was shared between variants. No synthesis/PnR/hardware was run.

The active final2 invocation loaded an earlier runner revision and returned process code 0 despite the 4 raw case failures. The runner has since been corrected to aggregate last-attempt failures into a nonzero exit, reject stale source/config reuse, and check source hashes before/after runs. This final deterministic case audit returns **1**, and these historical results contain **38 PASS + 4 baseline-equivalent failures**. Reference-fix validation is recorded separately.
