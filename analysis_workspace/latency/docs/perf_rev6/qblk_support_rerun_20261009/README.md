# C3 QBLK assertion 확장 및 M4 재실행

실행일: 2026-10-09. rev6 C3 설정, `fpint_gemm_ffn_hw_naive`, `xrt-vcs-sim --perf 3`. 다섯 case 모두 returncode=0 및 CPU reference 검증 `PASSED`.

## 변경

`hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv`의 QBLK 검사만 `log2(QBLK)==5`에서 `4 <= log2(QBLK) <= 7`로 변경했다. 허용 값은 16, 32, 64, 128이다. 차원 및 alignment 검사는 유지했다. 기존 데이터 경로의 qlog 기반 주소 계산은 변경하지 않았다. 변경 부분은 `GEMM_NAIVE` 및 `ifndef SYNTHESIS` 내부라 improve 선택 RTL과 합성 하드웨어 로직에 변화가 없다. improve 재실행이나 PnR은 수행하지 않았다.

## 결과

| case | M × N × K | QBLK | WTRANS / QDIR | 결과 | GEMM cycles | GEMM µs | MXU input util. | GEMM AXI GB/s |
|---|---|---:|---|---|---:|---:|---:|---:|
| small_q16 | 16 × 32 × 128 | 16 | 0 / 0 | PASSED | 1,327 | 13.27 | 19.29% | 0.608 |
| small_q32 | 16 × 32 × 128 | 32 | 0 / 0 | PASSED | 1,302 | 13.02 | 19.66% | 0.580 |
| small_q64 | 16 × 32 × 128 | 64 | 0 / 0 | PASSED | 1,292 | 12.92 | 19.81% | 0.565 |
| small_q128 | 16 × 32 × 128 | 128 | 0 / 0 | PASSED | 1,282 | 12.82 | 19.97% | 0.559 |
| llama3_attention_decode | 4 × 1025 × 128 | 128 | 1 / 0 | PASSED | 7,596 | 75.96 | 27.38% | 1.041 |

M4 case는 기존과 같은 실제 attention shape이며 QBLK를 바꾸지 않았다. assertion 완화만으로 정답 검증까지 통과했으므로, 이 shape의 기존 실패 원인은 QBLK=32로 고정된 assertion이었다. 네 QBLK의 작은 case 및 QBLK=128의 실제 attention case를 검증했으며, 모든 layout·QDIR 조합을 검증한 결과는 아니다.

시간 환산은 모델의 logic clock 100 MHz 기준이다. MXU utilization은 input handshake / GEMM cycles이다. AXI GB/s는 uncalibrated 시뮬레이션 모델의 관찰값이며 FPGA 실측이 아니다. passive monitor의 cycle 및 byte accounting 검사도 다섯 case 모두 통과했다.

## 재현

configured build `build_latency_perf_c3_rev6`에서:

```bash
source ../configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh
export CC=/usr/bin/gcc CXX=/usr/bin/g++
timeout 1800 ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args '-m 4 -n 1025 -k 128 -q 128 -t 1 -d 0' --perf 3 --configs-extra '-DDISABLE_FSDB'
```

작은 case는 `-m 16 -n 32 -k 128 -q {16,32,64,128} -t 0 -d 0`으로 실행했다. build Makefile에 수정한 FSM을 simv prerequisite로 추가해 RTL 재빌드를 보장했다. 최초 수정 전 바이너리 재사용 실패는 `raw/stale_binary_attempt/`에 별도로 보존했고 결과 표에는 포함하지 않았다.

원래 2026-10-08 C3 assertion 실패는 상위 `raw/attempts/c3_attention_qblk32_assertion_20261008/`에 보존했다. 상위 `raw/c3_llama3_attention_decode.*`는 이후 보완 측정으로 갱신했으며, [전체 분석](../../c3_c4_rev6_fine_grained_analysis.md)과 [현재 전체 자료](../README.md)의 모든 표·그림에 C3 attention을 포함했다. 이번 실행의 로그·실행 명령·모델 manifest는 `raw/`, 계측값은 `measurements.json`과 `measurements.csv`에 저장했다.

## 전체 분석 반영

2026-10-09 C3 attention을 같은 조건으로 다시 실행해 GEMM 7,596 cycles 및 정답 검증 통과를 재확인했다. 이 문서의 최초 재실행 데이터는 그대로 보존하고 전체 집계에는 상위 `raw/`의 최신 실행을 사용한다. HBM min/max/mean/median, MXU·pipeline utilization, LMEM read/write·bank conflict, DMA stage bandwidth·중첩 정보는 전체 분석 본문에 채웠다.

2026-10-09 추가 갱신: M=4 K/V·FFN projection의 C3/C4 네 실행도 통과해 상위 전체 집계는 12개 passing case가 됐다. 이 폴더의 QBLK 검증 5개 기록은 별도로 유지하며 M=1/M=4 비교는 [상위 자료 안내](../README.md)와 [전체 분석](../../c3_c4_rev6_fine_grained_analysis.md)에 있다.

2026-10-09 batch64 추가 갱신: 실제 M=64 K/V projection의 C3/C4 두 실행이 PASSED여서 상위 전체 집계는 14개가 됐다. 기존 12개 값과 이 폴더의 검증 기록은 보존했다. QKᵀ 추가 실행은 제외했으며 실제 CLI M=8과 storage padding의 차이는 [전체 분석](../../c3_c4_rev6_fine_grained_analysis.md)에 기록했다.
