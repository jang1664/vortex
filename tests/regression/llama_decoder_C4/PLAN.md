# C4 C++ decoder layer 구현 및 검증 계획

작성일: 2026-10-09. 이 문서는 실행 계획이다. 완료된 구현/실행 결과는 RESULTS.md에 기록한다.

## 1. 목적과 최초 범위

기존 handwritten C++ kernel을 실제 tensor dependency로 연결한다. 같은 C4 이미지에서 개별 연산을 독립 실행한 합산값과 decoder 실행값을 비교하고, 동일 입력·가중치를 사용하는 CPU 및 TVM reference로 출력을 검증한다.

- 위치: `tests/regression/llama_decoder_C4`.
- 최초 실행: **Llama3-8B, batch 1, prefill 32 tokens, decoder 1개**.
- hidden 4096, FFN 14336, Q heads 32, KV heads 8, head dimension 128은 유지한다.
- 최초 KV capacity도 32로 한다. 논리적인 shape와 물리적 padding은 별도 관리한다.
- 전체 decoder를 `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update` 이미지 하나로 실행한다. alias, manifest/config/hash, BDF를 기록한다.
- embedding, LM head, decode/token generation, 여러 layer, RTL 변경은 최초 범위에 없다.
- 1K 확대는 32-token 결과를 확인한 뒤 별도 단계로 둔다. 이번 최초 실험에 자동으로 추가하지 않는다.

## 2. 모델 설정 공유와 C4 실행 경로

Llama2/Llama3별 연산 코드를 복제하지 않고 설정으로 구분한다. 최초 preset은 Llama2-7B와 Llama3-8B이다. Llama3.1은 RoPE 설정이 다르므로 Llama3 preset에 암묵적으로 포함하지 않는다.

| Parameter | Llama2-7B | Llama3-8B |
|---|---:|---:|
| hidden size | 4096 | 4096 |
| FFN size | 11008 | 14336 |
| Q heads | 32 | 32 |
| KV heads | 32 | 8 |
| head dimension | 128 | 128 |
| Q heads per KV head | 1 | 4 |
| RoPE theta | 10000 | 500000 |
| RMS epsilon | 1e-5 | 1e-5 |

batch, sequence length, position offset, RoPE convention, weight/KV quantization group size·axis·policy도 설정에 포함한다. `hidden == Q_heads * head_dim`, `Q_heads % KV_heads == 0` 등을 검증한다.

Thread/MXU 관계는 기존 `vector_common/config_check.h`를 재사용한다. 16/32에 한정하는 새 제약을 만들지 않으며, 이번 실험은 TH16/MXU16으로 한다.

모델 설정·fixture·검증 코드는 향후 candidate에서도 공유할 수 있도록 작성한다. 실행 계획은 C4 전용으로 두고, 이번에 C1–C3 backend나 범용 backend framework까지 구현하지 않는다.

## 3. 먼저 확인할 연산 경계

각 경계의 logical shape, dtype, physical layout, stride, padding, buffer 크기/alignment, quantization 방식, 반올림 위치를 표로 확정한다. layout 이름만으로 호환된다고 가정하지 않고 실제 주소 계산을 확인한다.

재사용 대상:

- `fpint_gemm_ffn_hw/{kernel.cpp,common.h,layout.h,test_vectors.h}`
- `layout_fused_common/layout_fused_layouts.h`
- `kv_cache_quant_layout_fused_w4a16/{common.h,host_common.h}`와 `kv_cache_common/`
- `vector_common/{fp16.h,fp16_preserve.h,config_check.h}`
- 각 `*_layout_fused`의 현재 선택된 kernel source와 argument ABI
- `pytorch/spinquant/spinquant_inference/llama3_c4_export.py`의 모델·reference 생성 코드

중점 확인 사항:

1. fix_pad 이후 GEMM-A/C layout 및 8-row/64B tail 규칙. 생산자·소비자의 byte offset과 할당 크기를 함께 확인한다.
2. RoPE K 출력의 W-like layout은 packed INT4가 아니다. K Hadamard와 quantization으로 이어지는 layout을 선택하고 중간 host 변환을 넣지 않는다.
3. GQA는 `kv_head = q_head / (Q_heads / KV_heads)`로 연결한다. K/V를 Q head 수만큼 물리적으로 복제하지 않는다.
4. causal mask와 `1/sqrt(head_dim)`을 softmax에서 한 번만 적용한다.
5. SiLU는 header 주석만 보지 않고 현재 variant의 실제 GEMM-C 입출력을 확인한다.
6. quantization group axis, transpose, signed code, scale/zero-point 표현을 맞춘다. 32-token PV에서 head dimension의 group 128과 sequence length를 혼동하지 않는다.
7. Q/K Hadamard와 FFN mixed-radix Hadamard는 reference와 같은 base matrix 및 정규화를 사용한다. 비2의 거듭제곱 FFN을 단순 zero-padding FWHT로 바꾸지 않는다.

## 4. Decoder 구성

| 순서 | 연산 | 연결 방식 |
|---|---|---|
| 1 | input RMSNorm | row-major hidden → GEMM-A |
| 2 | Q/K/V projections | 같은 normalized activation에서 3 GEMM |
| 3 | Q/K RoPE + Hadamard | 전체 Q/KV heads를 처리하고 다음 연산의 layout으로 출력 |
| 4 | K/V quantization | 전체 KV heads의 packed W·scale·zero-point 생성 |
| 5 | QKᵀ | 모든 Q head가 대응하는 KV head 참조 |
| 6 | causal softmax | GEMM-C scores → GEMM-A probabilities |
| 7 | PV | 모든 Q head가 대응하는 V 참조 |
| 8 | head concat → O projection | head별 GEMM-C → combined GEMM-A → GEMM |
| 9 | attention residual add | GEMM-C + 저장한 row-major residual → row-major |
| 10 | post-attention RMSNorm | row-major → GEMM-A |
| 11 | gate/up projections | 같은 normalized activation에서 2 GEMM |
| 12 | SiLU → elementwise multiply | GEMM-C → GEMM-C → GEMM-A |
| 13 | FFN Hadamard → down projection | GEMM-A를 유지해 GEMM으로 연결 |
| 14 | final residual add | GEMM-C + attention residual → row-major output |

구현 시 이 표를 kernel argument와 buffer 이름까지 구체화한다. Llama3에서도 QKᵀ/PV 각각 32 heads를 모두 실행한다. GEMM은 논리적으로 **7 linear projections + 32 QKᵀ + 32 PV = 71회**이다.

Vector는 기존 batched/head-aware interface를 활용하되 전체 원소를 처리한다. 대표 head의 결과를 복사하거나 latency에 head 수를 곱해 실제 실행을 대신하지 않는다.

## 5. C++ 구현과 build

하나의 host application에서 device를 한 번 열고 가중치, RoPE table, kernel code, workspace를 준비한다. 중간 tensor는 device에 유지하며 측정 중 CPU에서 다음 입력을 만들지 않는다.

초기 구성은 **device binary 하나 + operation dispatcher + host의 순차 launch**이다. 기존 kernel의 연산 loop·schedule·variant를 재사용하고 필요한 최소 entry wrapper만 추가한다. decoder 전체를 하나의 launch로 합치는 최적화는 이번에 하지 않는다.

현재 `.vxbin`들은 같은 `STARTUP_ADDR`를 사용하고, `runtime/stub/utils.cpp`의 `vx_upload_kernel_bytes`는 고정 VMA를 reserve한다. 따라서 기존 binary 여러 개를 같은 주소에 동시에 올릴 수 있다고 가정하지 않는다. 연산마다 code를 재업로드하는 비용도 측정 경로에서 피한다.

각 연산은 별도 translation unit에서 기존 source/header를 재사용한다. `kernel_arg_t`, `main`, header guard, global symbol 충돌을 처리하되 계산 코드는 복제하지 않는다. 필요한 경우 기존 entry에서 argument를 받는 함수만 추출하고 원래 app도 같은 함수를 호출하게 한다. 변경한 kernel에 대해서만 기존 regression의 기능·cycle을 확인한다.

파일 구성안:

- `main.cpp`: CLI, device lifetime, fixture 로딩, 검증·측정 mode.
- `model_config.*`: 공통 parameter 검증과 Llama2/Llama3 preset.
- `decoder.*`: C4 실행 순서, buffer lifetime, 전체 head loop.
- `ops/`: 기존 kernel에 연결하는 얇은 host/device adapter.
- `Makefile`: 기존 `tests/regression/common.mk`를 활용한 build.
- fixture/reference Python helper와 README. 큰 데이터와 로그는 build/results에 저장한다.

variant 설정은 기존 Makefile을 가능한 한 재사용하고 실제 source·define·hash를 기록한다. 현재 기본값의 예는 softmax=`rev2_shuffle_cursor`, RoPE=`task_chunk16`, RMSNorm=`adaptive_m_rows`, Hadamard=`r3_shuffle_incremental`이다. rev5 실측 시점과 같다고 가정하지 않는다. `rev2_shuffle_safe`는 사용하지 않는다.

## 6. Fixture와 기능 검증

고정 seed로 hidden, norm weights, quantized linear weights, scale/zero-point, position, RoPE/Hadamard constants를 한 번 생성한다. C++/CPU/TVM 모두 동일한 fixture를 읽으며 각각 따로 random 생성하거나 quantize하지 않는다.

입력·weight scale은 알려진 subnormal 문제를 일으키기 어려운 범위로 정하되, softmax 등에서 자연스럽게 작은 값이 나오는 것을 clamp해서 계산을 바꾸지는 않는다.

계산 규칙은 현재 C++ C4 pipeline을 기준으로 고정한다. 기존 TVM 모델과의 차이를 먼저 해소한다:

- rev5에는 K signed-asymmetric / V signed-symmetric 기록이 있다. 현재 TVM export는 all-asymmetric만 허용한다. group axis까지 포함해 C++ 정책을 확정하고 TVM reference에 명시적으로 대응하는 설정을 추가한다. 기존 TVM default는 바꾸지 않는다.
- C++ SiLU 출력은 FP16을 거쳐 elmul로 전달된다. 현재 TVM 모델은 SiLU와 multiply를 float로 처리한 뒤 FP16으로 변환한다. reference의 중간 반올림 위치도 맞춘다.
- Hadamard, RMSNorm, softmax 등의 reduction 순서 차이는 오차 지표로 평가한다.

검증 순서:

1. Host에서 layout round-trip, buffer 크기, padding, head offset을 검사한다.
2. GEMM → fused vector → GEMM 등 짧은 연결 단위를 검사한다.
3. Llama3 B1/S32 전체 layer를 debug mode로 실행하고 중간 tensor를 logical layout으로 복원해 비교한다.
4. 같은 fixture의 CPU reference 및 계산 규칙을 맞춘 TVM B1/S32 출력과 비교한다.
5. 같은 C++ 코드로 Llama2 B1/S32를 실행해 MHA/GQA parameter화를 확인한다.

비교 지점은 Q/K/V projections, RoPE/Hadamard 후, KV 양자화, scores, softmax, PV, attention residual, gate/up, SiLU/elmul, FFN Hadamard, final hidden이다.

max/mean absolute error, relative L2, cosine, 기준 초과 개수/전체 개수, NaN/Inf, 최대 오차 위치를 저장한다. INT4 payload와 qparams는 따로 비교하고 필요하면 dequantized 값도 확인한다. bitwise 일치를 일반 조건으로 요구하지 않는다. 기존 검증 기준을 출발점으로 결과를 보기 전에 판정 규칙을 확정한다. subnormal 차이를 포함한 실패를 일괄 PASS로 처리하지 않고 처음 어긋나는 경계부터 분류한다.

## 7. Latency 비교

기능 검증을 통과한 후 dump·CPU 검증을 끈 timing mode로 측정한다. 초기 업로드, weight packing, reference 생성, 최종 다운로드는 측정에서 분리한다.

동일 C4 이미지·variant·shape·계산 규칙으로 **독립적인 두 실험**을 수행한다:

1. `isolated`: debug 실행에서 저장한 각 연산의 실제 입력으로 해당 연산을 독립 실행한다. 모든 head의 연산을 실제로 측정하고 합산한다. 입력 복원·업로드는 시간 밖에 둔다.
2. `decoder`: 최초 입력부터 최종 출력까지 device buffer를 연결해 실행한다.

decoder 실행의 내부 cycle을 합한 값만을 독립적인 합산 baseline이라고 부르지 않는다. 같은 allocation/BDF를 유지하고, warmup 후 짧게 반복 측정한다. 1 warmup + 3 repetitions을 기본으로 하되 오래 걸리면 횟수를 줄이고 명시한다.

| 지표 | 의미 |
|---|---|
| 독립 실행한 per-op FPGA cycle 합 | 같은 C++ 구현의 합산 baseline |
| decoder 실행 중 per-op FPGA cycle 합 | 실제 데이터 연결 시 device 실행 비용 |
| decoder wall time | launch, wait, argument 갱신 등을 포함한 host-visible 시간 |
| wall time − device cycle 환산 시간 | host 제어 등의 잔여 시간. 전부 launch 비용이라고 단정하지 않음 |

Counter는 별도 profile pass에서 읽어 wall-time 측정에 섞지 않는다. resident code, tensor 주소, cache 상태, standalone/dispatcher의 코드 배치 차이를 기록한다. 같은 config라도 cache와 실제 입력 때문에 cycle이 달라질 수 있으므로 완전 일치를 가정하지 않는다.

rev5는 보조적인 과거 결과 비교로 둔다. 먼저 32-token entry가 있는지 확인한다. 없다면 1K의 30.299684초를 32/1024배 한 값을 baseline으로 쓰지 않는다. 향후 1K를 실행하면 shape를 맞춰 비교하되 이미지·policy 차이를 함께 표기한다.

## 8. 실행 순서와 완료 조건

1. 연산 경계, 수치 정책, variant 목록을 확정한다.
2. 공통 fixture, C4 dispatcher, buffer 계획을 구현한다.
3. 작은 연결 test로 layout과 head mapping을 확인한다.
4. C4에서 Llama3 B1/S32 전체 layer를 실행하고 CPU/TVM과 비교한다.
5. Llama2 B1/S32로 코드 공유를 검증한다.
6. 독립 연산 합산 vs decoder cycle/wall time을 측정하고 내역을 CSV/Markdown에 남긴다.

HW는 configured build에서 `ci/run_black.sh hw --fpga-bin <위 alias> --app llama_decoder_C4 ...`로 실행한다. CLI안은 `--model llama3-8b --batch 1 --seq-len 32 --mode verify|isolated|timing --fixture <path>`이다.

필요한 짧은 RTL 확인만 별도 build에서 config를 source하고 `xrt-vcs-sim`으로 실행한다. 처음부터 실제 크기의 decoder 전체를 VCS에서 실행하며 기다리는 계획은 아니다.

완료 조건은 전체 head를 처리하는 C4 decoder, 재현 가능한 fixture, 기능 판정, 독립 합산 대비 latency 표, 차이 분석이 모두 갖춰지는 것이다. 해결하지 못하는 불일치나 장시간 정체가 생기면 실험을 중단하고 기록·알림을 남기며 1K로 확대하지 않는다.

## 9. 실행 중 확정한 수치 계약

- K/V는 모두 signed-asymmetric, group128을 사용한다. rev5와 policy가 다르다는 점을 결과에 명시한다.
- C++와 비교할 TVM/CPU fixture는 FP16 KV quantization arithmetic과 별도 FP16 SiLU 출력을 선택한다. 기존 모델의 기본값은 보존한다.
- C++ warp RMS reduction과 TVM의 순차 reduction 사이의 차이를 줄이기 위해, opt-in `rms_reduction_width`로 lane-strided 합산과 binary tree를 표현한다. 폭은 선택한 profile에서 가져온다.
- TVM C backend의 `roundf`는 ties-away이므로 새 FP16 quantization 경로에서는 `nearbyintf`의 ties-even 규칙을 사용한다. 실제 FPGA에서 양/음수 `.5` 및 zero-point 경계를 검사한다.
- **사용자 합의:** 전체 출력 atol/rtol은 0.005, 개별 연산은 0.002. magnitude split 0.25, 기준 초과 원소 2% 이하, relative L2 0.01 이하, cosine 0.999 이상, NaN/Inf 없음은 유지한다.
- Chain 비교와 실제 입력을 이용한 local replay 결과를 함께 보존한다. Local replay로 최종 출력 gate를 대체하지 않는다.
