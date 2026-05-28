# TCOLUMN=1 vs TCOLUMN=32 GEMM Latency Analysis

Source data:

- Notebook: `analysis_workspace/latency/cycle_analysis.ipynb`
- CSV directory: `analysis_workspace/latency/fpint_improve_m1_k128_n64_tcol_compare`
- Traces:
  - `fpint_improve_m1_k128_n64_tcol1`
  - `fpint_improve_m1_k128_n64_tcol32`

## Summary

`tcol32` improves the compute-facing part of the kernel, but the end-to-end
gain is limited by fixed GEMM overhead, unchanged DMA/HBM activity, and runtime
overhead outside the user kernel body.

The important split is:

| Metric | tcol1 | tcol32 | Delta | Speedup |
|---|---:|---:|---:|---:|
| `kernel_busy` | 14518 | 12498 | 2020 | 1.16x |
| `user_kernel_body` | 6708 | 4688 | 2020 | 1.43x |
| `gemm_total` | 4822 | 2838 | 1984 | 1.70x |
| `gemm_compute` | 3384 | 1400 | 1984 | 2.42x |
| `gemm_stall` | 64 | 64 | 0 | 1.00x |
| `gemm_total - compute - stall` | 1374 | 1374 | 0 | 1.00x |
| `user_kernel_body - gemm_total` | 1886 | 1850 | 36 | 1.02x |

So the local optimization is real: `gemm_compute` drops by 1984 cycles. But
almost all other user-body cost stays constant. That is why the `user_kernel_body`
speedup is only 1.43x, not 2x.

## What Improved

### G0/G1 wait cycles

The sync wait reduction is concentrated in `G0` and `G1`.

| Sync reg | tcol1 | tcol32 | Delta | Reduction |
|---|---:|---:|---:|---:|
| `G0` | 1848 | 856 | 992 | 53.7% |
| `G1` | 1856 | 864 | 992 | 53.4% |
| `G0 + G1` | 3704 | 1720 | 1984 | 53.6% |
| `O` | 269 | 269 | 0 | 0.0% |
| `W0` | 105 | 105 | 0 | 0.0% |
| `SZ0` | 55 | 55 | 0 | 0.0% |
| `W1` | 32 | 32 | 0 | 0.0% |
| `SZ1` | 32 | 32 | 0 | 0.0% |

The `G0 + G1` reduction is exactly 1984 cycles, which matches the
`gemm_compute` reduction:

```text
gemm_compute: 3384 -> 1400, delta = 1984
G0 + G1 wait: 3704 -> 1720, delta = 1984
```

This strongly suggests that `tcol32` mainly reduces the compute-side spacing
between GEMM group operations, not the memory movement or output path.

### MXU fire utilization

The number of MXU fire events does not change, but the compute window gets
shorter, so utilization improves.

| Metric | tcol1 | tcol32 |
|---|---:|---:|
| `input_fire` | 64 | 64 |
| `weight_fire` | 512 | 512 |
| `psum_fire` | 56 | 56 |
| `output_fire` | 8 | 8 |
| `mxu_input_util_pct_compute` | 1.89% | 4.57% |
| `mxu_weight_util_pct_compute` | 15.13% | 36.57% |
| `mxu_output_util_pct_compute` | 0.24% | 0.57% |

The interval analysis shows the same trend:

| Metric | tcol1 | tcol32 | Direction |
|---|---:|---:|---|
| `mxu_input_p50` | 67 | 36 | better |
| `mxu_weight_p90` | 59 | 28 | better |
| `mxu_psum_p90` | 133 | 71 | better |
| `mxu_output_p90` | 917.2 | 520.4 | better |

So `tcol32` does improve compute feeding cadence and utilization.

## What Did Not Improve

### DMA/HBM traffic and active cycles are unchanged

HBM and LDMA activity is effectively identical.

| Metric | tcol1 | tcol32 |
|---|---:|---:|
| `hbm_rd_bytes` | 41984 | 41984 |
| `hbm_wr_bytes` | 512 | 512 |
| `hbm_active` | 2539 | 2544 |
| `ldma_input_active` | 640 | 640 |
| `ldma_weight_active` | 1089 | 1089 |
| `ldma_sz_active` | 1280 | 1280 |
| `ldma_output_active` | 80 | 80 |

HBM read latency also stays the same:

| Metric | tcol1 | tcol32 |
|---|---:|---:|
| `hbm_read_req_count` | 656 | 656 |
| `hbm_read_rsp_count` | 656 | 656 |
| `hbm_read_p50_latency` | 3 | 3 |
| `hbm_read_p90_latency` | 3 | 3 |
| `hbm_read_max_latency` | 5 | 6 |

This means `tcol32` does not reduce the amount of memory work, HBM service
latency, or LDMA active time. As the compute side gets shorter, these fixed
memory costs become a larger fraction of the user body.

### GEMM fixed non-compute cycles are unchanged

Inside `gemm_total`, the non-compute portion is constant:

```text
tcol1:  gemm_total - gemm_compute - gemm_stall = 4822 - 3384 - 64 = 1374
tcol32: gemm_total - gemm_compute - gemm_stall = 2838 - 1400 - 64 = 1374
```

This 1374-cycle block is not affected by `tcol32`.

### Work outside GEMM total is also unchanged

The user kernel body has a large portion that is not counted as `gemm_total`:

```text
tcol1:  user_kernel_body - gemm_total = 6708 - 4822 = 1886
tcol32: user_kernel_body - gemm_total = 4688 - 2838 = 1850
```

This part only improves by 36 cycles. It likely includes software/control flow,
command issue, wait/notify overhead not captured in `gemm_total`, and local
memory/output bookkeeping.

### Runtime phases outside the user body are fixed

If the measured performance includes the full `kernel_busy` window, the speedup
is only 1.16x because the runtime phases are unchanged:

| Phase | tcol1 | tcol32 |
|---|---:|---:|
| `runtime_bootstrap_to_user` | 4588 | 4588 |
| `tag_init` | 2048 | 2048 |
| `warp_spawn` | 266 | 266 |
| `runtime_exit` | 538 | 538 |
| `perf_dump` | 547 | 547 |
| `fence_wait` | 2078 | 2078 |
| `cache_flush_data` | 2048 | 2048 |
| `cache_flush_tags` | 2048 | 2048 |

These phases hide most of the user-body improvement in whole-kernel timing.

## Why the Final Speedup Is Less Than 2x

For `user_kernel_body`, the useful mental model is:

```text
tcol1  user_kernel_body = compute 3384 + non_compute 3324 = 6708
tcol32 user_kernel_body = compute 1400 + non_compute 3288 = 4688
```

`tcol32` reduces the compute portion by 1984 cycles, but the non-compute portion
is still about 3.3k cycles. The observed speedup is therefore:

```text
6708 / 4688 = 1.43x
```

To reach 2x on `user_kernel_body`, the tcol32 body would need to be at most:

```text
6708 / 2 = 3354 cycles
```

The current non-compute floor alone is already about:

```text
3288 cycles
```

That leaves only about 66 cycles for compute if the target is 2x. Since the
current `tcol32` compute portion is still 1400 cycles, a 2x end-to-end user-body
speedup is not realistic from this optimization alone.

If the full `kernel_busy` window is the benchmark target, the fixed runtime
overhead makes the limit even tighter:

```text
14518 / 12498 = 1.16x
```

## Interpretation

`tcol32` improves MXU feeding and reduces G0/G1-related compute spacing, but it
does not address:

- HBM read/write byte count.
- HBM active cycles.
- HBM read latency.
- LDMA input/weight/SZ/output active cycles.
- GEMM non-compute overhead.
- Runtime bootstrap, tag init, fence, and cache flush phases.

Therefore, the optimization shifts the bottleneck from compute cadence toward
fixed memory/control/runtime overhead. The result is a real local improvement,
but only a 1.43x `user_kernel_body` speedup and a 1.16x full `kernel_busy`
speedup.

## Bottleneck Classification

The notebook now writes:

```text
analysis_workspace/latency/fpint_improve_m1_k128_n64_tcol_compare/fpint_improve_bottleneck_summary.csv
```

Current classification:

| Trace | Bottleneck | Memory pressure | Pure memory-bound |
|---|---|---:|---:|
| `fpint_improve_m1_k128_n64_tcol1` | `compute_fixed_mixed_bound` | false | false |
| `fpint_improve_m1_k128_n64_tcol32` | `fixed_control_memory_overlap_bound` | true | false |

So the answer is not "pure memory-bound". For `tcol32`, memory activity is high
enough to be on the critical path, but the largest limiter is the combined
fixed/control region:

```text
tcol32 compute_user_pct        = 29.9%
tcol32 fixed_control_user_pct  = 68.8%
tcol32 memory_active_user_pct  = 54.3%
```

This is better described as fixed/control plus memory-overlap bound. In other
words, DMA/HBM/LDMA work is not being hidden well enough anymore, but raw HBM
latency or bandwidth alone is not the only bottleneck.

## Next Optimization Targets

To get closer to 2x final speedup, the next work should target the fixed parts:

1. Reduce or overlap GEMM non-compute overhead.
   - The unchanged 1374-cycle block inside `gemm_total` is now a dominant cost.
   - This likely needs command scheduling, sync, and DMA/control overlap work.

2. Reduce user-body work outside `gemm_total`.
   - The approximately 1850-cycle block outside `gemm_total` barely changed.
   - Track what contributes to this region: command issue, waits outside MXU,
     output handling, and software-side instruction overhead.

3. Overlap or shorten LDMA/HBM activity.
   - HBM active cycles and LDMA active cycles are unchanged.
   - Better compute feeding alone cannot reduce these memory-bound cycles.

4. Separate benchmark reporting into user-only and full-runtime metrics.
   - `user_kernel_body` shows the hardware optimization more clearly.
   - `kernel_busy` includes fixed runtime/cache/fence costs and will understate
     the hardware-local improvement.
