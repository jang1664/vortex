# MXU SLR kernel verification results

**Reference correction retest: 18/18 PASS, runner exit 0. No deferred failures remain.** Latest applicable evidence covers 42/42 cases: 18 reruns after the host correction plus 24 earlier QCOL cases whose reference expressions are unchanged. All 42 were not rerun after the host-only change.

| Variant | PASS | M16/t0/d1 | M16/t1/d1 | M16/t0/d0 control |
|---|---:|---|---|---|
| [naive_acc_slr0](results/qrow_reference_naive_acc_slr0/metadata.json) | 3/3 | [PASS](results/qrow_reference_naive_acc_slr0/m16_t0_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_naive_acc_slr0/m16_t1_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_naive_acc_slr0/m16_t0_d0_r1.attempt1.app.log) |
| [naive_acc_slr1](results/qrow_reference_naive_acc_slr1/metadata.json) | 3/3 | [PASS](results/qrow_reference_naive_acc_slr1/m16_t0_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_naive_acc_slr1/m16_t1_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_naive_acc_slr1/m16_t0_d0_r1.attempt1.app.log) |
| [naive_noacc_slr0](results/qrow_reference_naive_noacc_slr0/metadata.json) | 3/3 | [PASS](results/qrow_reference_naive_noacc_slr0/m16_t0_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_naive_noacc_slr0/m16_t1_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_naive_noacc_slr0/m16_t0_d0_r1.attempt1.app.log) |
| [naive_noacc_slr1](results/qrow_reference_naive_noacc_slr1/metadata.json) | 3/3 | [PASS](results/qrow_reference_naive_noacc_slr1/m16_t0_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_naive_noacc_slr1/m16_t1_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_naive_noacc_slr1/m16_t0_d0_r1.attempt1.app.log) |
| [improve_slr0](results/qrow_reference_improve_slr0/metadata.json) | 3/3 | [PASS](results/qrow_reference_improve_slr0/m16_t0_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_improve_slr0/m16_t1_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_improve_slr0/m16_t0_d0_r1.attempt1.app.log) |
| [improve_slr1](results/qrow_reference_improve_slr1/metadata.json) | 3/3 | [PASS](results/qrow_reference_improve_slr1/m16_t0_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_improve_slr1/m16_t1_d1_r1.attempt1.app.log) | [PASS](results/qrow_reference_improve_slr1/m16_t0_d0_r1.attempt1.app.log) |

All runs use K=N=256, q32, r1 and `ci/run_black.sh xrt-vcs-sim --debug 1`. Host apps were explicitly rebuilt with `/usr/bin/g++`. Configured final2 simulator builds were reused after matching RTL/config fingerprints; each simulator binary hash remained unchanged. RTL and both host source hashes were checked before and after every rerun.

Current RTL SHA-256: `55a40a71e8e434a7e0973d57c1895d7dec07b7728645b25487b1ee9e495dfb90`. All 6 RTL hashes, both host hashes, commands, configurations, application/simulator logs, and per-case provenance are recorded in [summary.yaml](summary.yaml).

The QROW reference now rounds `a*scale` to FP16 before multiplying `(w-zp)`. QCOL expressions and `FP16_TOL=0.01` are unchanged. Both formerly failing improve QROW layouts now pass with SLR OFF/ON.

[Historical verification](pre_reference_results.md) preserves 3 baseline PASS results, the 2 baseline QROW reproductions, the initial 38 PASS + 4 FAIL matrix, the resolved SLR PSUM-underflow regression, and successful M256 timeout retries. Historical failures remain archived; their earlier deferral was superseded by the user-requested reference fix.

No synthesis, PnR, or FPGA hardware run was performed.
