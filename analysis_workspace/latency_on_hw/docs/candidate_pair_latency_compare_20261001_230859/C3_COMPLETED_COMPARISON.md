# Completed C3 cycle comparison

The old and corrected v2 C3 configs now both pass the CPU reference check.
The v2 config enables `DMA_SPLIT_RSP_REORDER=1` to correctly reassemble
out-of-order cache-lane responses. A naive-only `VX_STATIC_ASSERT` in
`VX_mem_unit.sv` now requires this option when `DMA_DCACHE_PORTS > 1`;
ports=1 remains valid without it.

The repository's assertion macro reports an error at simulation time zero.
It is not a VCS compile-time rejection, and expands to nothing for synthesis.
An actual full-RTL invalid-config VCS run printed the expected error at time
zero. The standalone run was supervised because its DPI server waits for a
client; this check uses the error message, not process exit status, as evidence.

Fresh old/v2 runs use the same source snapshot after adding the assertion,
independent configured builds, and `ci/run_black.sh xrt-vcs-sim`, without
observational trace defines.

- Old config: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr.sh`.
- Fixed v2: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh`.
- App: `fpint_gemm_ffn_hw_naive`.
- Shape: M=128, N=256, K=256, QBLK=32, QDIR=0, REPS=1.

| Weight layout | Old cycles | Corrected v2 cycles | Delta (v2-old) | Change | Speedup | Verification |
|---|---:|---:|---:|---:|---:|---|
| `-t 0` | 47,981 | 47,446 | -535 | -1.115% | 1.0113× | PASS/PASS |
| `-t 1` | 48,206 | 47,671 | -535 | -1.110% | 1.0112× | PASS/PASS |

These are full-kernel core cycles including DMA and job polling, from one
cold launch per case. The result measures the entire config change, including
cache banks, DMA ports, LMEM capacity and HBM connectivity.

All four C3 runs have identical kernel SHA-256:
`e02e64ff8a4e42ca33c0fe4d43dba867ee7e03c803c2c6206dc038715fd62ed2`.

| Config / workload | Instructions | Log |
|---|---:|---|
| C3_old / gemm | 9,617 | [run.log](../../../../agent-tasks/c3-static-assert-cycle-compare-20261001_235906/C3_old/gemm/run.log) |
| C3_old / gemm_wtrans1 | 9,635 | [run.log](../../../../agent-tasks/c3-static-assert-cycle-compare-20261001_235906/C3_old/gemm_wtrans1/run.log) |
| C3_v2_fixed / gemm | 9,575 | [run.log](../../../../agent-tasks/c3-static-assert-cycle-compare-20261001_235906/C3_v2_fixed/gemm/run.log) |
| C3_v2_fixed / gemm_wtrans1 | 9,593 | [run.log](../../../../agent-tasks/c3-static-assert-cycle-compare-20261001_235906/C3_v2_fixed/gemm_wtrans1/run.log) |

## Improve preservation

The assertion is guarded by `GEMM_NAIVE`. Before/after preprocessing of
`VX_mem_unit.sv` with the C4 improve config produces identical selected RTL
after removing empty lines. Interfaces, storage and ready/valid behavior
are unchanged. The same improve case passes at 46,848 cycles and 9,523
instructions, matching the earlier result: zero measured core-cycle delta.
No improve synthesis was run.

## Evidence

Artifact directory: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c3-static-assert-cycle-compare-20261001_235906`.

Commands, config copies, compile and simulation logs, model manifests,
result JSON, source hashes and improve preprocessing outputs are preserved.
The direct negative-test build initially lacked generated `VX_config.h`;
`make -C hw config` resolved the prerequisite before checking the assertion.

Original failing v2 logs and `results.json` remain historical evidence.
`comparison.csv` and the primary `SUMMARY.md` table now use the passing
C3 rerun. Its raw records are in `completed_c3_results.json`. The separate
[C3 root-cause report](../c3_dma_ports2_root_cause_20261001.md) explains the
data corruption and minimal config correction.
