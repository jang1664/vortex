MXU16 기본 조건 `QBLK=32, WTRANS=0, QDIR=0`에서 실측했고, `fpint_gemm_ffn_hw`는 `PASSED`했습니다.

핵심 결과:

| 항목 | 결과 |
|---|---:|
| GEMM microtile 명령 | 256개 |
| gemm_unit 입력 packet | 1,024개 |
| 실제 MXU compute fire | 1,024개 |
| Compute-active cycles | 1,436 |
| Compute utilization | 71.3% |
| HBM load/compute overlap | 202 / 264 cycles = 76.5% |
| HBM store/compute overlap | 49 / 179 cycles = 27.4% |
| 전체 DMA/compute overlap | 251 / 443 cycles = 56.7% |

HBM load는 처음 62-cycle prologue를 제외하면 전부 compute와 겹칩니다. 현재 병목 우선순위는 HBM read가 아닙니다. 반면 output store는 overlap이 낮고, 마지막 compute 이후 224-cycle store epilogue가 남습니다.

gemm_unit 입력은 첫 packet부터 마지막 packet까지 1,530 cycle 중 1,024 cycle에만 전달됐습니다.

- 입력 bubble: 506 cycles, 33.1%
- 128-column phase 전환의 126-cycle gap을 제외한 bubble: 380 cycles, 27.1%
- steady-state 입력 utilization: 72.9%

506개 bubble의 원인은 다음과 같습니다.

- 479 cycles: local DMA에서 ordered data가 아직 나오지 않음
- 27 cycles: gemm input pipe backpressure
- W/S/Z/ACC admission dependency 대기: 0 cycles

479-cycle producer bubble을 더 분해하면:

- 121 cycles: 두 번째 128-column phase 전환 중 command head 없음
- 258 cycles: response RAM의 registered sink stage refill
- 98 cycles: 실제 TMEM response 대기
- 2 cycles: expected response slot이 아직 발행되지 않음

중요하게도, 뒤쪽 slot에 data가 도착했지만 앞쪽 응답 때문에 막힌 head-of-line stall은 0 cycle이었습니다. 따라서 이 shape에서는 reorder depth를 늘리는 것이 직접적인 개선책은 아닙니다.

Compute-active 1,436 cycles 중 실제 issue가 없었던 412 cycles은:

- 294 cycles: aligned preprocessed input/control이 없음
- 118 cycles: `weight_ready=0`
- tree credit, scale, zero point, ZP consume channel 병목: 0 cycles

즉 최적화 우선순위는 다음과 같습니다.

1. Input local DMA의 registered sink-stage refill과 TMEM response 공급
2. 128-column 경계의 output-store handoff 및 마지막 224-cycle epilogue
3. 다음 weight generation을 더 일찍 준비하도록 prefetch/명령 간격 개선
4. HBM load나 response reorder depth는 후순위

전체 분석과 측정 방법은 [analysis.md](/home/jaeyongjang/project.local/vortex_base/agent-tasks/mxu16-m4-k256-n256-perf/analysis.md)에 정리했습니다. 실행 로그는 [wrapper.log](/home/jaeyongjang/project.local/vortex_base/agent-tasks/mxu16-m4-k256-n256-perf/logs/wrapper.log)에 있습니다.