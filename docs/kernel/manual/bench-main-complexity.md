# `bench_main` kernel 복잡도 요약

아래 식은 latency의 정확한 예측식이 아니라, kernel argument가 커질 때 처리해야 하는
logical work의 증가 방향을 나타낸다. Tile/DMA startup, thread 수, memory bandwidth에
따라 실제 latency는 선형식과 다를 수 있다.

| benchmark | 주요 argument | logical work |
|---|---|---|
| `sgemm_tcu`, `fpint_gemm_ffn_hw`, `fpint_gemm_ffn_hw_naive`, `deprecated/fpint_gemm_ffn_hw_improve` | `M, N, K` | GEMM: `O(MNK)` |
| `softmax`, `softmax_layout_fused` | rows=`batch×heads×seq_q`, cols=`seq_k` | `O(rows×cols)`; max, exp/sum, normalize가 모두 K 방향으로 증가 |
| `rmsnorm`, `rms_norm_layout_fused` | rows=tokens, cols=`K`/hidden | `O(rows×cols)` |
| `rope`, `rope_layout_fused` | `batch, seq, heads, head_dim` | `O(batch×seq×heads×head_dim)` |
| `silu`, `silu_layout_fused` | `M, K` | `O(MK)` |
| `eladd`, `eldiv`, `elmul`, `elscalar`, `elsub`, `elunary` | element `size` | `O(size)` |
| `eladd_layout_fused`, `elmul_layout_fused` | `M_real, K` | 보통 `O(M_real×K)`; zero-pad variant는 `M_pad×K` 쓰기 포함 |
| `dropout`, `vecadd` | `num_points` | `O(num_points)` |
| `elreduce` | rows, reduction width | `O(rows×width)` |
| `head_concat`, `head_concat_layout_fused` | `batch, seq, heads, headdim` | `O(batch×seq×heads×headdim)` |
| `hadamard`, `hadamard_base` | rows, `base_k`, width | dense base transform는 `O(rows×width×base_k²)` |
| `hadamard_layout_fused` | rows, dim, factorization | factorized butterfly는 대체로 `O(rows×dim×log dim)`, base stage 비용 추가; zero-padding은 padded dim/row 처리 포함 |
| `kv_cache_quant_w4a16`, `kv_cache_dequant_w4a16` | `K, N` | element 변환은 `O(KN)`; group qparam 처리는 group 수에 비례 |
| `kv_cache_quant_layout_fused_w4a16` | valid `K, N`, source layout, cache update mode | full update는 `O(KN)`, append update는 새 token 수에 비례; tile/edge 처리 추가 |
| `detile_output` | `M, N`과 `M_pad, N_pad` | valid copy는 `O(MN)`; launch는 N tile 단위 |
| `tile_input_a` | `M_real, K_real`, `M_pad, K_pad` | destination 생성/zero-fill을 포함해 `O(M_pad×K_pad)` |
| `tile_weight_w4a16` | `K, N`, output tile shape | valid 변환 `O(KN)` + edge tile padding |
| `tile_scale_zp_w4a16` | `K, N, QBLK` | qparam 수와 padded scale slot/tile 수에 비례 |

## Decode attention에서 변하는 항

decode step의 실제 attention 길이를 `S = gen_kv_len + step + 1`이라 하면:

| logical kernel | 주요 shape | S에 대한 work |
|---|---|---|
| `attn_qkT` | `(1×D) · (D×S)` | `O(D×S)` |
| `attn_softmax` | 한 query row의 S개 score | `O(S)` |
| `attn_pv` | `(1×S) · (S×D)` | `O(S×D)` |
| attention detile/tile | S개 score/weight 변환 | `O(S)` 또는 tile launch 수 |
| KV dequant | cache의 `S×D` | `O(S×D)` |
| projection, norm, RoPE, FFN, residual | decode query는 항상 한 token | S와 무관 |

GEMM 실행기는 logical work가 선형이어도 내부 tile 수
`ceil(M/TM)×ceil(N/TN)×ceil(K/TK)`에 의해 latency가 계단식으로 보일 수 있다.

