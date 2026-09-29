# Directed MXU SLR verification results

Completed: 2026-09-29 19:12
Base commit: `73664e653b20cb0b0497d8627fa9c20cea786f8e`

Commit preparation only removed a trailing blank line from the unittest
Makefile and changed the runner to use the captured configuration files.
Both captured CONFIGS values were checked against the original inputs and
matched exactly; the runner passed Python syntax validation. The historical
Makefile hash identifies the tested version before that whitespace cleanup.
RTL, testbench, and VCS command helper remained unchanged.

All eight configured VCS variants passed using the same final RTL, TB, and build-helper hashes. Each checked 108 complete MXU vectors exactly at the FP32 scaler output. Their ordered result streams are bit-identical. No numerical tolerance was used.

| Variant | Result | Vectors | MXU latency | Weight rows/beat |
|---|---|---:|---:|---:|
| improve-off | PASS | 108 | 5 | 4 |
| improve-on | PASS | 108 | 9 | 4 |
| improve-wload-off | PASS | 108 | 5 | 32 |
| improve-wload-on | PASS | 108 | 9 | 32 |
| naive-acc-off | PASS | 108 | 5 | 4 |
| naive-acc-on | PASS | 108 | 9 | 4 |
| naive-lmem-off | PASS | 108 | 5 | 4 |
| naive-lmem-on | PASS | 108 | 9 | 4 |

The naive external-PSUM / SLR-ON run additionally passed four 96-row accumulation commands (384 vectors), covering both base-bank parities, QCOL/QROW, continuous/bubbled input, variable delayed responses and request stalls. All FP32 PSUM writes matched an independent arithmetic reference exactly; DUT burst/reservation assertions stayed enabled.

Coverage includes immediate first use after the final weight beat; inactive-bank writes during compute; asymmetric row/column loads; changing vector maximum exponent, scale and nonzero correction; reset during weight/input/result transport; post-reset recovery; exact +4 MXU flight latency; correction and exponent valid alignment.

Reproduce: `python3 hw/unittest/mxu_slr/run_tests.py`. Configured build directories are `build-mxu-directed-*`; each contains source/resolved config snapshots, configure/compile/simulation logs, and its verification-driver result. Full commands and source SHA-256 are recorded in `directed-results.json`. The simulator arithmetic wrappers use FPNEW. Xilinx-IP and full-kernel behavior are verified separately by the parent kernel regression.

## Resolved test-harness issues

- Initial stimulus varied lane exponents but held vector maximum exponent constant. The final stimulus varies the maximum across vectors and requires at least three distinct observed maxima. Preliminary per-variant logs are retained in `directed-preliminary`; its mixed-stimulus stream comparison was intentionally not accepted.
- The first asynchronous PSUM target allowed different read sets outstanding together, causing the existing eight-request burst assertion. The real `VX_gemm_node_naive` bridge blocks a read-set change until outstanding responses drain. The final target models that behavior explicitly, with no arbitrary outstanding-depth cap. Original failure: `psum-stress-missing-set-serialization.log`. This was a harness contract mismatch, not evidence of a reservation regression.
- Local header include paths exposed that configure alone does not generate `hw/VX_config.h`. The final unittest setup runs the configured build's `hw config` target and uses that build's headers. A testbench declaration-order compile error was also corrected before final acceptance.

## Limits

Load equivalence checks the scaler boundary. The additional stress checks external PSUM accumulation writes; ACC copy/STORE drain, final kernel outputs and physical SLR placement remain parent verification responsibilities. No simulation failure remains in this directed suite.
