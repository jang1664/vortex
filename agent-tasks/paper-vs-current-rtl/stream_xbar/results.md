# C3 M256 stream xbar comparison

M=K=N=256, q32, t0, d0, r1; `xrt-vcs-sim --perf 3`. One valid run per variant.
Only request/response Omega defines were removed from the matched historical configuration.
Internal ACC remains enabled; host/kernel binaries are identical to the Omega comparison.

| RTL | Stream node cycles | Compute cycles | Omega node cycles | Stream vs Omega |
| --- | ---: | ---: | ---: | ---: |
| old | 37588 | 21592 | 44040 | -14.650% |
| off | 38602 | 22565 | 123944 | -68.855% |
| on | 39111 | 23074 | — | unavailable |

| Stream xbar comparison | Cycle delta | Change |
| --- | ---: | ---: |
| C3_old → C3_off | +1014 | +2.698% |
| C3_off → C3_on | +509 | +1.319% |
| C3_old → C3_on | +1523 | +4.052% |

All runs passed correctness and artifact/source hash checks. Single samples do not measure run-to-run variability.
This compares RTL cycles, not FPGA Fmax or wall-clock hardware latency.
Removing both Omega defines changes request and response fabrics together; it does not isolate individual ordering mechanisms.
Product RTL and repository configs were not edited. Generated configs/builds are isolated under build_paper_vs_current_sources.
