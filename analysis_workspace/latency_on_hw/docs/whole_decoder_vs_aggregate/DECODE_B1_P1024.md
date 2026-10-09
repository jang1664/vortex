# C4 연결 decoder vs 개별 연산 합 — B1, past KV 1024, decode 1 step

2026-10-09. Llama3-8B와 Llama2-7B의 실제 크기 **decoder 1 layer**를 C++
regression kernel로 연결해 측정했다. Random weight/input이며 모든 head를 실행한다.
이 결과는 prefill 후 첫 **증분 decode** 한 단계다. Embedding/LM head/sampling이
없으므로 전체 모델의 첫 output token 시간(TTFT)이나 128-token 생성 시간은 아니다.

## 조건과 측정 범위

- C4 alias: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update`.
  TH16/MXU16, 100 MHz, FPGA `0000:2a:00.1`, Slurm job 5759.
- Batch 1, query 1, 기존 KV 1024 → 위치 1024에 append → 유효 KV 1025.
  Capacity 1152, QK target_N / PV target_K 1056(32 정렬).
- 입력/weight/기존 KV는 미리 upload한다. CPU의 같은 모델·seed prefill 결과에서
  KV prefix를 준비했다. 새 token의 projection, RoPE/Hadamard, quantization와
  packing/append, QK/softmax/PV, FFN은 모두 측정에 포함한다.
- Wall time은 `decoder.run()`이다. 중간 dump/check, CPU↔device tensor 복사,
  counter 조회는 제외하고 kernel launch/wait, MMIO, host bookkeeping은 포함한다.
  Runtime polling sleep 및 고정 settle 대기는 없다.
- Warmup 후 각 3회, 중앙값. 매회 같은 KV 위치를 덮어써 조건을 고정한다.
- 독립 합은 **같은 C4·보드·입력·인자**로 각 op를 warmup 후 재측정한 cycle 합이다.
  rev5의 여러 candidate를 섞은 CSV나 128 decode-step 평균과 직접 비교한 값은 아니다.

## Latency

| 모델 | 독립 op cycle 합 | 독립 합 환산 | 연결 cycle 합 환산 | 연결 wall time | wall / 독립 합 |
|---|---:|---:|---:|---:|---:|
| llama3 | 13,197,074 | 131.971 ms | 131.998 ms | 134.433 ms | +1.866% |
| llama2 | 16,698,057 | 166.981 ms | 166.390 ms | 170.778 ms | +2.274% |

Llama3는 100 op, Llama2는 148 op이며 GEMM은 각각 71개다. Wall time의
3회 범위는 Llama3 133.967–134.566 ms, Llama2 170.502–170.939 ms다.
연결 wall과 독립 cycle 합의 차이는 약 2.46/3.80 ms다. 별도 실행의 변동과
host 비용이 함께 포함되므로 그 차이 전부를 순수 launch 비용으로 볼 수는 없다.

## M=1 layout 연결 수정

기존 fused vector kernel은 microtile마다 8행 물리 pitch를 사용한다.
GEMM에 origin_M=1을 전달하면 packed M=1 layout으로 해석해 첫 projection부터
큰 오차가 발생했다. **origin_M=8, target_M=1**로 저장 공간과 연산 범위를 분리했다.
실제 계산은 한 행이지만 padding 전송 및 inactive output row 보존 비용은 남는다.
따라서 compact origin_M=1의 standalone GEMM 수치와 같다고 해석하면 안 된다.
이번 연결/독립 비교에는 모두 동일한 parent layout을 사용했다. RTL은 변경하지 않았다.

Tiled 입력의 KV append는 기존 generic accessor를 사용하게 했다. Row-major
전용 contiguous fast path를 tiled 입력에 적용하지 않도록 조건을 제한했으나,
후속 A/B에서 기존 single-row bench의 성능 회귀가 확인되어 그 제한은 되돌렸다.
Decoder는 src_total_K=8이므로 기존 조건만으로 generic 경로를 선택한다.
[후속 A/B 및 되돌림 기록](KV_QUANT_LATENCY_AB_20261009.md) 참고.
KV 전체를 다시 packing하지 않고 새 token만 quantize/pack한다.

## 정확성: FAIL을 유지한 진단용 측정

두 모델 모두 PV의 기존 FP16 subnormal 문제가 남아 **최종 출력도 FAIL**이다.
허용 오차를 변경하지 않았다. 기본 timing은 실패 시 중단하며,
이번에는 `--diagnostic-timing`으로 실패 JSON과 nonzero exit를 유지하며 측정했다.

| 모델 | 최종 출력 상대 L2 | 최대 절대 오차 | 최종 기준 초과 | 동일 입력 PV 상대 L2 |
|---|---:|---:|---:|---:|
| llama3 | 0.3560% | 0.00878906 | 635/4096 (15.50%) | 1.5057% |
| llama2 | 0.2785% | 0.00634766 | 381/4096 (9.30%) | 1.6141% |

- 수행한 동일 입력 검증 중 PV 이외의 연산은 PASS.
- 모든 head의 packed KV weight/scale/zero 불일치 **0개**. 기존 prefix와 비활성
  tail까지 비교했고, 측정 반복 후에도 일치했다. 미사용 cache는 nonzero 값이므로
  잘못된 유효길이/masking을 0-filled cache가 숨기지 않도록 했다.
- PV를 기존 QROW FP16 multiplier의 subnormal flush 및 출력 converter 결함
  모델로 계산하면 두 모델 모두 **4096개 전부 bit-exact**하다. 이것은 원인 진단이며
  올바른 산술 기준의 PASS를 대신하지 않는다.
- 이번 decode 출력의 TVM FPGA 실행 비교는 하지 않았다. TVM export와 공유하는
  CPU 모델로 검증했다.

## 회귀 검증

- M=1/4/32/129/136/256의 padded parent layout host 검사 PASS.
- 기존 Llama3/Llama2 B1/S32 prefill FPGA 최종·중간 검증 PASS.
- 기존 row-major persistent KV append K/V(capacity1152, position1024) FPGA PASS.
- Python syntax 및 `git diff --check` PASS.

## 재현

[실행법](../../../../tests/regression/llama_decoder_C4/README.md)의 decode section 참고.
실험 자료: `build_llama_decoder_c4/results/decode_b1_p1024_20261009/`의
`run.sh`, `summary.json`, `provenance.json`, 모델별 `verify/`, `timing/`, `isolated/`.
`pv_defect_diagnosis.json`은 verify 폴더에 있다. `session_v4.log`는
진단 측정 절차 완료 로그이며, functionality PASS 로그가 아니다.
