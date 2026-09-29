# M1/M4 old/current comparison: unguarded Omega

K=N=256, q32, t0, d0, r1; xrt-vcs-sim --perf 3; SLR OFF. One run per configuration.
C3 uses internal ACC. Request and response Omega are enabled; both ordering guards are absent.
C3 historical commit: 93f4ae97d. C4 historical commit: 391b45d39 plus ordering-selector-only backport.
Current base: 18ab7f92 plus the same new ordering controls.

| Backend | M | Old node cycles | Current node cycles | Change | Correctness |
| --- | ---: | ---: | ---: | ---: | --- |
| C3 | 1 | 5960 | 6225 | +4.446% | both PASS |
| C3 | 4 | 6115 | 6376 | +4.268% | both PASS |
| C4 | 1 | 3101 | 3101 | +0.000% | both PASS |
| C4 | 4 | 3307 | 3307 | +0.000% | both PASS |

Each backend reuses its identical host/kernel binaries from the M256 comparison.
These are single-sample RTL cycle measurements, not FPGA Fmax/wall-clock measurements.
C4 originally used stream xbar in the paper configuration; this experiment explicitly selects Omega on both revisions.
No additional product RTL edits. Raw counters, command lines, source/config/artifact hashes: summary.json and logs/.
