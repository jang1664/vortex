# 분석할 figure 목록
llama_gemm_only_no_area_norm
llama_e2e_no_area_norm_stacked
llama_energy_no_area_norm_gemm_layout_vector_stacked/llama_energy_per_token_power_fpga_dequant_dynamic_W_no_area_norm_gemm_layout_vector_stacked.*

분석 대상은 `th16_20261004_rev3_pipeline`의 figure와 2026-10-04 energy 재생성 후의 prepared CSV다. 다른 실험 태그의 수치는 섞지 않았다. 아래 비율은 같은 model/stage/batch/context에서의 `비교 후보 값 / C4 값`이다. C4 막대의 합은 항상 1이며, 비율이 클수록 C4가 유리하다. 서로 다른 context의 상대 막대 높이만으로 절대 latency나 energy가 감소한다고 해석하지 않는다.

수치 근거는 [Llama2 prepared manifest](../../figure_prepare.th16_20261004_rev3_pipeline/prepare_manifest.llama2_7b.json)와 [Llama3 prepared manifest](../../figure_prepare.th16_20261004_rev3_pipeline/prepare_manifest.llama3_8b.json)에 기록된 GEMM-only, E2E name/backend, 해당 power 모드의 energy name/backend CSV다. Component 비중과 후보 비율은 figure와 같은 stack 분해·C4 정규화 방식으로 계산했다.

| 후보 | 구성 |
| --- | --- |
| C1 | Linear와 attention 모두 FP TCU |
| C2 | Linear는 naive FP–INT, attention은 FP TCU; C1/C3 실행 결과를 합성 |
| C3 | Linear와 attention 모두 naive FP–INT |
| C4 | Linear와 attention 모두 improved FP–INT, vector kernel은 fused-layout 경로 |

Prefill은 B=1, context=1k–32k의 6개 지점이며, Decode는 B=1/4/64와 context=1k–32k의 18개 지점이다. 두 모델은 각각 32 layers, hidden=4096, query heads=32, head dimension=128이다. Llama2는 KV heads=32, FFN dimension=11008이고, Llama3는 KV heads=8, FFN dimension=14336이다. [모델과 attention geometry 정의](../../../../tools/workload/gen_kernel_cfgs.py).

Latency는 kernel의 FPGA cycle에 호출 수를 적용한 합성 값이다. Prefill은 TTFT, Decode는 출력 128 step의 합을 128로 나눈 배치 단위 TPOT이며, host 실행 시간은 포함하지 않는다. Latency에는 standalone weight/KV dequantization을 포함하지 않고, energy에는 Prefill의 weight dequantization과 Decode의 weight/KV dequantization을 포함한다. 세 figure 모두 면적 정규화를 적용하지 않는다. [집계 및 포함 정책](../../prepare.py).

`layout` stack은 별도의 DMA 시간 측정값이 아니다. 각 C4 fused kernel과 C3의 대응 standalone kernel 차이 중 양수만 합산한 값이며, 음수 차이는 다른 kernel의 양수 비용을 상쇄하지 않는다. 구현·이미지·전력 차이도 포함될 수 있어 순수 layout 변환 비용과 동일시하지 않는다. [stack 분해 코드](../../plot.py).

rev3 실행 이미지의 softmax 기능 검증 이슈와 prefill 1k의 fused softmax overhead 예외는 [기존 진단 문서](../debug/SUMMARY.md)에 남아 있다. 아래는 해당 이미지에서 관찰된 성능 경향이며, 기능 검증 완료를 의미하지 않는다.

# llama_gemm_only 분석

## 1. prefill에서 seq가 길어지면 C4가 더 좋아진다.

**관찰.** seq가 길어지면서 C4가 C1~C3에 비해 점점 좋아지는 경향을 보인다. C3 대비 이득도 두 모델의 6개 context에서 모두 증가한다.

| Model | C1/C4, 1k → 32k | C2/C4, 1k → 32k | C3/C4, 1k → 32k |
| --- | --- | --- | --- |
| Llama2 | 28.92 → 39.63 | 2.38 → 26.36 | 1.066 → 1.146 |
| Llama3 | 28.01 → 38.51 | 2.29 → 25.55 | 1.067 → 1.144 |

**원인.** Projection/FFN의 행 수는 seq에 비례하지만, Prefill attention의 QKᵀ/PV는 Q와 KV 길이가 함께 늘어 연산량이 대략 seq²에 비례한다. C4 GEMM 합에서 attention 비중은 Llama2에서 4.44% → 59.04%, Llama3에서 4.14% → 57.22%로 커진다. 긴 seq일수록 attention backend의 차이가 전체 GEMM latency에 더 크게 반영된다.

C3/C4를 component별로 보면 Prefill linear 합의 비율은 약 1.06이고 attention 합은 약 1.21이다. seq가 길어질 때 상대적으로 이득이 큰 attention의 비중이 늘어나므로, 전체 C3/C4도 1.07 부근에서 1.15 부근으로 증가한다. C2는 attention에 FP TCU를 그대로 사용하므로 이 효과가 더 크다. C2의 linear 가속만으로는 긴 seq의 attention 비용을 줄이지 못한다.

FP TCU와 FP–INT의 비교에는 operand 표현도 포함된다. C1/C2 attention은 변환된 FP16 KV를 사용하고, C3/C4는 packed INT4 KV를 FP–INT 경로로 처리한다. 압축된 operand의 메모리 전송량과 backend의 공급·연산 경로가 함께 달라지므로, 큰 C1/C2 대비 이득을 하나의 RTL 최적화나 압축률만으로 설명하지 않는다.

## 2. Decode에서는 C4의 C3 대비 GEMM 이득이 Prefill보다 크다.

**관찰.** B=1, context=1k에서 C3/C4는 Llama2 2.34, Llama3 3.17이다. 같은 context의 Prefill은 두 모델 모두 약 1.07이다. 특히 Decode linear 합의 C3/C4는 Llama2 약 2.45, Llama3 약 3.23으로, Prefill linear의 약 1.06보다 크다.

**원인.** Prefill linear의 M은 B×seq이고, Decode linear의 M은 B다. B=1 Decode에서는 큰 weight를 매우 적은 입력 행에 적용하므로 weight 공급, tile 준비, 명령 발행 등의 비용을 많은 행에 나누기 어렵다. Prefill과 Decode는 같은 backend라도 다른 실행 구간이다.

C3는 LMEM 기반 operand 경로, C4는 전용 TMEM 기반 operand 경로와 scheduling을 사용한다. 작은 M에서 이러한 공급·제어 경로의 차이가 상대적으로 크게 드러난다는 해석은 실제 component 비율과 일치한다. 다만 rev3 figure에는 stall counter나 waveform이 없으므로 특정 DMA stall을 직접 원인으로 확정하지는 않는다. 특히 현재 C3에는 `GEMM_NAIVE_USE_ACC_MEM`이 켜져 있어, 과거 naive의 LMEM PSUM 병목을 그대로 이번 원인으로 적용하면 안 된다. [C3 설정](../../../../configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh), [C4 설정](../../../../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh).

## 3. Decode batch가 커지면 짧은 context의 C4 이득은 줄고, 긴 context에서는 attention 가속이 이득을 유지한다.

**관찰.** Context=1k에서 B=1 → 64로 늘리면 C3/C4가 Llama2 2.34 → 1.43, Llama3 3.17 → 1.23으로 감소한다. 반면 B=64에서 context를 1k → 32k로 늘리면 각각 1.43 → 2.37, 1.23 → 2.19로 증가한다.

**원인.** Batch 증가는 linear의 M을 키워 weight와 제어 비용을 여러 행에 나누게 한다. B=64에서는 두 모델 모두 linear 합의 C3/C4가 약 1.086으로 좁혀진다. 그러나 attention은 batch를 GEMM M에 합치는 대신 호출 수에 반영한다. Llama2의 attention M=1, Llama3의 attention M=4는 B가 커져도 유지된다.

긴 context에서는 KV 길이가 늘어 attention의 N 또는 K가 커진다. B=64, 32k에서 C4 GEMM 중 attention 비중은 Llama2 94.54%, Llama3 80.01%이며, attention 자체의 C3/C4는 각각 약 2.45, 2.46이다. 따라서 linear의 이득이 작아져도 attention 가속이 전체 이득을 유지한다. [Decode attention shape와 호출 구성](../../../../tools/workload/gen_kernel_cfgs.py).

## 4. Llama3의 짧은 Decode는 Llama2보다 FFN 비중이 높다.

**관찰.** B=1, context=1k에서 C4 GEMM의 FFN 비중은 Llama2 57.00%, Llama3 77.27%다. Attention 비중은 각각 13.98%, 3.63%다. 같은 지점의 C3/C4는 Llama3가 더 크다.

**원인.** Llama3의 FFN dimension은 14336으로 Llama2의 11008보다 크다. 반면 Decode attention은 GQA로 KV를 공유하는 query head 4개를 M=4에 묶고, KV head 8개 단위로 호출한다. Llama2는 M=1, KV head 32개 단위다. 이 구성은 KV와 실행 준비 비용의 재사용을 늘리고 head별 호출 수를 줄인다. Query head 수는 같으므로 attention 산술 연산량이 무조건 1/4이 된다는 뜻은 아니다.

결과적으로 Llama3의 짧은 Decode는 FFN 성능 차이를 더 강하게 반영한다. 긴 context에서는 attention 비중이 다시 커지며, Llama3 B=1의 C3/C4는 1k의 3.17에서 32k의 2.99로 조금 줄어든다.

Llama3는 Prefill에서도 query head 32개가 KV head 8개를 공유하는 GQA다. 다만 현재 workload generator는 Prefill의 QKᵀ와 PV를 query head별 M=seq_q인 GEMM으로 구성하고, layer·batch당 각각 32회 호출로 집계한다. Decode에서는 같은 KV head를 공유하는 query head 4개를 M=4에 묶어 QKᵀ와 PV를 각각 8회로 집계한다. 따라서 Prefill에서도 GQA의 KV 공유는 유지되지만, 이 벤치마크의 Decode에서 사용하는 query head 묶음에 따른 GEMM 호출 수 감소를 Prefill에 그대로 적용할 수는 없다. [Attention GEMM shape와 호출 수 구성](../../../../tools/workload/gen_kernel_cfgs.py).

# llama_e2e_no_area_norm_stacked 분석

## 5. Prefill에서는 GEMM 개선이 vector·layout 비용에 상쇄되어 C3와 C4가 비슷하거나 C4가 느리다.

**관찰.** GEMM-only는 모든 Prefill 지점에서 C4가 빠르지만, E2E는 12개 지점 중 10개에서 C4가 C3보다 느리다. Llama2의 C3/C4는 0.991–1.002로 거의 같고, Llama3는 0.947–0.971이다. Llama3의 C4 TTFT는 C3보다 약 2.95–5.61% 높다.

**원인.** Prefill C4의 GEMM 비중은 Llama2 약 14–17%, Llama3 약 17–29%다. 나머지 대부분은 vector와 fused kernel 비용이어서, GEMM을 개선해도 전체 latency 절감 폭은 제한된다. 실제 backend별 component를 합산하면 C4의 non-GEMM 증가분이 GEMM 절감분보다 크다.

아래 값은 각 워크로드의 **C4 E2E total을 100으로 둔 비용 차이**다. non-GEMM은 vector와 layout의 합이며, 표시된 layout stack만 따로 비교한 값이 아니다.

| Model / context | C3 → C4 GEMM 절감 | C3 → C4 non-GEMM 증가 | C4 total − C3 total |
| --- | ---: | ---: | ---: |
| Llama2 / 1k | 1.12 | 1.64 | +0.51 |
| Llama2 / 32k | 2.09 | 3.02 | +0.93 |
| Llama3 / 1k | 1.94 | 7.25 | +5.31 |
| Llama3 / 32k | 2.45 | 5.32 | +2.87 |

따라서 Prefill에서 C4의 GEMM-only 개선을 그대로 TTFT 개선율로 쓰면 안 된다. Fused kernel의 비용에는 layout뿐 아니라 standalone과 다른 구현·실행 이미지의 영향도 들어 있다.

## 6. Prefill의 vector 병목은 짧은 context의 MLP Hadamard에서 긴 context의 softmax로 이동한다.

**관찰.** C4 E2E total에서 `spinquant_r4_mlp_hadamard`가 차지하는 비중은 1k에서 Llama2 63.24%, Llama3 43.06%다. 32k에서는 이 비중이 22.92%, 11.33%로 줄고, `attn_softmax`가 각각 58.69%, 67.93%를 차지한다. 비중 감소는 Hadamard의 절대 실행 시간이 감소했다는 뜻이 아니다.

**원인.** MLP Hadamard는 고정된 FFN dimension을 seq에 비례하는 행 수에 적용한다. Softmax는 각 query에 대해 KV 전체를 처리하므로 Prefill 작업 크기가 seq²에 비례한다. 긴 context에서는 softmax가 Hadamard보다 더 빠르게 커진다.

Hadamard의 모델별 차이는 dimension의 분해 방식과도 관련된다. Llama2는 11008=172×64, Llama3는 14336=28×512로 factorized transform을 구성한다. Fused kernel은 butterfly 뒤에 base matrix transform을 수행하므로 base dimension 172와 28은 서로 다른 작업량을 만든다. 따라서 FFN dimension이 더 큰 Llama3가 Hadamard에서도 반드시 더 느리다고 볼 수 없다. [factor 선택](../../../../tools/workload/gen_kernel_cfgs.py), [fused Hadamard의 base transform](../../../../tests/regression/hadamard_layout_fused/kernel.cpp).

이 병목 구성 때문에 두 모델의 C1 대비 E2E 추세도 다르다. 1k → 32k에서 C1/C4는 Llama2 5.70 → 6.50으로 증가하지만 Llama3 8.80 → 7.35로 감소한다. GEMM-only 이득은 두 모델 모두 커져도, 전체 분모에 포함되는 Hadamard·softmax 비중이 달라 E2E 추세는 같지 않다.

**C1 대비 E2E 추세가 반대인 원인.** 이를 수치로 분해하면 `C1/C4 E2E = r_G × w_G + n_1`이다. 여기서 `r_G`는 C1/C4 GEMM-only 비율, `w_G`는 C4 E2E에서 GEMM의 시간 비중, `n_1`은 C1 non-GEMM 시간을 C4 E2E total로 나눈 값이다. Non-GEMM에는 vector와 fused kernel의 layout 비용을 포함한다. 즉, GEMM-only 비율이 증가하더라도 그 비율에 곱해지는 GEMM 비중이 더 크게 줄면 E2E 비율은 감소할 수 있다.

아래의 두 기여 항은 각각 **C4 E2E total을 1로 둔 C1의 비용**이며, 그 합이 C1/C4 E2E다.

| Model / context | GEMM-only 비율 `r_G` | C4 GEMM 비중 `w_G` | GEMM 기여 `r_G × w_G` | non-GEMM 기여 `n_1` | C1/C4 E2E |
| --- | ---: | ---: | ---: | ---: | ---: |
| Llama2 / 1k | 28.92 | 16.89% | 4.884 | 0.815 | 5.699 |
| Llama2 / 32k | 39.63 | 14.31% | 5.673 | 0.827 | 6.499 |
| Llama3 / 1k | 28.01 | 29.13% | 8.161 | 0.636 | 8.797 |
| Llama3 / 32k | 38.51 | 17.06% | 6.571 | 0.776 | 7.347 |

Llama2는 1k부터 MLP Hadamard가 C4 total의 63.24%를 차지해 GEMM 비중이 이미 낮다. 긴 context에서 softmax가 주 병목이 되더라도 GEMM 비중의 상대 감소는 약 15.2%에 그친다. 반면 attention 비중 증가에 따른 GEMM-only 비율 상승은 약 37.0%다. 두 효과를 곱한 GEMM 기여 항은 4.884 → 5.673으로 증가하고, non-GEMM 기여 항은 거의 유지되어 E2E 비율도 증가한다.

Llama3는 1k에서 Hadamard 비중이 더 작고 FFN dimension은 더 커서, GEMM이 C4 total의 29.13%를 차지한다. 따라서 짧은 context에서는 GEMM 가속이 E2E에 더 크게 반영된다. 그러나 context가 길어지면 query head 32개 전체에 적용되는 softmax 비용이 seq²에 따라 커지고, softmax 비중이 13.71% → 67.93%로 증가한다. GQA의 KV head 공유가 softmax 대상 query head 수를 줄이지는 않는다. 이때 GEMM 비중의 상대 감소 약 41.4%가 GEMM-only 비율 상승 약 37.5%와 결합하여 GEMM 기여 항을 8.161 → 6.571로 낮춘다. Non-GEMM 기여 항은 0.636 → 0.776으로 늘지만 이를 상쇄하기에는 작아, E2E 비율은 감소한다.

**Llama3에서 GEMM 비중이 더 빠르게 줄어드는 이유.** C4의 GEMM 시간을 `G`, non-GEMM 시간을 `N`으로 두면 GEMM 비중은 `G / (G + N)`이다. 따라서 비중의 감소 폭은 GEMM 가속률보다 **같은 후보 안에서 N이 G보다 얼마나 빠르게 증가하는지**에 의해 결정된다. Prepared `total.csv`의 절대 시간에 component 비중을 적용하면 다음 증가 배수가 나온다. 각 배수는 같은 모델의 1k 대비 32k 시간 비율이다.

| Model | C4 GEMM 시간 증가 | C4 non-GEMM 시간 증가 | C4 E2E 시간 증가 | GEMM 비중의 유지 비율, 32k / 1k |
| --- | ---: | ---: | ---: | ---: |
| Llama2 | 74.65배 | 90.78배 | 88.06배 | 84.8% |
| Llama3 | 71.71배 | 143.30배 | 122.44배 | 58.6% |

GEMM 시간의 증가 배수는 두 모델이 비슷하지만, non-GEMM의 증가 배수는 Llama3가 훨씬 크다. 이 차이의 주된 원인은 **작은 Hadamard 비용에서 출발해, 두 모델에 거의 동일한 softmax 비용이 추가되는 구조**다. C4의 MLP Hadamard 시간은 Llama3가 Llama2의 약 42.4%로 시작하고 32k에서도 약 42.8%다. 반면 softmax의 절대 시간은 두 context 모두 모델 간 차이가 약 0.2% 이내이며, 1k → 32k 증가 배수도 각각 약 606배로 거의 같다. 따라서 Llama3에서 softmax 비중이 더 빠르게 커지는 것은 softmax 자체의 증가 속도가 더 빨라서가 아니라, 처음의 Hadamard 중심 non-GEMM 비용이 더 작기 때문이다.

Hadamard 비용 차이는 factorized transform의 base matrix 계산으로 설명할 수 있다. 이 계산은 row마다 `width × base_k² = FFN dimension × base_k`에 비례하는 누산을 수행한다. Llama2의 `64 × 172²`는 Llama3의 `512 × 28²`보다 약 4.72배 크다. Butterfly·메모리 접근·실행 overhead도 포함되므로 이 연산량 비율을 전체 kernel latency 비율로 해석하지는 않는다. 실제 C4 Hadamard 시간은 Llama2가 Llama3의 약 2.3–2.4배다. 두 모델 모두 Hadamard 시간은 context에 거의 비례해 약 32배 증가하므로, Llama2의 큰 Hadamard 비용이 non-GEMM 합에서 seq² 성격의 softmax 증가가 차지하는 비중을 낮춘다. [Base matrix 계산 루프](../../../../tests/regression/hadamard_layout_fused/kernel.cpp).

GEMM 쪽도 이 해석과 일치한다. C4 linear 시간은 두 모델 모두 약 32배, attention GEMM 시간은 약 992배 증가한다. 현재 Prefill workload는 두 모델 모두 query head별 QKᵀ/PV를 구성하므로, 동일 context의 attention GEMM 합산 시간도 두 모델이 사실상 같다. Llama3의 linear 시간은 Llama2보다 약 7.7% 크지만 context에 선형으로 늘어난다. 긴 context에서 공통의 attention·softmax 비용이 커지면서, 짧은 context의 FFN·Hadamard 구성 차이가 전체에서 차지하는 비중은 줄어든다. 그 결과 Llama3는 처음의 높은 GEMM 비중이 더 크게 내려가고, Llama2는 이미 Hadamard 때문에 낮았던 GEMM 비중이 상대적으로 덜 내려간다.

따라서 두 모델의 차이는 **짧은 context에서 시작하는 GEMM 비중과, softmax 병목으로 이동하면서 그 비중이 줄어드는 폭**으로 설명된다. 실제 non-GEMM 전체의 C1/C4 시간 비율은 이 네 지점에서 약 0.90–0.98로, GEMM의 약 28–40배와 큰 차이가 있다. Softmax·Hadamard 비중이 커질수록 GEMM에서 얻은 가속이 E2E에 반영되는 비중이 작아진다.

## 7. Llama3의 긴 Decode에서는 softmax가 GEMM 개선을 가려 C4의 상대 이득이 줄어든다.

**관찰.** Llama3 B=1에서 context=1k → 32k로 늘리면 C1/C4 E2E는 34.18 → 19.67, C3/C4 E2E는 2.45 → 1.74로 감소한다. 같은 구간의 C1/C4 GEMM-only는 49.63 → 48.93으로 거의 유지된다.

**원인.** Llama3 C4에서 softmax 비중이 5.96% → 50.49%로 증가하고, 전체 GEMM 비중은 68.29% → 39.04%로 감소한다. Decode linear는 context에 따라 shape가 변하지 않지만, attention과 softmax는 KV 길이에 따라 커진다. GQA는 attention의 KV 재사용과 head별 호출 구성에는 도움을 주지만, softmax는 query head 32개 전체에 대해 수행한다. 긴 context에서 GQA로 줄어든 attention 비용보다 softmax 비용이 상대적으로 더 크게 드러나는 구조다.

Llama2 B=1에서는 같은 구간에 GEMM 비중이 54.10% → 50.65%로 유지되고 C3/C4 E2E도 1.71 부근이다. MHA attention의 비용이 더 커서, 긴 context에서도 GEMM backend 개선이 E2E에 더 많이 반영된다.

## 8. 큰 batch에서는 GEMM-only 이득이 있어도 E2E 이득은 작아진다.

**관찰.** 6개 context에 대한 C3/C4 비율의 기하평균은 batch가 커질수록 감소한다.

| Model | B=1 | B=4 | B=64 |
| --- | ---: | ---: | ---: |
| Llama2 E2E | 1.710 | 1.454 | 1.282 |
| Llama3 E2E | 2.148 | 1.578 | 1.093 |

Llama3 B=64, 1k에서는 GEMM-only가 1.23이지만 E2E는 0.9998로 사실상 동률이다. 이 작은 차이로 두 후보의 우열을 일반화하지 않는다.

**원인.** 같은 context에서 batch만 늘리면, linear GEMM은 batch를 M에 합쳐 처리하지만 attention은 batch만큼 호출 수를 늘리고 vector는 batch만큼 처리할 행·원소 수를 늘린다. 이 차이로 GEMM 자체의 C3/C4 이득이 좁혀지는 동시에, C4 E2E에서 GEMM의 비중도 낮아진다. 여기에 C4 fused kernel의 non-GEMM 추가 비용이 남아 전체 이득을 더 줄인다. 아래는 context를 고정한 batch 비교다.

**1. B=1 → 4에서는 linear의 측정 shape가 같지만 attention·vector 작업은 증가한다.** Decode의 query 길이는 1이므로 projection·FFN GEMM은 `M=batch`, 호출 수는 layer 수다. 다만 FP–INT GEMM의 latency canonicalization은 M을 8의 배수로 올림한다. 따라서 B=1과 B=4의 logical M은 달라도, 실제 측정 M은 모두 8이며 동일한 raw 측정값을 재사용한다. 두 후보 모두 이 구간에서 linear 합산 시간이 같다. 이것은 측정 shape의 재사용에 따른 결과다. [M alignment 정책](../../../../tools/latency_bench/kernel_latency_canonicalization.yaml).

Attention은 batch를 M에 합치지 않는다. Llama2는 M=1, Llama3는 query head 4개를 묶은 M=4를 유지하고, 호출 수를 `layers × batch × KV heads`로 늘린다. 따라서 같은 context에서 B=1 → 4 → 64이면 attention 합산 시간도 정확히 1 → 4 → 64배다. Softmax는 호출 수가 layer 수로 유지되지만 한 호출에서 batch×32 query heads를 처리하며, MLP Hadamard도 batch만큼 행 수가 늘어난다. 서로 다른 batch의 vector는 logical 작업 크기가 달라 별도로 측정한다. [Linear·attention·softmax 구성](../../../../tools/workload/gen_kernel_cfgs.py).

실제로 Llama3, context=1k에서 B=1 → 4이면 C4 linear 시간은 그대로인데 softmax는 3.82배, MLP Hadamard는 4.01배 증가한다. C4 total에서 linear 비중은 65.82% → 36.14%로 줄고, 전체 GEMM 비중도 68.29% → 41.58%로 줄어든다. 이때 linear 자체의 C3/C4는 3.23으로 같고 GEMM 전체의 C3/C4도 3.17 → 3.03으로 조금만 줄지만, E2E는 2.45 → 1.77로 크게 내려간다. 이 구간의 주된 원인은 가속된 linear의 시간 비중 감소다.

**2. B=64에서는 작은 M에서 컸던 linear backend 차이도 좁혀진다.** 측정 M이 8 → 64가 되어 같은 weight를 더 많은 입력 행에 적용한다. Llama3 linear 합은 B=1 대비 C3에서 2.47배, C4에서 7.35배 증가하므로, linear C3/C4는 3.23 → 1.09로 좁혀진다. Llama2도 C3는 3.25배, C4는 7.32배 증가하여 2.45 → 1.09가 된다. Batch가 커지면서 C3가 작은 M에서 부담하던 공급·제어 비용이 더 많은 행에 나뉘고, 두 후보의 차이가 줄어드는 해석과 일치한다.

Raw DB의 Llama3 gate/up shape `N=14336, K=4096`에서도 이를 확인할 수 있다. M=8의 FPGA cycle은 C3 8,210,134, C4 2,008,176이지만 M=64에서는 C3 16,040,060, C4 14,782,073이다. 두 후보의 clock period는 모두 10 ns다. 동일 weight dimension에서 C3 시간은 약 1.95배, C4는 약 7.36배 증가하며, 이 shape의 C3/C4는 4.09 → 1.09가 된다. 작은 M의 큰 차이가 큰 M까지 유지되지 않는다는 직접적인 근거다. 구체적인 stall 종류나 준비 비용의 cycle별 분해는 이 raw DB에 없으므로, 특정 DMA stall로 원인을 한정하지 않는다. [C3 raw DB](../../outputs_llama3_main.th16_20261004_rev3_pipeline/C3/raw_db.csv), [C4 raw DB](../../outputs_llama3_main.th16_20261004_rev3_pipeline/C4/raw_db.csv).

**3. Linear의 batch 처리 이득이 vector에 동일하게 적용되지 않아 GEMM 비중도 감소한다.** Llama3, context=1k에서 B=1 → 64이면 C4 linear는 7.35배, 전체 GEMM은 9.41배 증가한다. 그러나 softmax는 60.99배, MLP Hadamard는 61.45배, non-GEMM 전체는 50.19배 증가한다. Vector는 batch마다 필요한 query score와 activation을 처리하므로, linear처럼 하나의 weight를 여러 입력 행에 적용하는 이득을 동일하게 얻지 못한다. 그 결과 GEMM 비중은 68.29% → 28.76%로 감소하고, MLP Hadamard 비중은 11.91% → 32.77%, softmax 비중은 5.96% → 16.27%로 증가한다. 이 비교에서는 context를 1k로 유지했으며 seq² 증가가 원인이 아니다.

**4. 작아진 GEMM 절감분이 C4의 non-GEMM 추가 비용에 상쇄된다.** `r_G`를 C3/C4 GEMM-only 비율, `w_G`를 C4 E2E의 GEMM 비중, `ΔN`을 C4 non-GEMM 시간에서 C3 non-GEMM 시간을 뺀 값으로 두면 `C3/C4 E2E = 1 + (r_G − 1) × w_G − ΔN / C4 total`이다. 다음은 Llama3, context=1k의 비용 분해다. 절감·추가 비용은 각 batch의 C4 total을 100으로 둔 값이다.

| Batch | C3/C4 GEMM-only `r_G` | C4 GEMM 비중 `w_G` | C4 GEMM 절감 | C4 non-GEMM 추가 | C3/C4 E2E |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 3.174 | 68.29% | 148.44 | 3.77 | 2.447 |
| 4 | 3.027 | 41.58% | 84.29 | 7.67 | 1.766 |
| 64 | 1.233 | 28.76% | 6.71 | 6.73 | 0.9998 |

B=64의 non-GEMM 추가 비용 6.73 중 softmax가 3.17, MLP Hadamard가 2.11을 차지한다. 둘만으로 추가 비용의 약 78%다. 전체 GEMM에서는 여전히 C4가 약 1.23배 빠르지만, E2E 기준 절감은 6.71에 그쳐 non-GEMM 추가 비용 6.73과 거의 상쇄된다. 이 차이는 실제 fused/standalone kernel·실행 이미지의 시간 차이이며, plot의 layout stack을 순수 layout 변환 시간으로 해석하지 않는다.

**5. Llama3는 batch 증가로 약해지는 linear 이득에 더 크게 의존한다.** 같은 context에서 Llama3의 Decode attention GEMM 시간은 이 GQA 실행 구성에서 Llama2의 약 1/4이지만, 두 모델의 softmax 시간은 거의 같다. 따라서 작은 batch에서 Llama3의 큰 이득을 만들던 linear가 batch 증가로 1.09배 수준에 가까워지면, 그 자리를 vector 비용이 더 크게 차지한다. 반면 attention의 C3/C4는 batch가 커져도 동일 context에서 유지된다. 32k에서는 Llama2 약 2.45, Llama3 약 2.46이다.

이를 반영해 context=32k의 C4 GEMM 비중은 B=1 → 4 → 64에서 Llama2 50.65% → 44.23% → 42.52%, Llama3 39.04% → 24.38% → 20.65%다. Llama2는 attention 이득이 E2E에 더 많이 남아 C3/C4 E2E가 1.712 → 1.615 → 1.553으로 줄지만, Llama3는 1.736 → 1.374 → 1.194로 더 크게 줄어든다. 따라서 batch 증가에 따른 이득 감소는 **linear backend 차이 축소, GEMM 비중 감소, 남아 있는 fused kernel 추가 비용**의 결합으로 설명된다.

# llama_energy_per_token_power_fpga_dequant_dynamic_W_no_area_norm_gemm_layout_vector_stacked

이 figure의 energy는 kernel별 실행 시간과 power를 곱해 합산한 값이다. Prefill은 B×seq, Decode는 B×128로 나눠 token당 energy를 구한다. `power_fpga_dequant_dynamic_W`는 모든 kernel에 dynamic power만 적용하는 모드가 아니다.

- 일반 GEMM/vector/layout kernel: `시간 × (PCIe run power − PCIe idle power + 고정 idle 5.5506 W)`.
- Standalone dequantization kernel: `시간 × (PCIe run power − PCIe idle power) × pure-dequant 보정계수`. Weight는 0.48263, KV-K/V는 0.28516이다.

고정 idle은 FPGA 내부 rail 기준의 추정값이며, 이 지표를 PCIe 전체 보드 energy 또는 전체 dynamic energy로 부르지 않는다. 같은 워크로드 내 후보 비율에서는 공통 token 수가 상쇄된다. [power와 pure-dequant 적용 코드](../../prepare.py).

## 9. Prefill에서는 latency가 비슷하거나 느린 C4도 C3보다 energy가 작을 수 있다.

**관찰.** Llama2의 C3/C4 energy는 모든 Prefill 지점에서 1.026–1.038이다. C4 TTFT가 조금 높아도 energy는 약 2.56–3.64% 작다. Llama3는 1k/2k에서 C4 energy가 높고, 4k 이후에는 같거나 조금 낮다.

| Model / context | C3/C4 E2E latency | C3/C4 energy |
| --- | ---: | ---: |
| Llama2 / 1k | 0.995 | 1.032 |
| Llama2 / 32k | 0.991 | 1.031 |
| Llama3 / 1k | 0.947 | 0.987 |
| Llama3 / 32k | 0.971 | 1.008 |

**원인.** C3/C4에는 standalone dequantization이 없으므로, 같은 kernel 범위에 대해 `energy = total time × 실행 시간으로 가중한 평균 effective power`로 비교할 수 있다. 위 네 지점에서 `(C3/C4 energy) / (C3/C4 latency)`로 계산한 C3/C4 평균 effective power 비율은 약 1.037–1.042다. 즉 C4의 가중 평균 effective power가 약 3.6–4.0% 낮아 latency 증가를 일부 상쇄한다.

Llama2의 작은 latency 불이익은 이 차이로 상쇄된다. Llama3 1k에서는 C4 latency가 약 5.61% 높아 energy도 약 1.37% 높지만, 32k에서는 latency 증가가 약 2.95%로 줄어 energy가 약 0.76% 낮아진다. 이는 해당 power 모드와 kernel 구성의 가중 평균이며, 모든 순간의 C4 power가 더 낮다는 뜻은 아니다.

## 10. Decode에서는 C1의 weight dequantization이 보이고, 긴 context·큰 batch에서는 KV dequantization 비중이 커진다.

**관찰.** B=1, 1k에서 C1 energy 중 weight dequantization 비중은 Llama2 10.53%, Llama3 10.70%다. 같은 지점의 C1/C4 energy는 28.06, 36.24로, E2E latency의 25.95, 34.18보다 크다.

Context가 길어지면 C1의 weight dequant 비중은 줄고 KV dequant 비중은 늘어난다. Llama2 B=1의 1k → 32k에서 weight는 10.53% → 4.23%, KV는 0.33% → 3.90%다. B=64, 32k의 C1 KV 비중은 Llama2 6.03%, Llama3 5.32%다. C2에도 attention용 KV dequantization이 보이지만 C3/C4에는 두 dequant stack이 없다.

**원인.** C1의 FP TCU 경로는 quantized weight/KV를 standalone kernel로 변환하고, C2는 attention의 KV 변환을 사용한다. C3/C4는 FP–INT GEMM 경로에서 처리하므로 별도의 dequant kernel이 없다. C3/C4의 dequant stack이 0인 것은 변환 관련 처리 전체가 공짜라는 뜻이 아니라, 비용이 별도 kernel로 분리되지 않는다는 뜻이다.

Weight 크기는 context와 무관하지만 KV는 context에 따라 늘어난다. 또한 batch가 커지면 weight 관련 비용을 더 많은 출력 token에 나누는 반면 각 sequence의 KV는 별도로 처리해야 한다. 따라서 긴 context·큰 batch에서 energy 구성은 weight dequant보다 KV dequant 쪽으로 이동한다. Latency figure는 두 standalone dequantization을 제외하므로, C1/C2에 대해 energy와 latency를 같은 kernel 범위의 지표로 비교하면 안 된다.

## 11. 이 power 모드에서도 큰 batch·긴 context의 C4 energy는 vector 비용에 제한된다.

**관찰.** B=64, 32k에서 C4 energy의 vector 비중은 Llama2 54.02%, Llama3 75.41%다. GEMM은 각각 44.46%, 21.74%다. 같은 지점의 C3/C4 energy는 1.565, 1.220으로, E2E latency의 1.553, 1.194와 비교적 가깝다. GEMM-only의 2.374, 2.187만큼 큰 energy 이득은 나오지 않는다.

**원인.** 이 모드는 dequantization을 제외한 GEMM/vector kernel에 고정 idle 5.5506 W를 더한다. 오래 실행되는 vector kernel은 dynamic power가 작더라도 실행 시간 동안 이 idle 성분을 계속 누적한다. 특히 Llama3의 긴 Decode에서는 query head 전체를 처리하는 softmax가 큰 비용을 차지하므로, FP–INT GEMM의 개선만으로 전체 energy를 크게 줄이기 어렵다.

C4의 standalone dequantization은 이미 0이므로 이 후보의 추가 개선 대상은 해당 stack 제거가 아니라 GEMM과 vector의 실제 실행 시간·effective power다. Figure에서 보이는 작은 layout energy만으로 fused kernel의 전체 비용이 작다고 판단하지 않고, vector와 layout의 합도 함께 비교해야 한다.
