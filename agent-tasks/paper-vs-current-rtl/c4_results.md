# C4 M256: completed comparison

All nine runs passed. M=K=N=256, q32, t0, d0, r1, perf class 3.

| RTL | Node cycles (3 runs) | Median | Range | Compute median |
| --- | --- | ---: | --- | ---: |
| old | 24763, 24764, 24764 | 24764 | 24763–24764 | 19477 |
| off | 24763, 24764, 24762 | 24763 | 24762–24764 | 19477 |
| on | 25276, 25276, 25274 | 25276 | 25274–25276 | 19989 |

| Comparison | Delta | Change | Speedup |
| --- | ---: | ---: | ---: |
| old → off | -1 | -0.0040% | 1.0000× |
| off → on | +513 | +2.0716% | 0.9797× |
| old → on | +512 | +2.0675% | 0.9797× |

The old/OFF ranges overlap; the one-cycle median difference is not evidence of a performance change.
The ON range is separate, with approximately 2.07% more node cycles.
Same host/kernel SHA-256 across all variants. Baseline RTL: `391b45d39`; current: `18ab7f92b`.
This measures cycles in a shared simulator environment, not FPGA wall time or Fmax.
