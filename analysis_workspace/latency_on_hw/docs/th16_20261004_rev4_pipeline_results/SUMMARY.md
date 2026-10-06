# 분석할 figure 목록
llama_gemm_only_no_area_norm
llama_e2e_no_area_norm_stacked
llama_energy_no_area_norm_gemm_layout_vector_stacked/llama_energy_per_token_power_fpga_dequant_dynamic_W_no_area_norm_gemm_layout_vector_stacked.*

분석 대상은 `th16_20261004_rev4_pipeline`의 figure와 해당 prepare manifest가 가리키는 CSV다. 기존 rev3 SUMMARY의 세 figure 분류와 분석 1–11의 순서를 유지하고, 관찰·수치·원인을 rev4 결과로 다시 작성했다. 아래 수치는 모두 rev4에서 계산했다. 비율은 같은 model/stage/batch/context의 `비교 후보 값 / C4 값`이며, C4 막대의 합은 1이다. 비율이 클수록 C4가 유리하다. 서로 다른 context나 batch의 상대 막대 높이만으로 절대 시간이 감소한다고 해석하지 않는다.

수치 근거는 [Llama2 prepared manifest](../../figure_prepare.th16_20261004_rev4_pipeline/prepare_manifest.llama2_7b.json)와 [Llama3 prepared manifest](../../figure_prepare.th16_20261004_rev4_pipeline/prepare_manifest.llama3_8b.json)의 GEMM-only, E2E name/backend, energy name/backend CSV다. Component는 figure와 같은 stack 분해·C4 정규화로 계산했다. 시간 증가 배수는 prepared `total.csv`의 합산 시간과 component 비중으로 구했다.

| 후보 | 구성 | rev4 FPGA alias |
| --- | --- | --- |
| C1 | Linear와 attention 모두 FP TCU | `tcu_th16_c1_v3_axi_fix` |
| C2 | Linear는 naive FP–INT, attention은 FP TCU; C1/C3 결과를 합성 | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3_axi_fix` |
| C3 | Linear와 attention 모두 naive FP–INT | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3_axi_fix` |
| C4 | Linear와 attention 모두 improved FP–INT, vector는 fused-layout 경로 | `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_axi_fix` |

[Candidate map](../../candidate_fpga_bins.rev4.yaml). 실제 실행 후보는 C1/C3/C4이며 C2는 합성 후보다. [실행 설정](../../pipeline_state.th16_20261004_rev4_pipeline/launch.json)에 softmax fused variant `rev2_shuffle_cursor`, full suite, 출력 128 step, 두 모델 병렬 실행이 기록되어 있다.

Prefill은 B=1, context=1k–32k의 6개 지점이다. Decode는 B=1/4/64와 context=1k–32k의 18개 지점이다. 두 모델은 32 layers, hidden=4096, query heads=32, head dimension=128이다. Llama2는 KV heads=32, FFN dimension=11008이고 Llama3는 KV heads=8, FFN dimension=14336이다. [모델·attention geometry](../../../../tools/workload/gen_kernel_cfgs.py).

Latency는 kernel FPGA cycle에 호출 수를 적용한 합성 값이다. Prefill은 TTFT, Decode는 출력 128 step 합을 128로 나눈 배치 단위 TPOT다. Host 실행 시간은 포함하지 않는다. Latency에는 standalone weight/KV dequantization을 제외하고 energy에는 포함한다. 세 figure 모두 면적 정규화를 적용하지 않는다. [집계·포함 정책](../../prepare.py).

`layout` stack은 각 C4 fused kernel과 C3 대응 standalone kernel의 양수 비용 차이를 합산한 것이다. 음수 차이는 다른 kernel의 양수 비용을 상쇄하지 않으며, vector는 total을 유지하도록 나머지 비용으로 표시한다. 따라서 layout stack은 별도 DMA 측정값이나 순수 layout 변환 시간과 같지 않다. [Stack 분해](../../plot.py).

Rev4의 softmax cursor barrier/fence 제거와 elmul 최적화·기능 검증 범위는 [후속 최적화 결과](../../regression_results/softmax_rev4_optimization/SUMMARY.md)에 기록되어 있다. 이 문서의 성능 해석은 현재 rev4 pipeline 결과에 근거하며, rev3의 과거 softmax 진단 수치를 사용하지 않는다.

# llama_gemm_only 분석

[분석 figure](../../figure_output.th16_20261004_rev4_pipeline/llama_gemm_only_no_area_norm/llama_gemm_only_latency_no_area_norm.png)

## 1. Prefill에서 seq가 길어지면 C4의 GEMM-only 이득이 커진다.

**관찰.** 두 모델 모두 6개 context에서 C3/C4 GEMM-only 비율이 증가한다. C1/C4와 C2/C4도 함께 증가한다.

| Model | C1/C4, 1k → 32k | C2/C4, 1k → 32k | C3/C4, 1k → 32k |
| --- | ---: | ---: | ---: |
| Llama2 | 28.95 → 39.65 | 2.38 → 26.38 | 1.067 → 1.146 |
| Llama3 | 28.02 → 38.51 | 2.29 → 25.55 | 1.067 → 1.144 |

**원인.** Projection·FFN의 M은 B×seq로 증가하지만, Prefill의 QKᵀ/PV는 query와 KV 길이가 함께 늘어 작업량이 대략 seq²에 비례한다. C4 GEMM에서 attention 비중은 1k → 32k에 Llama2 4.44% → 59.04%, Llama3 4.14% → 57.22%로 증가한다.

Prefill linear 합의 C3/C4는 약 1.06, attention은 약 1.21이다. 따라서 상대 이득이 더 큰 attention의 비중이 늘면서 전체 C3/C4도 약 1.07 → 1.14–1.15로 증가한다. C2는 attention에 FP TCU를 사용하므로 긴 seq에서 attention backend 차이가 더욱 크게 드러난다.

C1/C2 attention은 FP16 KV를, C3/C4는 packed INT4 KV를 사용한다. FP TCU와 FP–INT 비교에는 operand 표현과 전송량, backend 공급·연산 경로 차이가 함께 포함된다. 큰 C1 대비 이득을 하나의 RTL 최적화나 압축률만으로 설명하지 않는다.

## 2. Decode에서는 C4의 C3 대비 GEMM 이득이 Prefill보다 크다.

**관찰.** B=1, context=1k의 C3/C4 GEMM-only는 Llama2 2.38, Llama3 3.20이다. 같은 context의 Prefill은 두 모델 모두 약 1.07이다. Decode linear 합의 C3/C4는 각각 2.49, 3.26로 Prefill의 약 1.06보다 크다.

**원인.** Prefill linear의 logical M은 B×seq, Decode는 B다. Decode B=1은 큰 weight를 적은 입력 행에 적용하여 공급·tile 준비·명령 발행 비용을 여러 행에 나누기 어렵다. 현재 측정 정책은 FP–INT GEMM M을 8의 배수로 올림하므로 logical M=1은 M=8에서 측정된다. 이 작은 M 구간에서 backend 차이가 크게 나타난다. [측정 shape 정책](../../../../tools/latency_bench/kernel_latency_canonicalization.yaml).

C3는 LMEM operand 경로, C4는 전용 TMEM operand 경로와 scheduling을 사용한다. 작은 M의 공급·제어 비용 차이가 크다는 해석은 raw cycle과 component 비율에 부합한다. 다만 이 figure에는 stall counter가 없어 특정 DMA stall로 원인을 확정하지 않는다. C3에는 `GEMM_NAIVE_USE_ACC_MEM`이 켜져 있으므로 과거 naive의 LMEM PSUM 병목을 그대로 적용하지 않는다. [C3 설정](../../../../configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh), [C4 설정](../../../../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh).

## 3. Decode batch가 커지면 짧은 context의 이득은 줄고, 긴 context에서는 attention 가속이 이득을 유지한다.

**관찰.** Context=1k에서 B=1 → 64의 C3/C4 GEMM-only는 Llama2 2.38 → 1.44, Llama3 3.20 → 1.24로 감소한다. 반면 B=64에서 context=1k → 32k이면 각각 1.44 → 2.44, 1.24 → 2.19로 증가한다.

**원인.** Batch 증가는 linear M을 키우며 작은 M에서 컸던 backend 비용 차이를 좁힌다. B=64에서는 두 모델 모두 linear 합의 C3/C4가 약 1.086이다. Attention은 batch를 M에 합치지 않고 호출 수에 반영한다. Logical M은 Llama2 1, Llama3 4로 유지되고, 측정 M은 둘 다 8로 올림된다. 같은 context에서 attention C3/C4는 batch가 달라도 유지된다.

Context가 길어지면 attention의 N 또는 K가 증가한다. B=64, 32k의 C4 GEMM 중 attention 비중은 Llama2 94.38%, Llama3 79.86%이며 attention 자체의 C3/C4는 2.52, 2.47이다. Linear 이득이 작아져도 attention 가속이 긴 context의 GEMM-only 이득을 유지한다. [Attention shape·호출 수](../../../../tools/workload/gen_kernel_cfgs.py).

## 4. Llama3의 짧은 Decode는 Llama2보다 FFN 비중이 높다.

**관찰.** B=1, context=1k의 C4 GEMM에서 FFN 비중은 Llama2 57.03%, Llama3 77.32%다. Attention은 각각 14.14%, 3.65%다. 짧은 Decode의 C3/C4 GEMM-only도 Llama3가 더 크다.

**원인.** Llama3의 FFN dimension은 14336으로 Llama2의 11008보다 크다. Decode에서는 GQA로 같은 KV를 공유하는 query head 4개를 logical M=4에 묶어, layer·batch당 QKᵀ/PV를 각각 8회 호출한다. Llama2는 logical M=1로 각각 32회다. 둘 다 physical M=8에서 측정되므로 이 벤치마크에서는 호출 수 감소가 합산 latency에 크게 반영된다. Query head 수가 같으므로 attention의 논리적 산술 연산량이 1/4이라는 뜻은 아니다.

그 결과 Llama3의 짧은 Decode는 FFN backend 차이를 더 크게 반영한다. Context가 길어지면 attention 비중이 커지고, Llama3 B=1의 C3/C4 GEMM-only는 3.20 → 3.01로 조금 줄어든다.

Llama3는 Prefill에서도 query head 32개가 KV head 8개를 공유하는 GQA다. 현재 workload generator는 Prefill QKᵀ/PV를 query head별 M=seq_q GEMM으로 구성하고 layer·batch당 각각 32회로 집계한다. 따라서 Prefill의 GQA KV 공유와 Decode의 query head 묶음에 따른 호출 수 감소를 구분해서 해석한다. [Geometry 정의](../../../../tools/workload/gen_kernel_cfgs.py).

# llama_e2e_no_area_norm_stacked 분석

[분석 figure](../../figure_output.th16_20261004_rev4_pipeline/llama_e2e_no_area_norm_stacked/llama_e2e_latency_no_area_norm_stacked.png)

## 5. Prefill에서 C4는 Llama2의 E2E를 소폭 줄이지만, Llama3는 non-GEMM 비용으로 C3보다 느리다.

**관찰.** GEMM-only는 두 모델의 모든 Prefill 지점에서 C4가 빠르다. E2E C3/C4는 Llama2 1.002–1.021로 6개 지점 모두 C4가 조금 빠르고, Llama3는 0.980–0.984로 6개 모두 C4가 조금 느리다. Llama3의 C4 TTFT는 C3보다 약 1.66–2.00% 높다.

**원인.** Prefill의 C4 GEMM 비중은 Llama2 약 14–17%, Llama3 약 17–30%다. Vector·fused kernel 시간이 대부분을 차지하여 GEMM 이득이 E2E에 전부 반영되지 않는다. 다음은 각 workload의 **C4 E2E total을 100으로 둔 비용 차이**다. Non-GEMM은 vector와 layout의 합이다. Non-GEMM 증가 항이 음수이면 C4에서 비용이 줄었다는 뜻이다.

| Model / context | C3 → C4 GEMM 절감 | C3 → C4 non-GEMM 증가 | C4 total − C3 total |
| --- | ---: | ---: | ---: |
| Llama2 / 1k | 1.15 | -0.38 | -1.53 |
| Llama2 / 32k | 2.12 | 1.95 | -0.17 |
| Llama3 / 1k | 2.01 | 3.97 | 1.96 |
| Llama3 / 32k | 2.48 | 4.19 | 1.70 |

Llama2 1k에서는 MLP Hadamard 비용이 C4 total 기준 1.58 줄어, 다른 fused kernel 증가를 합친 non-GEMM 전체도 0.38 줄어든다. GEMM 절감과 더해 E2E가 개선된다. Llama2 32k에서는 softmax 추가 비용 2.57 등이 Hadamard 절감 0.97을 넘지만, non-GEMM 순증가 1.95는 GEMM 절감 2.12보다 작아 소폭 개선이 남는다.

Llama3 1k에서는 MLP Hadamard 추가 비용이 3.02로 non-GEMM 순증가 3.97의 큰 부분이다. 32k에서는 softmax 추가 비용 3.30이 순증가 4.19의 큰 부분이다. 두 지점 모두 GEMM 절감보다 커서 E2E가 느리다. 이 결과는 fused kernel 전체의 구현·실행 이미지 차이를 포함하며, layout 변환 하나만의 비용으로 해석하지 않는다.

## 6. Prefill의 vector 병목은 짧은 context의 MLP Hadamard에서 긴 context의 softmax로 이동한다.

**관찰.** C4 total에서 MLP Hadamard 비중은 1k의 Llama2 64.62%, Llama3 44.55%에서 32k의 23.17%, 11.38%로 줄어든다. Softmax 비중은 각각 6.57% → 58.24%, 10.70% → 67.66%로 늘어난다.

**원인.** Hadamard는 고정 FFN dimension을 seq에 비례하는 행 수에 적용한다. Softmax는 각 query에 대해 KV 전체를 처리하므로 Prefill 작업량이 seq²에 비례한다. 실제 1k → 32k에서 C4 Hadamard 시간은 두 모델 모두 약 32배, softmax는 Llama2 789.1배, Llama3 793.0배 증가한다. 이는 해당 구간의 측정 배수이며, seq²의 점근 작업량을 그대로 시간 배수로 대입한 값은 아니다. Hadamard 비중 감소는 절대 시간이 감소했다는 뜻이 아니다.

Hadamard의 모델별 차이는 factorized transform과 관련된다. Llama2는 11008=172×64, Llama3는 14336=28×512로 분해한다. Base matrix 누산 작업량은 row마다 `width × base_k² = FFN dimension × base_k`에 비례하여, Llama2의 `64 × 172²`가 Llama3의 `512 × 28²`보다 약 4.72배 크다. Butterfly·메모리 접근·실행 overhead를 포함한 전체 latency 비율은 이 연산량 비율과 같지 않다. 실제 C4 Hadamard 시간은 Llama3가 Llama2의 약 42.3–42.5%, 즉 Llama2가 약 2.35배다. [Factor 선택](../../../../tools/workload/gen_kernel_cfgs.py), [base transform](../../../../tests/regression/hadamard_layout_fused/kernel.cpp).

**C1 대비 E2E 추세가 반대인 원인.** 1k → 32k에서 C1/C4 E2E는 Llama2 5.83 → 6.57로 증가하고 Llama3 9.12 → 7.43로 감소한다. GEMM-only 이득은 두 모델 모두 커지지만, E2E에서 GEMM의 시간 비중이 다르다. `C1/C4 E2E = r_G × w_G + n_1`로 분해할 수 있다. `r_G`는 C1/C4 GEMM-only, `w_G`는 C4 E2E의 GEMM 비중, `n_1`은 C1 non-GEMM / C4 E2E다.

| Model / context | C1/C4 GEMM-only | C4 GEMM 비중 | C1 GEMM / C4 E2E | C1 non-GEMM / C4 E2E | C1/C4 E2E |
| --- | ---: | ---: | ---: | ---: | ---: |
| Llama2 / 1k | 28.95 | 17.25% | 4.995 | 0.831 | 5.827 |
| Llama2 / 32k | 39.65 | 14.47% | 5.736 | 0.836 | 6.572 |
| Llama3 / 1k | 28.02 | 30.18% | 8.457 | 0.659 | 9.115 |
| Llama3 / 32k | 38.51 | 17.25% | 6.645 | 0.786 | 7.430 |

Llama2는 GEMM 기여 항이 4.995 → 5.736으로 늘고 non-GEMM 기여는 거의 유지된다. Llama3는 GEMM 기여가 8.457 → 6.645로 줄며 non-GEMM 기여 증가 0.659 → 0.786은 이를 상쇄하지 못한다. 따라서 E2E 추세가 반대가 된다.

**Llama3의 GEMM 비중이 더 빠르게 줄어드는 이유.** C4의 GEMM 시간을 G, non-GEMM 시간을 N으로 두면 비중은 `G / (G + N)`이다. 같은 모델의 1k 대비 32k 절대 시간 증가 배수는 다음과 같다.

| Model | C4 GEMM 시간 증가 | C4 non-GEMM 시간 증가 | C4 E2E 시간 증가 | GEMM 비중 유지 비율, 32k / 1k |
| --- | ---: | ---: | ---: | ---: |
| Llama2 | 74.65배 | 92.03배 | 89.03배 | 83.8% |
| Llama3 | 71.71배 | 148.64배 | 125.42배 | 57.2% |

GEMM의 증가 배수는 비슷하지만 non-GEMM은 Llama3에서 더 크게 증가한다. 두 모델의 softmax 절대 시간은 1k에서 거의 같고 32k에서도 약 0.5% 차이다. Llama3는 Hadamard 비용이 작은 상태에서 출발해 공통의 큰 softmax 비용이 더해지므로, non-GEMM 합의 증가 배수가 더 크다. Softmax 자체의 모델별 증가 속도가 크게 다른 것이 아니라, 초기 non-GEMM 구성과 크기의 차이다.

Llama2는 1k부터 큰 Hadamard 때문에 GEMM 비중이 낮아, 32k에서 그 비중의 상대 감소가 약 16.2%다. Llama3는 초기 GEMM 비중이 높고 softmax의 상대 영향이 더 크게 증가하여 약 42.8% 줄어든다. 두 모델의 GEMM-only 가속률 증가가 약 37%로 비슷해도, 곱해지는 GEMM 비중의 감소 폭 때문에 E2E 결과가 달라진다.

## 7. Llama3의 긴 Decode에서는 softmax가 GEMM 개선을 가려 C4의 상대 이득이 줄어든다.

**관찰.** Llama3 B=1에서 context=1k → 32k의 C1/C4 E2E는 34.89 → 19.91, C3/C4 E2E는 2.48 → 1.75로 감소한다. 같은 구간의 C1/C4 GEMM-only는 50.53 → 49.73로 거의 유지된다.

**원인.** Llama3 C4에서 softmax 비중은 5.16% → 50.52%로 늘고 GEMM 비중은 68.49% → 38.88%로 줄어든다. Decode의 query 길이는 1로 유지되어 projection·FFN shape는 context와 무관하고, attention·softmax는 KV 길이에 따라 커진다. Prefill의 seq² 설명을 Decode에 적용하지 않는다.

Llama3 B=1의 C4 전체 GEMM 시간은 1k → 32k에 1.41배, softmax는 24.30배, E2E는 2.48배다. Linear 고정 비용 때문에 전체 GEMM 증가가 작으며, softmax가 늘면서 GEMM 이득의 E2E 기여가 줄어든다. GQA는 attention GEMM 호출을 줄이지만 softmax는 query head 32개 전체에 적용한다.

Llama2 B=1은 GEMM 비중이 52.99% → 49.73%로 비교적 유지되고 C3/C4 E2E도 1.71 → 1.73로 거의 유지된다. 본 벤치마크에서 Llama2 attention GEMM 비용이 더 커, 긴 context에도 GEMM 가속이 E2E에 더 많이 남는다.

## 8. 큰 batch에서는 GEMM-only 이득이 있어도 E2E 이득은 작아진다.

**관찰.** 아래는 모델별로 같은 batch의 6개 context에 대한 C3/C4 E2E 비율의 기하평균이다. Batch=1 → 4 → 64에서 두 모델 모두 감소한다.

| Model | B=1 | B=4 | B=64 |
| --- | ---: | ---: | ---: |
| Llama2 | 1.717 | 1.416 | 1.298 |
| Llama3 | 2.171 | 1.614 | 1.110 |

Llama3 B=64, context=1k에서 C3/C4 GEMM-only는 1.236이지만 E2E는 1.026이다. C4가 C3보다 E2E에서 약 2.53% 빠르다. 이 절은 **context를 고정하고 batch만 늘리는 비교**다.

**원인.** Linear GEMM은 batch를 M에 합쳐 처리하고, attention은 batch만큼 호출 수를 늘리며, vector는 batch만큼 처리할 행·원소 수를 늘린다. 이 차이로 linear backend의 상대 이득과 E2E에서 GEMM이 차지하는 비중이 함께 줄어든다. Fused kernel의 non-GEMM 추가 비용도 남아 전체 이득을 더 줄인다.

**1. B=1 → 4: linear 측정 shape는 같고 attention·vector 작업만 증가한다.** Decode linear의 logical M은 batch지만, 현재 M alignment 정책에 따라 B=1과 B=4 모두 physical M=8에서 측정되어 같은 raw cycle을 재사용한다. Layer당 GEMM 호출 수도 같아 linear 시간은 두 후보 모두 유지된다. Attention은 Llama2 logical M=1, Llama3 M=4를 유지하고 호출 수를 `layers × batch × KV heads`로 늘리므로 합산 시간은 정확히 4배가 된다. Softmax 호출 수는 layer 수지만 내부의 batch×32 heads가 늘고 Hadamard 행 수도 늘어난다. [M alignment](../../../../tools/latency_bench/kernel_latency_canonicalization.yaml), [호출·shape 구성](../../../../tools/workload/gen_kernel_cfgs.py).

Llama3, context=1k에서 B=1 → 4의 C4 softmax 시간은 3.78배, Hadamard는 3.80배 증가한다. GEMM 비중은 68.49% → 42.55%로 줄어든다. Linear C3/C4는 3.26으로 그대로지만 E2E는 2.48 → 1.83로 줄어든다. 이 구간의 큰 감소는 가속된 linear의 시간 비중 감소로 설명된다.

**2. B=64: 작은 M에서 컸던 linear backend 차이도 좁혀진다.** 측정 M이 8 → 64로 커지며 동일 weight를 더 많은 입력 행에 적용한다. Llama3 linear 합은 C3에서 2.49배, C4에서 7.49배 증가하여 C3/C4는 3.26 → 1.09가 된다. Llama2도 C3 3.26배, C4 7.49배 증가로 2.49 → 1.09가 된다. C3의 작은 M에서 두드러지던 공급·제어 비용이 더 많은 행에 나뉘는 해석과 일치한다.

Rev4 raw DB의 Llama3 gate/up shape `N=14336, K=4096`에서 M=8의 cycle은 C3 8,153,085, C4 1,973,929이고 M=64에서는 C3 16,035,602, C4 14,782,086이다. 두 clock period는 10 ns이다. C3 시간은 약 1.97배, C4는 약 7.49배 증가하여 해당 shape의 C3/C4는 4.13 → 1.08로 좁혀진다. 이는 작은 M의 이득이 큰 M에 그대로 유지되지 않는 직접 근거다. 개별 stall·준비 단계의 cycle 분해는 포함되지 않아 특정 DMA stall로 원인을 한정하지 않는다. [C3 raw DB](../../outputs_llama3_main.th16_20261004_rev4_pipeline/C3/raw_db.csv), [C4 raw DB](../../outputs_llama3_main.th16_20261004_rev4_pipeline/C4/raw_db.csv).

**3. Linear의 batch 처리 이득이 vector에 동일하게 적용되지 않는다.** Llama3, context=1k에서 B=1 → 64의 C4 전체 GEMM 시간은 9.55배 증가하지만 softmax는 59.57배, Hadamard는 60.99배, non-GEMM 전체는 49.65배 증가한다. Vector는 sequence마다 필요한 score·activation을 처리하며, 동일 weight를 여러 행에 적용하는 linear의 이득을 같은 방식으로 얻지 못한다. 따라서 GEMM 비중이 68.49% → 29.49%로 줄어든다. Context는 1k로 고정되어 있다.

**4. 줄어든 GEMM 절감분에서 non-GEMM 추가 비용을 빼면 작은 E2E 이득만 남는다.** `r_G`는 C3/C4 GEMM-only, `w_G`는 C4 E2E GEMM 비중, `ΔN`은 C4 non-GEMM − C3 non-GEMM이다. `C3/C4 E2E = 1 + (r_G − 1) × w_G − ΔN / C4 total`로 분해할 수 있다. 아래는 Llama3, context=1k이며 절감·추가 비용은 각 batch의 C4 total을 100으로 둔 값이다.

| Batch | C3/C4 GEMM-only | C4 GEMM 비중 | C4 GEMM 절감 | C4 non-GEMM 추가 | C3/C4 E2E |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 3.205 | 68.49% | 151.01 | 2.92 | 2.481 |
| 4 | 3.056 | 42.55% | 87.48 | 4.70 | 1.828 |
| 64 | 1.236 | 29.49% | 6.95 | 4.35 | 1.026 |

B=64에서 GEMM 절감 6.95 중 non-GEMM 추가 4.35가 상쇄하여, 순절감은 C4 total 기준 2.60이다. Non-GEMM 추가 비용의 주된 항은 MLP Hadamard 2.43, KV quant K/V 합 0.98, softmax 0.39이다. 현재 rev4는 E2E 이득이 남으며 거의 동률로 해석하지 않는다. 이 비용은 fused/standalone 구현·실행 이미지 차이까지 포함한다.

**5. 모델 차이는 linear 이득에 대한 의존도와 attention 비용의 차이로 설명된다.** 이 Decode 실행 구성에서 Llama3는 attention 호출 수가 적어 attention 비용이 Llama2의 약 1/4이지만, softmax는 두 모델의 query head 32개를 모두 처리한다. 따라서 작은 batch의 큰 linear 이득이 batch 증가로 약 1.09배까지 좁혀지면 Llama3 E2E에서 vector가 더 크게 드러난다. Attention 자체의 C3/C4는 batch와 무관하게 유지되며 32k에서는 Llama2 2.52, Llama3 2.47이다.

Context=32k의 C4 GEMM 비중은 B=1 → 4 → 64에서 Llama2 49.73% → 43.16% → 41.86%, Llama3 38.88% → 24.36% → 20.60%다. 이에 따라 C3/C4 E2E는 Llama2 1.728 → 1.613 → 1.571, Llama3 1.748 → 1.386 → 1.197로 감소한다. Batch 증가 추세는 **linear backend 차이 축소, GEMM 비중 감소, 남아 있는 fused kernel 추가 비용**의 결합이다.

# llama_energy_per_token_power_fpga_dequant_dynamic_W_no_area_norm_gemm_layout_vector_stacked

[분석 figure](../../figure_output.th16_20261004_rev4_pipeline/llama_energy_no_area_norm_gemm_layout_vector_stacked/llama_energy_per_token_power_fpga_dequant_dynamic_W_no_area_norm_gemm_layout_vector_stacked.png)

Energy는 kernel별 실행 시간에 effective power를 곱해 합산한 것이다. Prefill은 B×seq, Decode는 B×128로 나눠 token당 energy를 구한다. `power_fpga_dequant_dynamic_W`는 모든 kernel에 dynamic power만 적용하는 모드가 아니다.

- 일반 GEMM/vector/layout kernel: `시간 × (PCIe run power − PCIe idle power + 고정 idle 5.5506 W)`.
- Standalone dequantization kernel: `시간 × (PCIe run power − PCIe idle power) × pure-dequant 보정계수`. Weight는 0.48263, KV-K/V는 0.28516이다.

고정 idle은 FPGA 내부 rail 기준의 추정값이다. 이 지표를 PCIe 전체 보드 energy 또는 모든 kernel의 순수 dynamic energy로 해석하지 않는다. 같은 workload의 후보 비교에서는 공통 token 수가 상쇄된다. [Power·보정 정책](../../prepare.py).

## 9. Prefill에서는 Llama3의 작은 latency 불이익도 power 감소로 상쇄되어 두 모델 모두 C4 energy가 작다.

**관찰.** 6개 Prefill 지점의 C3/C4 energy는 Llama2 1.035–1.056, Llama3 1.013–1.021로 모두 1보다 크다. Llama2는 latency도 C4가 조금 빠르고, Llama3는 C4 latency가 더 높아도 energy는 약 1.31–2.09% 작다.

| Model / context | C3/C4 E2E latency | C3/C4 energy | C3/C4 평균 effective power |
| --- | ---: | ---: | ---: |
| Llama2 / 1k | 1.015 | 1.056 | 1.040 |
| Llama2 / 32k | 1.002 | 1.035 | 1.033 |
| Llama3 / 1k | 0.980 | 1.014 | 1.035 |
| Llama3 / 32k | 0.983 | 1.020 | 1.037 |

**원인.** C3/C4는 standalone dequantization이 없고 같은 kernel 범위를 합산하므로 `energy = total time × 시간으로 가중한 평균 effective power`로 비교할 수 있다. `(C3/C4 energy) / (C3/C4 latency)`가 평균 effective power 비율이다. 위 네 지점에서 이 비율은 약 1.033–1.040, 즉 C4 평균 effective power가 약 3.2–3.9% 낮다.

Llama3 1k의 C4 latency 불이익은 약 2.00%, 32k는 약 1.73%다. Power 감소가 이를 상쇄하여 energy는 각각 약 1.41%, 1.93% 줄어든다. 이는 해당 workload·power 모드에서 실행 시간으로 가중한 결과이며 모든 순간이나 모든 stage의 C4 power가 낮다는 뜻은 아니다.

실제로 Llama3 Decode B=1, 1k는 C3/C4 E2E 2.481, energy 2.361이고 평균 effective power C3/C4는 0.952이다. 이 지점에서는 C4의 평균 effective power가 더 높아 energy 이득이 latency 이득보다 작다. Prefill의 power 감소를 Decode 전체에 적용하지 않는다.

## 10. Decode에서는 C1의 weight dequantization이 보이고, 긴 context·큰 batch에서는 KV dequantization 비중이 커진다.

**관찰.** B=1, 1k에서 C1 energy의 weight dequant 비중은 Llama2 9.98%, Llama3 10.64%다. 같은 지점의 C1/C4 energy는 28.00, 36.89로, E2E latency의 26.02, 34.89보다 크다.

Llama2 B=1, 1k → 32k의 C1 weight 비중은 9.98% → 4.01%, KV는 0.31% → 3.84%다. Llama3는 weight 10.64% → 7.64%, KV 0.08% → 1.75%다. B=64, 32k의 C1 KV 비중은 Llama2 5.94%, Llama3 5.20%다. C2에도 attention용 KV dequant가 있지만 C3/C4의 두 dequant stack은 0이다.

**원인.** C1의 FP TCU 경로는 quantized weight/KV를 standalone kernel로 변환하며 C2는 attention의 KV 변환을 사용한다. C3/C4는 FP–INT GEMM 경로에서 처리하여 별도 dequant kernel이 없다. Dequant stack이 0인 것은 관련 비용 전체가 없다는 뜻이 아니라 별도 kernel로 분리되지 않는다는 뜻이다.

Weight 크기는 context와 무관하지만 KV는 context와 batch에 따라 증가한다. Batch가 커지면 한 forward의 weight 관련 비용을 더 많은 출력 token에 나눌 수 있지만 sequence별 KV는 각각 처리해야 한다. 따라서 energy 구성은 긴 context·큰 batch에서 KV dequant 쪽으로 이동한다. Latency figure는 standalone dequant를 제외하므로 C1/C2의 energy와 latency 비율 차이를 같은 kernel 범위의 power 차이만으로 설명하지 않는다.

## 11. 이 power 모드에서도 큰 batch·긴 context의 C4 energy는 vector 비용에 제한된다.

**관찰.** B=64, 32k에서 C4 energy의 vector 비중은 Llama2 54.52%, Llama3 76.46%다. GEMM-only 이득만큼 큰 E2E·energy 이득은 나오지 않는다.

| Model / context / batch | C3/C4 GEMM-only | C3/C4 E2E latency | C3/C4 energy | C4 energy GEMM 비중 | C4 energy vector 비중 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Llama2 / 32k / B64 | 2.440 | 1.571 | 1.596 | 44.24% | 54.52% |
| Llama3 / 32k / B64 | 2.195 | 1.197 | 1.241 | 21.95% | 76.46% |

**원인.** 이 모드는 dequant를 제외한 일반 GEMM/vector kernel에 고정 idle 5.5506 W를 더한다. 오래 실행되는 vector는 dynamic power가 낮더라도 실행 시간 동안 idle 성분을 계속 누적한다. 특히 Llama3 B=64, 32k의 softmax 시간 비중은 68.86%여서 GEMM 개선만으로 energy 전체를 크게 줄이기 어렵다.

이 지점의 C3/C4 평균 effective power 비율은 Llama2 1.016, Llama3 1.036이다. C4의 낮은 평균 power가 latency 이득에 더해져 energy 이득을 조금 키우지만, vector 실행 시간이 큰 구조를 없애지는 않는다. 추가 개선은 GEMM과 vector의 실제 실행 시간·effective power를 함께 줄이는 방향으로 해석한다. 표시된 작은 layout stack만으로 fused kernel 전체 비용이 작다고 판단하지 않는다.
