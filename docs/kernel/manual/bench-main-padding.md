# `bench_main` padding 동작 요약

대상은 `tests/**/bench_main.cpp`가 있는 regression benchmark 35개다.

용어:

- **logical 크기**: 사용자가 지정한 실제 tensor 크기
- **physical padding**: allocation, stride, tiled layout을 위해 확보한 여분 영역
- **launch rounding**: block/thread 수만 올림하고 kernel 내부에서 logical 범위를 검사하는 것

중요한 점은 physical 크기가 같다고 연산량까지 항상 같은 것은 아니라는 것이다.
아래의 **valid만 연산** 유형은 logical argument를 padding해서 전달하면 원래보다 더
많이 연산하게 된다.

## 요약

| benchmark | padding 처리 | 실제 연산량 |
|---|---|---|
| `sgemm_tcu` | `M/N/K`를 각각 TCU tile 크기로 올린 `M_exec/N_exec/K_exec`를 allocation과 kernel argument에 사용 | **padded 전체 GEMM**. 같은 exec 크기면 같은 연산량 |
| `fpint_gemm_ffn_hw` | DRAM output slot의 `M`만 8 단위 `M_pad`로 잡지만, hardware에는 원래 `M/N/K`를 전달 | **logical `M/N/K` 기준**. tile tail 비용은 있을 수 있으나 argument를 미리 padding하면 문제 크기가 커짐 |
| `fpint_gemm_ffn_hw_naive` | 별도의 logical-to-padded argument 변환 없음. hardware에 원래 `M/N/K` 전달 | **logical `M/N/K` 기준** |
| `deprecated/fpint_gemm_ffn_hw_improve` | TMEM 영역별 시작 주소/크기를 alignment하고 원래 GEMM 크기는 유지 | **logical `M/N/K` 기준** |
| `softmax` | `seq_len_k`와 physical `row_pitch_bytes`를 분리. `-seqk-stride` 또는 variant 규칙으로 row storage만 padding | **`seq_len_k`까지만 softmax** |
| `softmax_layout_fused` | `seq_len_k`와 `seq_len_k_pad/output_k_pad`를 분리. `M`은 8, K storage는 DMA tile 단위로 padding | softmax reduction/exp는 **valid K만**, output padding은 zero-fill |
| `detile_output` | `M/N_real`과 `M_pad/N_pad`를 함께 전달 | padded source를 읽되 **valid `M×N`만 변환/출력** |
| `tile_input_a` | `M_real/K_real`과 `M_pad/K_pad`를 함께 전달 | padded destination 전체를 만들지만, valid input만 읽고 나머지는 **zero-fill**. padding 크기에 따라 zero-fill 작업량은 증가 |
| `tile_weight_w4a16` | output K/N을 DMA tile 단위로 확보하고 logical `K/N`도 유지 | tile variant는 edge tile을 포함해 padded layout을 생성. valid data 변환 + padding 처리 비용 |
| `tile_scale_zp_w4a16` | K/N tile 수와 scale slot 크기를 올림하고 logical `K/N` 유지 | ceil tile/slot 단위 작업. edge에서 padding slot을 생성하므로 bucket 크기에 따른 비용 |

## Layout-fused 및 변환 kernel

| benchmark | padding 처리 | 실제 연산량 |
|---|---|---|
| `eladd_layout_fused` | input layout의 `M_pad`와 `M_real`을 분리 | **valid `M_real×K`만 연산** |
| `elmul_layout_fused` | `M_pad`와 `M_real`을 분리 | 대부분 variant는 **valid rows만** 연산. 일부 same-layout/zero-pad variant는 padded row도 처리하므로 variant 의존 |
| `silu_layout_fused` | output은 `M_pad×K`, logical `M_real` 별도 전달 | 일반 variant는 **valid 영역만** 연산. zero-padding variant는 padded row를 0으로 쓰는 추가 작업 수행 |
| `rms_norm_layout_fused` | output은 `M_pad×K`, launch row 수는 `M_real` | RMSNorm은 **valid rows만**, padded storage는 연산 대상이 아님 |
| `head_concat_layout_fused` | input/output `M_pad`를 별도 stride로 사용하고 `batch/seq` 유지 | **valid token/head/dim만** 복사 |
| `rope_layout_fused` | input/output `M_pad`는 주소 계산용, `seq_len`은 별도 유지 | **valid sequence만** RoPE 연산 |
| `hadamard_layout_fused` | row storage는 `m_pad`. variant에 따라 valid row만 launch하거나 padded row도 launch | `factorized`는 주로 **valid row 연산**. `zero_padding`은 padded row/column을 명시적으로 0 처리하여 padding 비용 포함 |
| `kv_cache_quant_layout_fused_w4a16` | source physical shape/capacity와 logical `K/N`을 분리하고 output tile 수는 ceil 처리 | valid cache data를 quantize하며 edge tile/slot 처리 비용이 있음. append mode는 새 token 영역만 처리 |

## KV-cache quantization

| benchmark | padding 처리 | 실제 연산량 |
|---|---|---|
| `kv_cache_quant_w4a16` | 별도 K padding 없이 logical `K/N`으로 allocation과 work item 계산 | **logical `K×N` 기준** |
| `kv_cache_dequant_w4a16` | 별도 K padding 없이 logical `K/N`으로 allocation과 work item 계산 | **logical `K×N` 기준**. K를 미리 padding하면 dequant 연산량도 직접 증가 |

## Padding을 사용하지 않는 일반 kernel

아래 benchmark는 tensor 크기를 별도로 padding하지 않는다. grid/block 수만 올림하거나
사용 가능한 core 수에 맞추고, kernel loop 또는 bounds check가 logical 크기에서 끝난다.

| benchmark | 실제 연산 범위 |
|---|---|
| `eladd`, `eldiv`, `elmul`, `elscalar`, `elsub`, `elunary` | logical element `size` |
| `dropout`, `vecadd` | logical `num_points` |
| `elreduce` | logical batch/row와 reduction width |
| `silu` | logical `M×K`; chunk variant는 마지막 partial chunk 처리 비용만 추가 |
| `head_concat` | logical `batch×seq×heads×headdim` |
| `rmsnorm` | logical token 수와 hidden dimension |
| `rope` | logical sequence/head dimension |
| `hadamard`, `hadamard_base` | logical rows/base-K/width. 지원 shape 제약은 있지만 별도 storage padding은 없음 |

## Latency suite에서의 해석

- `sgemm_tcu`처럼 kernel argument 자체가 execution 크기인 경우에만 padded 크기를
  실행 key로 사용하는 것이 안전하다.
- `softmax`, layout-fused, KV quant/dequant, FPINT GEMM처럼 logical 크기를 따로
  사용하는 경우에는 logical argument를 유지해야 한다.
- allocation 크기가 같은 여러 shape를 하나로 합칠 수 있는지는 allocation alignment가
  아니라 **kernel loop bound, edge handling, zero-fill 작업량**을 기준으로 판단해야 한다.
