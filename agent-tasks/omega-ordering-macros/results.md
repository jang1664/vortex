# Omega ordering macro validation

Historical/current `VX_stream_omega.sv` is identical. The two new controls select ordering around it in `VX_local_mem.sv`.

- Default ordering is retained.
- All 16 fabric/disable presence combinations passed preprocessing guard/fabric checks.
- All nine distinct fabric/ordering modes passed local_mem_top via tools/verify_rtl.py.
- C3 M256, internal ACC, SLR OFF, both guards disabled: xrt-vcs-sim correctness and source/artifact checks passed.

| Current C3 SLR OFF | Node cycles |
| --- | ---: |
| Omega, default ordering (previous baseline) | 123944 |
| Omega, both ordering guards disabled (new macros) | 46272 |
| Stream xbar (previous experiment) | 38602 |

Guard bypass reduces cycles by 62.667% versus the previous default-Omega measurement.
Historical unguarded Omega measured 44040 cycles; current bypass is +5.068% relative to it. Other current LMEM/GEMM changes remain.

Single measurements, identical host/kernel binaries and hardware settings except the described selectors. Individual request/response guard costs were not separately measured in M256. The new default path was covered by unit tests; the quoted default-Omega and stream-xbar blackbox numbers are prior measurements, not fresh post-edit blackbox runs.

The initial unit invocation unnecessarily enabled GEMM_NAIVE_USE_ACC_MEM on a generic wrapper with an existing missing commit-output connection. That test setup was corrected to the ordinary LMEM unit configuration; ACC is verified in the blackbox. No product fix was needed for that wrapper-only warning.
