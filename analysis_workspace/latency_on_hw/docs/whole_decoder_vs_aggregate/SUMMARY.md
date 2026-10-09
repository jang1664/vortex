# C4 whole decoder vs aggregate — B1/S1024

2026-10-09. 실제 runtime의 AP_DONE/AP_IDLE polling sleep과 고정 0.5 ms 대기를
제거하고 측정했다. 완료 확인은 유지하며 timeout은 monotonic 경과 시간으로 검사한다.
`build/runtime`과 `build_llama_decoder_c4/runtime` 모두 갱신했다.

- Llama3-8B / Llama2-7B **decoder 1 layer**, random 입력·weight, batch 1, prefill 1024.
  실제 hidden/FFN/head 크기와 모든 head를 실행했다. Embedding/LM head는 제외.
- C4: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update`,
  TH16/MXU16, 100 MHz. 동일 FPGA `0000:2a:00.1` 사용(job 5754/5755).
- **Aggregate는 이번에 같은 C4·실제 입력으로 각 op를 독립 측정해 합산한 값**이다.
  기존 rev5의 여러 이미지가 섞인 CSV 합산값은 아니다.

## Latency

| 모델 | 독립 FPGA cycle 합 환산 | 연결 FPGA cycle 합 환산 | 연결 decoder wall time | wall / 독립 합 차이 |
|---|---:|---:|---:|---:|
| llama3 | 31.109715 s | 31.075147 s | 31.060445 s | -0.158% |
| llama2 | 50.062635 s | 50.072298 s | 50.068739 s | +0.012% |

Warmup 후 **각 1회 측정**했다. Wall time은 `decoder.run()` 전체로, 입력/weight
업로드, 결과 다운로드, 검증, cycle counter 조회를 제외하고 launch/wait와
CPU bookkeeping은 포함한다. FPGA profile은 별도 실행이다. 작은 음수 차이는
별도 실행 변동을 포함하며 음수 launch overhead를 뜻하지 않는다.

## 정확성 제한

두 모델 모두 측정 전 및 마지막 timed run의 **최종 출력은 CPU 기준 PASS**다.
하지만 동일 입력 PV(context) 검증은 기존 local 기준 0.002에서 **FAIL**이다.
따라서 위 수치는 수치 문제가 남아 있는 현재 이미지의 진단용 latency이며,
전체 functionality PASS 결과로 해석하면 안 된다.

| 모델 | PV 상대 L2 오차 | PV 기준 초과 원소 비율 | 최종 출력 상대 L2 오차 |
|---|---:|---:|---:|
| llama3 | 0.5039% | 10.815% | 0.1120% |
| llama2 | 0.5004% | 10.547% | 0.0905% |

그 외 수행한 동일 입력 연산 검증은 PASS이며 packed KV byte/qparam 불일치는 0개다.
기존 FP16 scaler의 subnormal flush 및 output converter 결함 모델로 PV를
계산하면 두 모델 모두 **4,194,304개 중 1개만 비트가 다르다**(모델 대비 상대
L2 약 0.00011%). 이는 기존 산술 결함과의 일치이며 올바른 reference PASS를
대신하지 않는다. 해당 RTL이나 허용 오차는 이번에 변경하지 않았다.

## 재현 자료

- [기존 PV 진단/수정 계획](../../../../agent-tasks/pv-small-product-debug/RTL_FIX_PLAN.md)
- [실험 자료](../../../../build_llama_decoder_c4/results/b1_s1024_busy_poll_20261009/):
  `summary.json`, `provenance.json`, `run.sh`, `resume.sh`, 각 모델의 timing/isolated
  CSV·로그·검증 JSON 및 `pv_defect_diagnosis.json`.
- Configured build에서 `ci/run_black.sh hw --fpga-bin <위 alias> --app llama_decoder_C4`
  및 `--args "--model llama3-8b --batch 1 --seq-len 1024 --mode timing --repetitions 1 --fixture <fixture> --output <output>"` 사용.
  독립 측정은 `--mode isolated`, Llama2는 `--model llama2-7b`를 사용한다.

최초 Llama3 intermediate FAIL에서 실행을 중단한 뒤, 실패를 보존한 상태로
같은 물리 보드에서 나머지 진단용 측정을 재개했다. Full PASS gate는 완화하지 않았다.

Decode 1-step 확장 결과: [B1/past KV1024 비교](DECODE_B1_P1024.md).
