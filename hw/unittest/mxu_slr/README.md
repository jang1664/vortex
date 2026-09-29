# MXU SLR directed VCS regression

Run from the source tree:

```sh
python3 hw/unittest/mxu_slr/run_tests.py
```

The runner sources the captured naive and improve configurations under
`agent-tasks/mxu-slr-port/verification/configs`, configures a separate build
directory per variant, and invokes
`tools/verify_rtl.py` with VCS and the system GCC/G++ compilers. No simulator is
shared across variants. FP arithmetic uses the existing FPNEW unit-test model;
Xilinx-IP arithmetic is covered separately by the xrt-vcs-sim kernel regression.
Use `--variants improve-off improve-on` to select a subset and `--report PATH`
to choose the structured result file.

The test instantiates the actual `VX_gemm_unit` and checks 108 output vectors
bit-for-bit at its FP32 scaler boundary using small dyadic operands and an
independent arithmetic reference. Coverage includes QCOL/QROW zero-point and
scale correction, changing signs/exponents, asymmetric row/column weight
loading, immediate start after the last weight beat, both weight banks,
inactive-bank writes during compute, consecutive inputs, bubbles, reset during
weight/input/result transport, and successful post-reset computation. It asserts
correction and exponent valid alignment and MXU latency from prealigner valid
to locally captured result: five cycles OFF and nine cycles ON for MXU32.
Reset-aborted vectors must not produce stale results after reset.

The naive-LMEM/SLR-ON binary additionally runs `+PSUM_STRESS`: four 96-row
accumulate commands covering both base parities and QCOL/QROW, with continuous
and bubbled inputs. The behavioral target preserves tags, returns a beat after
7 or 43 cycles with occasional additional 53-cycle delay, stalls requests,
and serializes read sets exactly as the bridge in `VX_gemm_node_naive` does.
An independent reference checks all 384 FP32 accumulated writes exactly. No
arbitrary target depth limit is used; the DUT burst and reservation assertions
remain enabled. This test specifically exercises PSUM admission with more
rows than the FIFO depth and uneven response timing.

The eight variants cover SLR OFF/ON for improve with WLOAD_AT_ONCE OFF/ON,
naive internal ACC, and naive external PSUM. Their exact result streams must
match. The naive variants exercise load-mode computation with always-ready
PSUM/final write sinks; the main equivalence suite does not model external PSUM
reads. The separate PSUM stress models those reads and accumulation; ACC
copy/STORE and full-kernel behavior require the kernel regression. Naive uses
four weight rows per beat independently of WLOAD_AT_ONCE, so full-tile weight
loading is tested with improve.

Build logs, simulator logs, resolved configurations, and original config copies
remain under `build-mxu-directed-*`. The JSON report records source SHA-256,
commands, pass/fail, vector count, latency, and result-stream SHA-256. Failures
exit nonzero; the runner does not relax numerical tolerances or clear logs.
