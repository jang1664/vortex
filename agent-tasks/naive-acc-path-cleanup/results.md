# Internal ACC cleanup results

C3, K=N=256, q32, t0, d0, r1. One xrt-vcs-sim --perf 3 measurement per case.

| M | Historical RTL | Current before cleanup | Current after cleanup | After vs historical |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 5960 | 6225 | 5974 | +0.235% |
| 4 | 6115 | 6376 | 6129 | +0.229% |
| 256 | 44040 | 46272 | 44068 | +0.064% |

Main comparisons use internal ACC, Omega request/response, ordering disabled, SLR OFF, identical host/kernel SHA-256 across all revisions. Historical/before values are the earlier measurements, preserved in paper-vs-current-rtl and omega-ordering-macros.

## Regression checks

| Configuration | M | Status | Node cycles |
| --- | ---: | --- | ---: |
| acc_omega | 1 | PASS | 5974 |
| acc_omega | 4 | PASS | 6129 |
| acc_omega | 256 | PASS | 44068 |
| acc_stream | 4 | PASS | 4478 |
| acc_slr | 4 | PASS | 6226 |
| acc_guarded | 4 | PASS | 7783 |
| external | 4 | PASS | 8676 |

External PSUM uses current application/kernel sources; its cycle count is a regression diagnostic, not an apples-to-apples historical performance comparison. All other runs reuse the historical C3 host/kernel artifacts.

Implementation and limitations: analysis.md. Full configuration, raw counters, logs and hashes: summary.json.

All seven runs passed correctness and source/artifact integrity checks. External-PSUM MAC/output counters follow the existing ACC-output-based instrumentation and are not used for performance conclusions here.
