# rev6 C3/C4 fine-grained 측정 자료

2026-10-09 갱신. 네 workload의 C3/C4 조합 **8개 모두 reference 검증을 통과**했다. 기존에 누락됐던 C3 M4 attention을 `xrt-vcs-sim --perf 3`으로 보완 측정해 표·그림·CSV에 포함했다.

[전체 분석](../c3_c4_rev6_fine_grained_analysis.md) · [QBLK 16/32/64/128 검증](qblk_support_rerun_20261009/README.md)

## 실행 범위

| workload | M × N × K | QBLK / WTRANS / QDIR | C3 | C4 |
|---|---|---|---|---|
| small | 16 × 32 × 32 | 32 / 0 / 0 | PASSED | PASSED |
| llama3_kv_decode | 1 × 1024 × 4096 | 32 / 0 / 0 | PASSED | PASSED |
| llama3_attention_decode | 4 × 1025 × 128 | 128 / 1 / 0 | PASSED | PASSED |
| llama2_ffn_decode | 1 × 11008 × 4096 | 32 / 0 / 0 | PASSED | PASSED |

## 보완된 M4 attention 결과

| 지표 | C3 naive | C4 improve |
|---|---:|---:|
| GEMM cycles | 7,596.000 | 5,324.000 |
| GEMM 시간 | 75.960 µs | 53.240 µs |
| 전체 core 시간 | 174.670 µs | 143.300 µs |
| MXU input utilization | 27.383% | 39.068% |
| pipeline active | 76.435% | 71.112% |
| GEMM AXI 평균 | 1.041 GB/s | 1.659 GB/s |
| GEMM window min | 0.169 GB/s | 0.569 GB/s |
| GEMM window max | 1.750 GB/s | 2.938 GB/s |
| GEMM window mean | 1.088 GB/s | 1.712 GB/s |
| GEMM window median | 0.975 GB/s | 1.894 GB/s |
| local memory read | 174,624 B | 174,720 B |
| local memory write | 87,744 B | 88,320 B |
| collision event | 6,798 LMEM bank_stalls | 712 denied requester |

C4는 M4 attention에서 GEMM 구간 1.427배, 전체 core 구간 1.219배 빠르다. bank collision 수는 backend마다 단위와 관찰 지점이 달라 직접 비율 비교하지 않는다. GEMM window는 1,024 cycles이며 tail은 min/max/mean/median에서 제외한다. bandwidth는 uncalibrated VCS 모델의 관찰값이다.

## 자료 구성

- `measurements.csv`: 현재 8개 passing 실행의 주요 지표.
- `measurements.json`: 전체 카운터, per-port/per-bank 및 window 통계(로컬 생성 자료).
- `overview.png`, `hbm_windows.png`: C3 attention을 포함한 최신 비교 그림.
- `raw/c3_llama3_attention_decode.{json,log,simv.log,model.json}`: 이번 보완 실행 명령·검증 로그·계측·모델.
- `raw/attempts/c3_attention_qblk32_assertion_20261008/`: 최초 assertion 실패 기록. 분석에서는 제외.
- `qblk_support_rerun_20261009/`: 앞선 QBLK별 검증과 M4 재실행 기록. 현재 전체 분석에는 이번 `raw/`의 보완 실행을 사용한다.
- `provenance.json`: 최초 측정 이력과 C3 보완 측정 이력을 구분해 보존.

## 재현

프로젝트 root에서 configured build와 monitor가 준비된 상태로:

```bash
python3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --candidate c3 --case llama3_attention_decode --timeout 1800
python3 analysis_workspace/latency/docs/perf_rev6/tools/analyze.py
/home/jaeyongjang/.conda/envs/vortex/bin/python analysis_workspace/latency/docs/perf_rev6/tools/render_results.py
```

`tools/setup_builds.py`는 build를 configure하고 passive monitor 및 naive FSM source의 simv dependency를 추가한다. 처음 준비할 때 사용한다. 실행 스크립트는 각 build에서 rev6 config를 source하고 `ci/run_black.sh xrt-vcs-sim --perf 3`을 호출한다. 정답 검증과 AXI/window/cycle/local-memory accounting 검사가 모두 통과한 자료만 집계한다.

기존 FFN 두 실행은 당시 controller 종료 상태를 복구할 수 없어 returncode가 null이며, reference `PASSED`와 정상 simulator SHUTDOWN 기록으로 통과를 확인했다. 이번 C3 attention 보완 실행은 returncode=0을 직접 확보했다.
