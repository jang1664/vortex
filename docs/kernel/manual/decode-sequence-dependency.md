# Decode kernel의 attention sequence 의존성

`S`는 현재 token을 포함한 logical attention 길이다. 분류는 sampled 측정 정책을
선택하기 위한 것이며, kernel argument에는 항상 실제 `S`를 전달한다.

## 1. Attention sequence length와 무관

한 decode pass에서 query token 수가 1로 고정되어 `S`가 바뀌어도 shape가 동일하다.
sampled mode에서는 한 번 측정하고 `out_tokens`만큼 가중한다.

- embedding/final projection
- RMSNorm
- Q/K/V/O projection 및 FFN GEMM
- RoPE와 query-side layout 변환
- SiLU, residual add, SwiGLU multiply
- head concat
- 새 token 하나만 처리하는 KV-cache append quantization

cache position처럼 argument 문자열이 달라도 처리량이 한 token으로 고정된 append
kernel은 이 그룹에 포함한다.

## 2. Logical S에 따라 연속적으로 변함

valid loop bound가 `S`이므로 같은 physical padding bucket 안에서도 work가 달라진다.
sampled mode에서는 시작/끝, 일정 간격, tile 경계 주변을 측정하고 사이를 선형
보간한다.

- `attn_softmax` (`softmax`, `softmax_layout_fused`)
- `kv_cache_dequant_k_to_attn_qkT`
- `kv_cache_dequant_v_to_attn_pv`

이 그룹은 padded argument 하나로 합치면 안 된다.

## 3. Tile 경계 중심의 계단식 변화

실행 tile/grid 수가 `ceil(S/tile)`로 증가하여 latency가 주로 tile 경계에서 바뀐다.
sampled mode에서는 각 padded execution bucket마다 logical argument 한 개를
측정하고 그 bucket의 decode step 수만큼 가중한다.

- `attn_qkT`, `attn_pv`의 `sgemm_tcu` backend
- `attn_qkT`, `attn_pv`의 FPINT GEMM backend. C1-C4 측정에서는
  M/N/K를 각각 8/MXU_NT/MXU_KT 단위로 canonicalize한다.
- `layout_attn_qkT_to_softmax_detile`
- `layout_attn_softmax_to_attn_pv`

마지막 tile의 valid lane이나 DMA tail 때문에 bucket 내부 latency가 완전히 동일하다는
보장은 없다. 정확한 평가가 필요하면 `exact` mode를 사용한다.

## 측정 mode

- `exact`: 모든 decode step을 실제 logical argument로 측정
- `sampled`: 위 분류에 따라 invariant 1회, continuous 보간 sample, tile bucket
  대표 sample만 측정

`raw_db.csv`의 `args`는 항상 실제 측정 argument다. `padded_args`는 execution
granularity로 padding했을 때의 참고 문자열일 뿐 실행이나 DB matching에 사용하지
않는다.

`cases.csv`의 `args`는 logical argument이고 `measurement_args`는 latency-equivalent
canonical argument다. Canonicalization이 활성화된 kernel은 `measurement_args`로
실행하고 동일한 canonical shape의 logical case가 하나의 raw measurement를 공유한다.
