# Rev7: B1/S1024 layout refresh (2026-10-10)

Follow-up: [C4 decode geometry correction and remeasurement](C4_DECODE_GEOMETRY_FIX.md). The C4 decode estimates below are the pre-fix baseline; C1~C3 and prefill results remain unchanged.

Generator 수정 후 Llama2-7B와 Llama3-8B의 prefill 및 one-step decode를 FPGA에서 재측정했다. 물리 측정 177개 정상 종료(Llama2 81, Llama3 96), compose 428개 논리 항목 모두 `pass` / `measured`. 누락 및 interpolation 항목은 0개다.

## 변경 범위

- C1/C2/C3 Q/K: RoPE `task_chunk16`의 `-head-major 1`로 head-major 출력을 직접 생성.
- C1/C2/C3 V: KV quant `groupwise_fp16`의 `--src-row-stride`로 projection에서 각 head를 직접 읽음. Llama2=4096, Llama3=1024 FP16 elements.
- C1/C2 PV: TCU `b_colmajor` variant에 `-r 1`을 전달하여 row-major B를 읽음. QK/linear GEMM은 기존 column-major B 유지.
- 별도 Q/K/V head reorder와 V transpose 제거. PV 뒤 head concat 유지. C4 fused 경로와 RTL 변경 없음.
- Host correctness/benchmark harness와 device ABI를 함께 확장. 새 args를 exec key에 포함하여 이전 dense/column-major 측정값과 구분.

기존 reuse suite 정책을 유지한다. C2는 C1의 TCU/vector와 C3의 naive GEMM 측정값을 합산하며, C2 이미지에서 독립적으로 측정한 raw DB가 아니다.

## 측정 조건과 해석

- Candidate map: `analysis_workspace/latency_on_hw/candidate_fpga_bins.rev7.yaml`; 모든 이미지 100 MHz.
- Prefill: B1, S1024. Decode: B1, 기존 KV1024에서 새 토큰 1개 처리; attention 유효 길이 1025.
- 생성 옵션: `--decode-measurement exact --generation-out-tokens 1 --generation-max-seq-len 1152`.
- 모델별 동일 FPGA에서 prefill → decode 순서로 실행. Llama2 BDF `0000:2a:00.1`, Llama3 BDF `0000:3d:00.1`; 두 모델 병렬.
- Latency만 측정. Power는 모든 app에 `--skip-power-app` 적용. Raw 측정은 warmup=0, iterations=1; 작은 차이의 통계적 유의성을 주장하지 않음.
- Workflow `generate → run → refine → compose` 완료. Refine은 `--max-iterations 0`으로 추가 probe 없이 종료; 요청한 한 점은 모두 직접 측정됨. 범위 전체의 interpolation 수렴을 검증한 것은 아님.

아래 표는 **decoder layer 1개의 device cycle 합계를 초로 환산**한 값이다. 이번 standalone 측정값에 실제 호출 수를 곱하고 두 모델의 32개 layer 수로 나눴다. 양쪽 모두 dequant를 제외했다. Decoder는 직전에 검증한 fix_sub_norm profile을 사용했으며 이번에 다시 실행하지 않았다. **Host wall time이나 kernel launch overhead를 포함한 비교가 아니다.**

오차 = `(estimate / decoder - 1) × 100`. 음수는 estimate가 더 낮음을 뜻한다.

## Prefill B1/S1024

| Model | Candidate | Decoder device (s) | Rev7 estimate (s) | Error |
|---|---|---:|---:|---:|
| llama2_7b | C1 | 295.123043 | 294.753405 | -0.13% |
| llama2_7b | C2 | 66.095492 | 65.890653 | -0.31% |
| llama2_7b | C3 | 50.361461 | 50.295646 | -0.13% |
| llama2_7b | C4 | 50.092732 | 49.224797 | -1.73% |
| llama3_8b | C1 | 285.528912 | 283.766885 | -0.62% |
| llama3_8b | C2 | 45.511646 | 45.342313 | -0.37% |
| llama3_8b | C3 | 29.883294 | 29.744932 | -0.46% |
| llama3_8b | C4 | 31.007163 | 30.338142 | -2.16% |

## Decode B1/KV1024, one step

| Model | Candidate | Decoder device (s) | Rev7 estimate (s) | Error |
|---|---|---:|---:|---:|
| llama2_7b | C1 | 3.965598 | 4.002549 | +0.93% |
| llama2_7b | C2 | 0.524453 | 0.521694 | -0.53% |
| llama2_7b | C3 | 0.241291 | 0.237883 | -1.41% |
| llama2_7b | C4 | 0.150012 | 0.137393 | -8.41% |
| llama3_8b | C1 | 3.940578 | 3.939284 | -0.03% |
| llama3_8b | C2 | 0.337059 | 0.341731 | +1.39% |
| llama3_8b | C3 | 0.268507 | 0.271732 | +1.20% |
| llama3_8b | C4 | 0.107685 | 0.099956 | -7.18% |

C1~C3의 절대 오차는 prefill 0.62% 이내, decode 1.41% 이내다. C4는 prefill 1.73~2.16%, decode 7.18~8.41% 낮게 추정된다. C4 잔여 차이의 원인은 이번 작업에서 확정하지 않았다.

Decode 비교의 제한: 과거 C1~C3 decoder의 cache capacity는 1056, C4는 1152였다. 이번 suite의 공통 capacity 옵션은 1152다. 기존 GEMM canonicalization/물리 stride 정책은 유지했으므로 위 표는 완전히 같은 물리 geometry를 재실행한 A/B 비교가 아니다. C2의 이미지 간 reuse와 synthetic 입력 차이도 남아 있다.

## 변경된 경로의 측정 cycle

C1에서 측정한 1회 kernel cycle. PV는 한 head/group의 GEMM이며 전체 head 합산값이 아니다. 같은 값을 C2에서도 재사용한다. C3는 RoPE/quant만 공유하며 PV는 naive GEMM이다.

| Model | Stage | RoPE Q | RoPE K | V quant | TCU PV row-major |
|---|---|---:|---:|---:|---:|
| llama2_7b | generation | 57,466 | 57,466 | 27,264 | 399,301 |
| llama2_7b | prefill | 22,199,675 | 22,199,675 | 1,912,299 | 20,063,429 |
| llama3_8b | generation | 56,960 | 44,094 | 27,425 | 386,290 |
| llama3_8b | prefill | 20,819,701 | 5,581,356 | 1,910,685 | 20,091,453 |

## 검증

- 관련 Python 테스트 61개 PASS. 확장 실행에서 발견한 기존 실패 4개는 HEAD generator에서도 재현했으며 본 변경의 통과 수에 포함하지 않음 (`build_rev7_layout_validation/preexisting_test_failures.log`).
- FPGA 기능 검사 8개 PASS: head-major RoPE B2/S32, stride 1024/4096 및 K1 quant, row-major TCU K256/K1056, QK shape, directed subnormal-B.
- TCU random M32/K1056/N128의 엄격한 원소별 검사에서는 **기존 column-major와 새 row-major 모두 동일한 1/4096 원소가 실패**: expected=260.0, actual=260.25, FP16 1 ULP(약 0.096%). 허용 오차를 바꾸지 않았으며 모두 functionality PASS라고 처리하지 않았다.
- Pipeline의 raw `pass`는 benchmark 실행/측정 성공을 뜻한다. 별도의 전체 출력 correctness 검사는 앞선 decoder 회귀 결과와 위 기능 검사로 구분한다.
- Compose 검사: 모든 항목 직접 측정, 새 layout args 유지, 삭제 대상 reorder 0개, C2 source C1/C3, B1/S1024 및 one-step 범위 확인.

## 결과 위치와 재현

- Tag: `th16_20261010_rev7_layout_b1_s1024`
- Raw: `analysis_workspace/latency_on_hw/outputs_{llama2,llama3}_main.th16_20261010_rev7_layout_b1_s1024/{C1,C3,C4}/raw_db.csv`
- Compose: `analysis_workspace/latency_on_hw/composed_results.th16_20261010_rev7_layout_b1_s1024/{llama2_7b,llama3_8b,combined}/composed.csv`
- Suites: `analysis_workspace/latency_on_hw/generated_suites/{llama2_7b,llama3_8b}_main_full.th16_20261010_rev7_layout_b1_s1024/`
- Decoder C1~C3: `build_decoder_layout_c{1,2,3}/results/<model>_{prefill1024,decode1024}/{profile,warmup_profile}.csv`.
- Decoder C4: `build_decoder_fix_sub_norm_c4/results/<model>_{prefill1024,decode1024}/profile.csv`.
- 실행 argv: `build_rev7_layout_validation/pipeline_command.json`. 실행 helper: `run_pipeline.py`; log: `generate.log`, `pipeline.log`, `compose_pipeline.log`.
- 실행: conda vortex Python으로 `run_pipeline.py --from generate --to generate`, 이어서 인자 없이 run, 마지막으로 `run_pipeline.py --from refine --to compose --max-iterations 0 --validation-samples 1`.
- 표 재생성 및 결과 assertions: `build_rev7_layout_validation/summarize.py`; 비교 수치: `summary.json`.
- 이전 decoder 수정/기능 검증: [C1_C3_LAYOUT_ADAPTER_REMOVAL.md](C1_C3_LAYOUT_ADAPTER_REMOVAL.md).
