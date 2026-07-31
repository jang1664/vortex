# Input-copy power validation

Date: 2026-07-31

The XRT runtime used for these measurements was `runtime/xrt/vortex_v6.cpp`.
Each run used separate power measurement with a roughly 10-second kernel
window on C4_v3. Copy and skip measurements used the same application shape.

## Results

| Case | Mode | Idle avg (W) | Run avg (W) | Dynamic avg (W) | Dynamic stderr (W) |
|---|---|---:|---:|---:|---:|
| softmax batch64, run 1 | copy | 35.599 | 37.114 | 1.515 | 0.045 |
| softmax batch64, run 1 | skip | 35.561 | 36.824 | 1.262 | 0.038 |
| softmax batch64, run 2 | copy | 35.707 | 37.055 | 1.347 | 0.047 |
| softmax batch64, run 2 | skip | 35.776 | 37.119 | 1.343 | 0.036 |
| GEMM decode | copy | 35.762 | 36.839 | 1.077 | 0.029 |
| GEMM decode | skip | 35.641 | 36.745 | 1.104 | 0.042 |
| KV quant decode | copy | 35.545 | 37.599 | 2.054 | 0.055 |
| KV quant decode | skip | 35.608 | 37.435 | 1.826 | 0.059 |

Skip relative to copy:

| Case | Run average difference | Dynamic average difference |
|---|---:|---:|
| softmax batch64, run 1 | -0.782% | -16.660% |
| softmax batch64, run 2 | +0.175% | -0.320% |
| GEMM decode | -0.256% | +2.447% |
| KV quant decode | -0.436% | -11.071% |

## Interpretation

- Total board run power is stable: all observed copy/skip differences are
  below 0.8%.
- Idle-subtracted dynamic power is not yet stable enough to call copy and
  skip equivalent. It ranges from a 16.7% decrease to a 2.4% increase.
- Softmax copy itself changed from 1.515 W to 1.347 W across two runs
  (about 11%), showing that baseline drift is large relative to the small
  1--2 W dynamic signal.
- Input contents may also change switching activity in skip mode because
  newly allocated device input memory is undefined.

For latency-only measurement, opt-in input-copy skip is supported by the
FPGA-cycle validation. Input copy remains the default, including for power
results, until more repeated/interleaved samples establish a tighter bound
for dynamic power.

Raw sampler CSV and one-row summary CSV files are stored in
`analysis_workspace/latency_on_hw/input_copy_power_validation/`.
