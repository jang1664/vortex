# N-fast waveform comparison

The requested traversal change is active, but its measured cycle effect is small: M4 saves 16 GEMM cycles (0.2481%), M256 saves one (0.0004%), and both whole-kernel core-cycle counts are unchanged. These measurements do not show a substantial performance benefit from microtile traversal order alone.

`check_wave.py` uses `fsdb_cli.report` on the retained K-fast captures and fresh N-fast captures. It samples strictly before rising edges, checks every accepted Input ARM coordinate and consecutive per-tile work identifier, and checks total accepted Input rows. All four captures satisfy the expected traversal and counts.

At each 128x128 macro N/K tile, the accepted `(N,K)` sequence changes from `(0,0),(0,1),...,(0,7),(1,0),...` to `(0,0),(1,0),...,(7,0),(0,1),...`. M4 has 1,024 ARM commands and 4,096 Input handshakes; M256 has 2,048 commands and 262,144 handshakes in either order. TMEM layout and per-output K accumulation order are unchanged.

| Observation | M4 K-fast | M4 N-fast | M256 K-fast | M256 N-fast |
|---|---:|---:|---:|---:|
| GEMM cycles | 6,449 | 6,433 | 272,870 | 272,869 |
| Input valid, ready low | 31 | 26 | 0 | 0 |
| Input absent, ready high | 1,538 | 1,526 | 41 | 41 |
| Compute operand waiting for weight | 335 | 387 | 1 | 1 |

The stall observations overlap across pipeline stages; they must not be summed to explain total cycles. In particular, M4's weight-wait count increases despite a small overall cycle decrease, so this result is not evidence of improved weight bandwidth.

M256's accepted Input gap histogram changes only one gap from three cycles to two. Both runs have 262,135 one-cycle gaps and seven 1,172-cycle gaps. Thus the traced Input delivery pattern is almost identical, consistent with the one-cycle total difference. M4 retains three 144-cycle Input gaps, while its short-gap distribution changes slightly.

Generated checks are in `runs/baseline-m4-wave.json`, `runs/baseline-m256-wave.json`, `runs/nfast-m4-wave.json`, and `runs/nfast-m256-wave.json`. Capture provenance is described in `baseline.md`; reproduction and numerical acceptance are in `results.md`. Current cycles and the historical K-fast comparison are published in `docs/hw_analysis/improve_vs_naive/fpint_gemm_latency.md`.
