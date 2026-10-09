# C4 decoder layer 검증 결과 — 2026-10-09

B1, prefill32, 실제 Llama hidden/FFN/head 크기, decoder 1개를 검증했다.
C4 nodsp FSM-update 이미지 하나에서 모든 head를 실행했다. CPU/TVM 출력 검증과
독립 연산 합산 대비 decoder cycle 비교를 완료했다. 측정 당시 변경은 미커밋 상태였다.

## 핵심 결과

- Llama3: 독립 합산 대비 연결 실행 **+0.389%**, device **0.919초**, host wall **1.057초**.
- Llama2: 독립 합산 대비 연결 실행 **−0.732%**, device **1.588초**, host wall **1.814초**.
- 이 shape에서 같은 C++ kernel의 개별 cycle 합산은 연결 실행의 device 시간을 **1% 이내**로 설명했다.
  host wall time에는 별도로 launch/wait 등의 비용이 포함된다.
- 전체 출력은 사용자 합의한 atol/rtol 0.005로 CPU·TVM 모두 PASS. 개별 연산 기준은 0.002를 유지했다.
- 22개 중간 tensor를 모델별로 확인했다. Llama3의 scores/FFN Hadamard와 Llama2의 일부 downstream
  tensor는 chain 기준을 넘지만, 동일한 실제 입력을 사용한 각 연산의 reference 검증은 PASS다.
  이를 bitwise 일치 또는 모든 chain tensor의 직접 비교 PASS라고 해석하면 안 된다.
- 모든 KV head의 INT4 payload·scale·zero는 동일 입력에서 byte 단위로 일치했다.
- FFN Hadamard가 device cycle의 Llama3 **45.45%**, Llama2 **62.43%**를 차지한다.
  Llama2 FFN11008은 base172 mixed-radix, Llama3 FFN14336은 base28이므로 FFN 폭만으로 시간을 비교할 수 없다.

## 검증 중 맞춘 수치 계약

1. C++ 양자화의 FP16 range/scale/division을 TVM/CPU에 opt-in으로 표현했다.
2. TVM의 C backend는 `tirx.round`를 `roundf`로 내보내 LLVM과 halfway 규칙이 달랐다.
   새 FP16 경로는 `nearbyintf`를 사용한다. 실제 FPGA에서 양/음수 `.5`, zero-point tie, all-zero row를 검증했다.
3. C++처럼 SiLU 출력에서 FP16 반올림을 거친다.
4. TVM RMSNorm의 순차 합산 대신 lane-strided partial sum과 binary tree를 선택할 수 있게 했다.
   C++ kernel과 입력·가중치는 유지했다. Llama3 TVM↔C++ relative L2는 0.267% → 반올림 수정 후
   0.114% → RMS 구조 정렬 후 0.041%로 줄었다. Llama2 최종 TVM↔C++ relative L2는 0.039%다.
5. QDIR=0 MXU는 dequantized FP16 weight를 중간에 만들지 않고, QDIR=1은 activation×scale에서 FP16 반올림을 한다.
   Local GEMM reference에는 기존 `fpint_gemm_ffn_hw/test_vectors.h`의 규칙을 적용했다.

기존 TVM model/quantizer 기본값은 보존했다. 위 정책들은 이 비교 fixture에서 명시적으로 선택한다.

## 추가 확인 및 파일

- Host A/C layout round-trip, DMA tile tail 및 TMEM 경계 검사: PASS.
- 기존 GEMM app: `(M,K,N,QBLK,WTRANS,QDIR)`가 `(32,256,256,32,0,0)`,
  `(32,128,32,128,1,0)`, `(32,32,128,128,0,1)`인 세 case 모두 FPGA PASS.
- TVM packed-KV tests: 13 PASS. 기존 backend policy tests: 17 PASS.
- 재현 명령: [README.md](README.md), 전체 실행: `run_validation.sh`, 집계: `summarize.py`.
- Raw 결과: [build results](../../../build_llama_decoder_c4/results/final/SUMMARY.md).
  `provenance.json`에 입력 hash, source hash, config, commit 기반 정보를 남겼다.
- Rev5에는 prefill32 E2E entry가 없다. 이번 표는 rev5 숫자와의 직접 비교가 아니라 **동일 C4·동일 shape의 독립 측정**과 비교한 결과다.
  Rev5의 1K 값을 비례 축소하지 않았고 1K 실행도 하지 않았다.

---

# C4 C++ decoder B1/S32 results

One real-size decoder layer; all heads executed. Three measured repetitions after warmup.

```text
job=5750
bdf=0000:2a:00.1
device_index=0
xclbin=/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_96c0f69b12/bin/vortex_afu.xclbin
```

Clock: 100 MHz. Cycles below are sums of per-operation medians.

| Model | Ops / GEMMs | Isolated cycles | Connected cycles | Difference | Device s | Wall median s |
|---|---:|---:|---:|---:|---:|---:|
| llama3 | 100 / 71 | 91,569,918 | 91,925,882 | +0.3887% | 0.919259 | 1.056709 |
| llama2 | 148 / 71 | 160,007,526 | 158,836,336 | -0.7320% | 1.588363 | 1.814306 |

## Functionality

Final atol/rtol 0.005, local 0.002; maximum violating fraction 2%, relative L2 1%, cosine 0.999.
All final CPU/TVM checks and identical-input packed KV checks passed. Chain differences are retained
in the JSON; passing local replays identify propagated numerical differences, not bitwise equality.

| Model | C++ vs CPU rel. L2 | TVM vs C++ rel. L2 | TVM vs CPU rel. L2 |
|---|---:|---:|---:|
| llama3 | 0.00044270 | 0.00040993 | 0.00039204 |
| llama2 | 0.00104674 | 0.00038642 | 0.00102058 |

## llama3: operation families

| Family | Calls | Isolated cycles | Connected cycles | Difference |
|---|---:|---:|---:|---:|
| RMSNorm | 2 | 1,799,411 | 1,799,318 | -0.005% |
| Linear GEMM (7) | 7 | 27,525,600 | 27,525,728 | +0.000% |
| RoPE | 2 | 1,009,550 | 1,009,755 | +0.020% |
| Q/K Hadamard | 2 | 2,912,752 | 2,919,369 | +0.227% |
| KV quantization | 16 | 3,545,459 | 3,540,461 | -0.141% |
| QK (all heads) | 32 | 454,299 | 454,398 | +0.022% |
| softmax | 1 | 4,744,527 | 4,712,205 | -0.681% |
| PV (all heads) | 32 | 480,057 | 480,038 | -0.004% |
| concat | 1 | 280,043 | 279,544 | -0.178% |
| Residual add | 2 | 1,394,447 | 1,397,907 | +0.248% |
| silu | 1 | 2,924,522 | 2,947,745 | +0.794% |
| mlp_product | 1 | 3,077,724 | 3,077,241 | -0.016% |
| ffn_hadamard | 1 | 41,421,527 | 41,782,173 | +0.871% |

Host-visible residual: 0.137450 s. This includes launch/wait/control effects and is not a direct pure launch-cost measurement.

## llama2: operation families

| Family | Calls | Isolated cycles | Connected cycles | Difference |
|---|---:|---:|---:|---:|
| RMSNorm | 2 | 1,800,339 | 1,799,079 | -0.070% |
| Linear GEMM (7) | 7 | 25,557,769 | 25,557,733 | -0.000% |
| RoPE | 2 | 1,549,735 | 1,557,386 | +0.494% |
| Q/K Hadamard | 2 | 4,618,894 | 4,628,093 | +0.199% |
| KV quantization | 64 | 14,138,746 | 14,146,232 | +0.053% |
| QK (all heads) | 32 | 454,775 | 455,239 | +0.102% |
| softmax | 1 | 4,777,051 | 4,735,917 | -0.861% |
| PV (all heads) | 32 | 479,968 | 480,964 | +0.208% |
| concat | 1 | 276,662 | 279,576 | +1.053% |
| Residual add | 2 | 1,408,146 | 1,405,707 | -0.173% |
| silu | 1 | 2,242,880 | 2,256,159 | +0.592% |
| mlp_product | 1 | 2,372,242 | 2,372,232 | -0.000% |
| ffn_hadamard | 1 | 100,330,319 | 99,162,019 | -1.164% |

Host-visible residual: 0.225942 s. This includes launch/wait/control effects and is not a direct pure launch-cost measurement.

## Scope and historical comparison

The independent baseline uses the same resident dispatcher, image, board, real inputs and launch shapes.
It replays each actual operator; it is not a sum copied from the decoder profile.
Different cache reuse between independent repeats and connected passes remains part of the comparison.
Initial code/weight upload, allocation, dumps and output validation are outside timing.

Rev5 prefill suites have 512/1024/2048/4096 tokens, not32. No proportional 1K-to32 extrapolation is used.
Rev5 also mixes FPGA images and uses a different V quantization policy. The matched baseline here is
the independently measured C++ execution. No1K decoder run was performed.

Artifacts: `operation_comparison.csv`, `summary.json`, per-model verify/isolated/timing directories,
`session.txt`, `xclbin.sha256`, `kernel.sha256`.
