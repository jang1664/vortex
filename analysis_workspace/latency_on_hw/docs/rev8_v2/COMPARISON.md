# rev8 versus rev8_v2

B1, context 8192. Seconds per output token, averaged over 128 decode steps and all 32 layers. These are aggregated FPGA-cycle estimates, not measured whole-model wall times. The ordinary E2E plot excludes dequantization by the existing policy.

| Model | Candidate | Vector rev8 | Vector rev8_v2 | K transpose rev8 | K transpose rev8_v2 | E2E rev8 | E2E rev8_v2 | E2E change |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| llama2 | C1 | 196.818245 | 3.451176 | 193.771754 | 0.404684 | 206.533096 | 13.166027 | -93.63% |
| llama2 | C2 | 196.818245 | 3.451176 | 193.771754 | 0.404684 | 204.806244 | 11.439175 | -94.41% |
| llama2 | C3 | 3.046492 | 3.046492 | 0.000000 | 0.000000 | 10.638016 | 10.638016 | +0.00% |
| llama2 | C4 | 3.046492 | 3.046492 | 0.000000 | 0.000000 | 6.603428 | 6.603428 | +0.00% |
| llama3 | C1 | 49.687832 | 2.047708 | 47.741750 | 0.101626 | 56.949013 | 9.308889 | -83.65% |
| llama3 | C2 | 49.687832 | 2.047708 | 47.741750 | 0.101626 | 57.800367 | 10.160243 | -82.42% |
| llama3 | C3 | 1.946081 | 1.946081 | 0.000000 | 0.000000 | 9.994321 | 9.994321 | +0.00% |
| llama3 | C4 | 1.946081 | 1.946081 | 0.000000 | 0.000000 | 4.575117 | 4.575117 | +0.00% |

All GEMM components, all prefill totals, and C3/C4 totals were checked unchanged. See `comparison.json` for every workload.
