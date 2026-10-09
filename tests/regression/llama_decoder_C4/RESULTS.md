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

## XRT fixed settle delay 제거 재검증 (2026-10-09)

현재 XRT entry `runtime/xrt/vortex.cpp`는 `vortex_v6.cpp`를 가리킨다.
`vx_ready_wait()`가 AP_DONE 및 AP_IDLE을 확인한 뒤 매 kernel에 적용하던
`nanosleep(500000 ns)`만 제거했다. 완료/idle 확인, 기존 polling 간격,
launch 경로, runtime 로그와 decoder의 CPU sample 기록은 그대로 유지했다.

`timing` 모드도 보완했다. 측정 전에만 정답을 검사하던 기존 코드에 더해,
마지막 `decoder.run(false, {})`가 남긴 output을 측정 종료 후 다운로드하고
CPU reference와 비교한다. 측정 중에는 tensor 다운로드나 counter 조회가 없다.
실패하면 profiling에 들어가기 전에 nonzero exit한다.

동일 Slurm allocation **5752**, BDF **0000:2a:00.1**에서 이전 source를 별도로
빌드한 baseline runtime과 수정 runtime을 비교했다. 두 runtime 모두 같은
수정 host executable과 동일 device binary, C4 nodsp_fsm_update 이미지,
B1/S32 fixture를 사용했다. 각 wall time은 3회 중앙값이다.

| 모델 | 기존 wall s | 수정 wall s | 감소 ms |
|---|---:|---:|---:|
| llama3 | 1.056792 | 1.005292 | 51.500 |
| llama2 | 1.801929 | 1.718759 | 83.170 |

고정 대기 요청량은 Llama3 50 ms, Llama2 74 ms였다. 실측 감소량에는
sleep scheduling과 실행 변동도 포함되므로 그 차이를 모두 launch 개선으로
해석하지 않는다. 같은 순서로 baseline 다음 수정 runtime을 실행한 소규모
검증이며 통계적 동등성 실험은 아니다.

수정 runtime의 연결/독립 비교:

| 모델 | 독립 device cycle 합 | 연결 device cycle 합 | 차이 | 독립 host 시간 합 s | 연결 wall s | host 차이 |
|---|---:|---:|---:|---:|---:|---:|
| llama3 | 91,618,079 | 91,899,259 | +0.3069% | 1.002302 | 1.005292 | +0.2983% |
| llama2 | 159,439,445 | 159,436,951 | -0.0016% | 1.725612 | 1.718759 | -0.3971% |

독립 host 시간 합은 각 op의 `vx_start`부터 `vx_ready_wait` 반환까지 측정한
`host_seconds`의 op별 중앙값 합이다. counter 조회는 그 타이머 뒤에 수행한다.
연결 wall은 decoder 전체 타이머라 op 사이 CPU bookkeeping까지 포함한다.
독립 replay는 같은 실제 입력을 사용하지만 cache reuse 조건은 다를 수 있다.
이 host 합은 기존 latency_on_hw의 FPGA-cycle 합산값과 구별해야 한다.

연결 wall은 별도 profile의 device-cycle 합 환산보다 Llama3 **9.39%**, Llama2 **7.80%** 크다. 이 잔차는 launch, polling, CPU bookkeeping 및 별도 실행 변동을 포함하며, 순수 launch 비용만 측정한 값은 아니다.

검증: 두 모델 모두 baseline/수정 runtime에서 측정 전 및 마지막 측정 출력 PASS.
수정 runtime의 22개 intermediate boundary 검증(필요한 동일 입력 replay 포함),
packed KV byte/qparam 검증, 독립 op 실행도 PASS. TVM graph와 RTL은 변경하지
않았고 이번에는 TVM 실행을 반복하지 않았다.

재현 자료는 `build_llama_decoder_c4/results/no_settle_20261009/`에 있다.
`baseline_source/`는 수정 전 runtime source, `baseline_runtime/`은 별도 빌드,
`runtime.patch`는 수정 내용, `run_verified.sh`는 configured build에서
`ci/run_black.sh hw --no-srun --run-only`를 사용하는 실험 명령이다.
`verified/`에 session/BDF, library·kernel SHA256, per-model 로그·출력·CSV·JSON을
보존했다. `summarize.py`는 정답 PASS 및 3회 측정/전체 op coverage를 확인하고
`verified/summary.json`을 생성한다. 이전 `results/final` 결과는 유지했다.

## Polling sleep 제거 임시 실험 (2026-10-09, B1/S32)

Slurm **5753**, 동일 BDF **0000:2a:00.1**, 동일 C4 nodsp_fsm_update 이미지와
기존 B1/S32 fixture를 사용했다. baseline과 busy-poll runtime 모두 이전에
제거한 0.5 ms fixed settle delay는 없다. 이번 차이는 AP_DONE polling의
1 ms sleep과 AP_IDLE polling의 0.1 ms sleep을 없앤 것이다.

기본 runtime source/binary는 변경하지 않고 build 아래의 별도 source와
runtime library로 실험했다. timeout은 polling마다 1 ms를 차감하는 방식
대신 `steady_clock`의 실제 경과 시간으로 검사했다. 완료/idle 상태 확인,
출력 로그, decoder CPU sample 기록 및 kernel은 유지했다.

각 wall time은 3회 중앙값이다. 독립 op는 실제 입력으로 각각 warmup 후
3회 측정하고, op별 중앙값을 합했다.

| 모델 | sleep 유지 wall s | busy-poll wall s | 감소 ms | 독립 FPGA cycle 합 환산 s | busy wall / 독립 cycle 합 차이 |
|---|---:|---:|---:|---:|---:|
| llama3 | 1.000551 | 0.921434 | 79.117 | 0.918175 | +0.3549% |
| llama2 | 1.731773 | 1.594983 | 136.790 | 1.592387 | +0.1630% |

| 모델 | 독립 device cycle 합 | 연결 device cycle 합 | cycle 차이 | 독립 host 시간 합 s | 연결 wall / 독립 host 합 차이 |
|---|---:|---:|---:|---:|---:|
| llama3 | 91,817,525 | 91,615,206 | -0.2203% | 0.920637 | +0.0866% |
| llama2 | 159,238,730 | 159,949,440 | +0.4463% | 1.596020 | -0.0650% |

이 두 workload에서 polling sleep을 없애면 실제 decoder wall time이 독립
FPGA-cycle 합 환산과 0.36% 이내로 가까워졌다. 독립 host 시간 합과는 0.09%
이내 차이다. 이는 이 설정의 반복 측정 결과이며 모든 shape에서의 동등성을
입증하는 것은 아니다. baseline→busy 실행 순서는 고정돼 있다.

연결 FPGA cycle profile도 wall 타이밍과 별도 실행이다. Llama2에서 wall이
별도 profile 환산보다 0.28% 짧게 나온 것은 실행 변동 및 중앙값 집계 차이로
볼 수 있으며, 이를 음수 launch overhead로 해석하면 안 된다. 순수 launch
비용을 정밀하게 분리하려면 같은 실행에서 대응되는 device 구간이 필요하다.

두 모델 모두 baseline/busy-poll의 측정 전 및 마지막 timed output 검사 PASS.
Busy-poll intermediate 검증(동일 입력 replay 포함), packed KV byte/qparam
검증, 독립 op 실행도 PASS. FPGA bitstream 및 TVM graph 변경은 없다.

자료: `build_llama_decoder_c4/results/busy_poll_20261009/`의 `busy_poll.patch`,
`baseline_source.cpp`, `busy_source/`, `baseline_runtime/`, `busy_runtime/`,
`run.sh`, `summarize.py`, `provenance.json`, `verified/summary.json`과 per-model
로그/CSV/검증 JSON. configured build에서 `ci/run_black.sh hw --no-srun
--run-only`와 phase별 `VORTEX_RT_PATH`로 library를 선택했다. 기본 runtime의
polling sleep은 그대로이며, 이번 결과는 별도 실험용 library의 결과다.

## 실제 runtime 반영 및 B1/S1024 추가 측정

임시 실험 이후 polling sleep 제거를 실제 `runtime/xrt/vortex_v6.cpp`에 반영했다.
완료/idle 확인은 유지하고 두 단계에 동일한 monotonic timeout을 적용한다.
`build/runtime`과 decoder build의 runtime도 재빌드했다.

B1/S1024의 연결 wall time / 독립 FPGA cycle 합 환산은 Llama3
31.060445 / 31.109715초(−0.158%), Llama2 50.068739 / 50.062635초(+0.012%)였다.
각 1회 측정이며, 최종 출력은 PASS지만 기존 FP16 subnormal 문제로 PV의
동일 입력 검증은 FAIL이다. 전체 functionality PASS 결과로 해석하지 않는다.

[상세 요약 및 재현 자료](../../../analysis_workspace/latency_on_hw/docs/whole_decoder_vs_aggregate/SUMMARY.md).

## B1, past KV1024, first incremental decode — 2026-10-09

Three repetitions on the same C4 image/board, median wall time versus independent
operation cycle sum at 100 MHz:

| Model | Independent sum | Connected wall | Difference |
|---|---:|---:|---:|
| Llama3-8B | 131.971 ms | 134.433 ms | +1.866% |
| Llama2-7B | 166.981 ms | 170.778 ms | +2.274% |

These are **diagnostic timings, not functionality PASS results**. Final-output
checks fail from the deferred PV subnormal arithmetic issue. Every PV element
matches the known RTL defect model bit-for-bit; packed KV mismatches are zero.
The padded parent M=8 / target M=1 layout is used in both measurements.

See [full decode report](../../../analysis_workspace/latency_on_hw/docs/whole_decoder_vs_aggregate/DECODE_B1_P1024.md)
for shapes, exact cycles, tolerances, provenance, and limitations. Existing
B1/S32 prefill and standalone persistent K/V append regressions pass.
