# Latency-on-HW Results

## Why C1-to-C4 generation improvement grows with sequence length

Source data:

- Total latency: `outputs/figures_notebook/plot_data.csv`
- Kernel stack latency: `outputs/figures_notebook/plot_stack_data.csv`
- Metric: `p50_us`, converted to seconds below
- C1: `all_sgemm_tcu_spinquant`
- C4 fused: `all_fpint_gemm_improve_fused_layout_spinquant`

For generation, the decode token length is one token. The sequence lengths below are the generation KV-cache lengths (`512` through `131072`), not the aggregate `seq_len=1` rows.

## Total latency

C4 is already faster at short KV lengths, but the absolute saved time becomes much larger at long KV lengths because the attention kernels scale with the cache length.

| Batch | KV length | C1 total (s) | C4 fused total (s) | Saved (s) | Speedup |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 512 | 96.244 | 25.227 | 71.018 | 3.82x |
| 1 | 2048 | 94.983 | 24.450 | 70.533 | 3.88x |
| 1 | 8192 | 106.421 | 28.898 | 77.523 | 3.68x |
| 1 | 32768 | 151.618 | 45.116 | 106.501 | 3.36x |
| 1 | 131072 | 866.415 | 103.031 | 763.383 | 8.41x |
| 8 | 512 | 201.341 | 166.031 | 35.311 | 1.21x |
| 8 | 2048 | 191.135 | 173.327 | 17.808 | 1.10x |
| 8 | 8192 | 282.624 | 195.585 | 87.039 | 1.45x |
| 8 | 32768 | 643.969 | 325.121 | 318.848 | 1.98x |
| 8 | 131072 | 6362.568 | 790.752 | 5571.816 | 8.05x |
| 64 | 512 | 1315.786 | 1296.638 | 19.148 | 1.01x |
| 64 | 2048 | 1234.146 | 1354.689 | -120.543 | 0.91x |
| 64 | 8192 | 1965.897 | 1534.819 | 431.078 | 1.28x |
| 64 | 32768 | 4857.307 | 2569.795 | 2287.511 | 1.89x |
| 64 | 131072 | 50605.758 | 2505.813 | 48099.945 | 20.20x |

The batch-1 speedup is not perfectly monotonic at the midpoints, but the long-context behavior is clear: C1 grows from `96.244s` at KV length 512 to `866.415s` at KV length 131072, while C4 grows only from `25.227s` to `103.031s`. The saved time therefore expands from `71.018s` to `763.383s`.

## Kernel-level reason

The projection GEMM improvement is large but mostly fixed across generation KV length, because generation still projects one new token. At batch 1, these kernels save about `76.394s` in total at every KV length:

| Kernel | C1 (s) | C4 fused (s) | Saved (s) | Speedup |
| --- | ---: | ---: | ---: | ---: |
| `q_proj` | 6.794 | 0.323 | 6.472 | 21.07x |
| `k_proj` | 6.794 | 0.323 | 6.472 | 21.07x |
| `v_proj` | 6.794 | 0.323 | 6.472 | 21.07x |
| `o_proj` | 6.794 | 0.323 | 6.472 | 21.07x |
| `gate_proj` | 18.038 | 0.829 | 17.209 | 21.76x |
| `up_proj` | 18.038 | 0.829 | 17.209 | 21.76x |
| `down_proj` | 16.917 | 0.829 | 16.089 | 20.42x |

That fixed projection saving explains why C4 is faster even at short KV lengths. It does not explain why the C1-to-C4 gap becomes much larger at long KV lengths.

The growing part comes from the attention GEMMs. At batch 1, `attn_qkT` and `attn_pv` save only `3.250s` together at KV length 512, but save `719.895s` together at KV length 131072:

| KV length | `attn_qkT` C1 -> C4 (s) | `attn_qkT` saved (s) | `attn_pv` C1 -> C4 (s) | `attn_pv` saved (s) | Combined saved (s) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 512 | 3.835 -> 1.666 | 2.168 | 2.747 -> 1.665 | 1.082 | 3.250 |
| 131072 | 513.190 -> 12.492 | 500.697 | 229.662 -> 10.463 | 219.198 | 719.895 |

The 131072 case is the clearest numerical example: `attn_qkT` improves from `513.190s` to `12.492s`, and `attn_pv` improves from `229.662s` to `10.463s`. Those two attention kernels alone save `719.895s`, which is much larger than the fixed projection saving.

## Overheads that C4 has to overcome

C4 also has layout/quantization and softmax overheads. At batch 1, KV length 131072:

| Kernel | C1 (s) | C4 fused (s) | Delta (s) |
| --- | ---: | ---: | ---: |
| `attn_softmax` | 34.461 | 58.976 | -24.515 |
| `kv_cache_quant_rope_k_to_attn_qkT` | 3.844 | 6.025 | -2.182 |
| `kv_cache_quant_v_cache_to_attn_pv` | 3.842 | 7.072 | -3.230 |
| `layout_rope_q_to_attn_qkT` | 0.000 | 1.675 | -1.675 |

These four items cost C4 about `31.601s` relative to C1 at KV length 131072. That overhead matters at short sequence lengths and high batch sizes. For example, batch 64 at KV length 2048 is a regression: C1 is `1234.146s`, C4 is `1354.689s`, so C4 is `120.543s` slower (`0.91x`).

At long KV length, the attention GEMM savings dominate those overheads. For batch 1 at KV length 131072, the two attention GEMMs save `719.895s`, while the listed overheads cost `31.601s`. That is why the total speedup jumps to `8.41x`. For batch 64 at the same KV length, the same scaling effect is stronger in absolute terms: total latency changes from `50605.758s` to `2505.813s`, saving `48099.945s` and reaching `20.20x`.

## Conclusion

C4 improves short generation latency mostly through fixed one-token projection GEMM speedups. As generation KV length increases, the dominant C1 cost moves to attention over the cache. C4's improved attention GEMM path keeps `attn_qkT` and `attn_pv` much smaller at long KV lengths, so the C1-to-C4 improvement gets better once those attention savings outweigh the C4 layout, quantization, and softmax overheads.

# Why does llama3 show a flat C1 vs C4 ratio with sequence length?

This section uses only `outputs_main`. The Llama3 generation C4-fused suite is reconstructed by generating the required kernels and matching existing `outputs_main/*/raw_db.csv` rows by exact `(app, args)`. This matters because several required C4-fused GEMM shapes are present as matching `C4_alone` rows, not as `llama3_8b_generation_C4_fused` case IDs.

The C1/C4 ratio is almost flat:

| KV length | C1 total (s) | C4 total (s) | C1/C4 |
| ---: | ---: | ---: | ---: |
| 512 | 85.730 | 12.218 | 7.02x |
| 1024 | 86.334 | 12.264 | 7.04x |
| 2048 | 87.853 | 12.535 | 7.01x |
| 4096 | 90.652 | 12.920 | 7.02x |

The ratio is flat because the dominant C1-vs-C4 difference is the projection GEMMs, and those are fixed across generation KV length. Generation projects one new token, so `q_proj`, `k_proj`, `v_proj`, `o_proj`, `gate_proj`, `up_proj`, and `down_proj` do not grow with the cache length. In this reconstruction, C1 projection GEMMs stay at `80.422s`, while C4 projection GEMMs stay at `4.191s`. That fixed projection gap is about `76.231s`, which dominates the total ratio.

Breakdown by generated-suite bucket:

| KV length | Variant | Projection GEMM (s) | AttenGEMM (s) | Rest (s) | Total (s) |
| ---: | --- | ---: | ---: | ---: | ---: |
| 512 | C1 | 80.422 | 1.658 | 3.651 | 85.730 |
| 512 | C4 | 4.191 | 0.891 | 7.136 | 12.218 |
| 1024 | C1 | 80.422 | 2.194 | 3.718 | 86.334 |
| 1024 | C4 | 4.191 | 0.874 | 7.199 | 12.264 |
| 2048 | C1 | 80.422 | 3.544 | 3.887 | 87.853 |
| 2048 | C4 | 4.191 | 0.908 | 7.437 | 12.535 |
| 4096 | C1 | 80.422 | 6.006 | 4.225 | 90.652 |
| 4096 | C4 | 4.191 | 0.917 | 7.813 | 12.920 |

C1 attention does increase with sequence length. Its AttenGEMM bucket grows from `1.658s` at KV 512 to `6.006s` at KV 4096, a `4.348s` increase:

| KV length | C1 `attn_qkT` (s) | C1 `attn_pv` (s) | C1 AttenGEMM total (s) |
| ---: | ---: | ---: | ---: |
| 512 | 0.963 | 0.695 | 1.658 |
| 1024 | 1.232 | 0.962 | 2.194 |
| 2048 | 2.309 | 1.235 | 3.544 |
| 4096 | 3.961 | 2.045 | 6.006 |

C4 attention does not increase much in the current `outputs_main` measurements. The generated C4 attention GEMM args grow with KV length:

- `attn_qkT`: `-m 4 -n {KV} -k 128 -q 128 -t 1 -d 0`
- `attn_pv`: `-m 4 -n 128 -k {KV} -q 128 -t 0 -d 1`

However, the matched `fpint_gemm_ffn_hw` p50 latency remains nearly constant:

| KV length | C4 `attn_qkT` p50 (us) | C4 `attn_pv` p50 (us) | C4 AttenGEMM total (s) |
| ---: | ---: | ---: | ---: |
| 512 | 1741.910 | 1737.614 | 0.891 |
| 1024 | 1705.418 | 1710.200 | 0.874 |
| 2048 | 1735.029 | 1811.874 | 0.908 |
| 4096 | 1799.515 | 1781.834 | 0.917 |

So the answer is not that C1 attention is flat. C1 attention is growing. The ratio stays flat because:

- The fixed projection GEMM improvement is very large: `80.422s -> 4.191s`.
- The growing C1 attention term is still small compared with that fixed projection gap over KV 512 to 4096.
- The C4 improve attention GEMM measurements are almost flat for these Llama3 GQA shapes (`M=4`, `QBLK=128`), so C4 does not gain much additional sequence-dependent cost.
- C4 rest grows from `7.136s` to `7.813s`, which offsets part of the increasing C1 attention saving.

Numerically, from KV 512 to KV 4096, C1 total increases by `4.922s` (`85.730s -> 90.652s`) while C4 total increases by `0.703s` (`12.218s -> 12.920s`). Both increases are small compared with the fixed projection gap, so the C1/C4 ratio stays near `7.0x`.
