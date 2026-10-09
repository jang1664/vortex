# rev6 C3/C4 fine-grained 측정 자료

2026-10-09 갱신. 일곱 case의 C3/C4 조합 **14개 모두 reference 검증을 통과**했다. 기존 12개 결과를 보존하고 Llama3 decode batch64 K/V projection의 실제 M=64 실행 두 개를 추가했다. QKᵀ 추가 실행은 사용자 요청으로 제외했으며, latency_on_hw benchmark가 논리 M=4를 실제 CLI M=8로 변환하는 차이를 기록했다.

[전체 분석](../c3_c4_rev6_fine_grained_analysis.md) · [QBLK 16/32/64/128 검증](qblk_support_rerun_20261009/README.md)

## 실행 범위

| workload | M × N × K | QBLK / WTRANS / QDIR | C3 | C4 |
|---|---|---|---|---|
| small | 16 × 32 × 32 | 32 / 0 / 0 | PASSED | PASSED |
| llama3_kv_decode | 1 × 1024 × 4096 | 32 / 0 / 0 | PASSED | PASSED |
| llama3_attention_decode | 4 × 1025 × 128 | 128 / 1 / 0 | PASSED | PASSED |
| llama2_ffn_decode | 1 × 11008 × 4096 | 32 / 0 / 0 | PASSED | PASSED |
| llama3_kv_decode_m4 | 4 × 1024 × 4096 | 32 / 0 / 0 | PASSED | PASSED |
| llama2_ffn_decode_m4 | 4 × 11008 × 4096 | 32 / 0 / 0 | PASSED | PASSED |
| llama3_kv_decode_b64_20261009 | 64 × 1024 × 4096 | 32 / 0 / 0 | PASSED | PASSED |

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

- `measurements.csv`: 현재 14개 passing 실행의 주요 지표.
- `measurements.json`: 전체 카운터, per-port/per-bank 및 window 통계(로컬 생성 자료).
- `overview.png`, `hbm_windows.png`: 기존 결과와 M=4·M=64 projection을 포함한 최신 비교 그림.
- `llama3_decode_batch64.png`: K/V M=1·4·64 × C3/C4의 주요 지표 비교.
- `raw/{c3,c4}_llama3_kv_decode_b64_20261009.*`: 실제 M64 명령·정답 검증·계측·모델·소스·바이너리.
- `raw/batch64_qkt_argument_audit_20261009.json`: 기존 QKT의 실제 CLI M8 실행과 저장 공간 padding의 차이 근거.
- `projection_m1_m4.png`: M=1/M=4 × C3/C4의 GEMM 시간·유효 MXU utilization·GEMM AXI bandwidth·DMA–pipeline overlap 비교.
- `raw/{c3,c4}_{llama3_kv_decode,llama2_ffn_decode}_m4.*`: 새 네 실험의 원시 로그·명령·모델 manifest.
- `raw/m4_projection_launch_sources/`, `raw/m4_projection_binaries/`: 측정 당시 소스와 실제 사용한 host/kernel 바이너리.
- `effective_peak_pct`는 유효 MXU utilization, `pipeline_util_pct`는 nonempty 비율, `dma_pipeline_overlap_pct`는 DMA-active 중 pipeline-nonempty 비율이다.
- `raw/c3_llama3_attention_decode.{json,log,simv.log,model.json}`: 이번 보완 실행 명령·검증 로그·계측·모델.
- `raw/attempts/c3_attention_qblk32_assertion_20261008/`: 최초 assertion 실패 기록. 분석에서는 제외.
- `qblk_support_rerun_20261009/`: 앞선 QBLK별 검증과 M4 재실행 기록. 현재 전체 분석에는 이번 `raw/`의 보완 실행을 사용한다.
- `provenance.json`: 최초 측정, C3 attention 보완, M=4 projection의 source/config/monitor/model 비교와 실제 M 검증을 보존. 대응 M=1과 config·monitor 해시 및 model manifest가 일치한다. 실제 측정 바이너리는 baseline과 비교 가능해 M=1을 재실행하지 않았다.

## 재현

프로젝트 root에서 configured build와 monitor가 준비된 상태로:

```bash
python3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --candidate c3 --case llama3_attention_decode --timeout 1800
python3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case llama3_kv_decode_m4 --case llama2_ffn_decode_m4 --timeout 7200
python3 analysis_workspace/latency/docs/perf_rev6/tools/run_cases.py --case llama3_kv_decode_b64_20261009 --timeout 10800
python3 analysis_workspace/latency/docs/perf_rev6/tools/analyze.py
/home/jaeyongjang/.conda/envs/vortex/bin/python analysis_workspace/latency/docs/perf_rev6/tools/render_results.py
```

새 batch64 ID의 raw 파일이 이미 존재하면 실행 스크립트는 덮어쓰기 대신 오류를 낸다. 재측정은 기존 자료를 보존하고 새 case ID 또는 별도 출력 디렉터리를 사용해야 한다.

`tools/setup_builds.py`는 build를 configure하고 passive monitor 및 naive FSM source의 simv dependency를 추가한다. 처음 준비할 때 사용한다. 실행 스크립트는 각 build에서 rev6 config를 source하고 `ci/run_black.sh xrt-vcs-sim --perf 3`을 호출한다. 정답 검증과 AXI/window/cycle/local-memory accounting 검사가 모두 통과한 자료만 집계한다.

기존 FFN 두 실행은 당시 controller 종료 상태를 복구할 수 없어 returncode가 null이며, reference `PASSED`와 정상 simulator SHUTDOWN 기록으로 통과를 확인했다. 이번 C3 attention 보완 실행은 returncode=0을 직접 확보했다.

<!-- M4_PROJECTION -->
## Projection M=1/M=4 비교

| projection | M | backend | GEMM cycles | MXU 유효 util. % | GEMM AXI GB/s | DMA–pipeline overlap % | C4/C3 GEMM speedup |
| --- | --- | --- | --- | --- | --- | --- | --- |
| llama3_kv_decode | 1 | C3 | 219,638 | 7.460 | 1.202 | 56.499 | 1.882 |
| llama3_kv_decode | 1 | C4 | 116,716 | 14.037 | 2.304 | 99.548 | 1.882 |
| llama3_kv_decode | 4 | C3 | 224,586 | 29.181 | 1.202 | 74.315 | 1.929 |
| llama3_kv_decode | 4 | C4 | 116,399 | 56.303 | 2.484 | 99.230 | 1.929 |
| llama2_ffn_decode | 1 | C3 | 2,399,965 | 7.339 | 1.183 | 55.150 | 1.916 |
| llama2_ffn_decode | 1 | C4 | 1,252,396 | 14.063 | 2.308 | 99.664 | 1.916 |
| llama2_ffn_decode | 4 | C3 | 2,467,912 | 28.547 | 1.175 | 72.790 | 1.977 |
| llama2_ffn_decode | 4 | C4 | 1,248,257 | 56.440 | 2.490 | 99.381 | 1.977 |

MXU 유효 utilization은 `100×2MNK/(cycles×512)`이며 padding 연산을 제외한다. overlap은 DMA-active 시간 중 pipeline-nonempty와 겹친 비율이고 실제 MAC-active 비율이 아니다. C4/C3 speedup은 C3 cycles/C4 cycles이다. input/weight beats·traffic·M 변화 해석은 [전체 분석](../c3_c4_rev6_fine_grained_analysis.md)에 있다.

![M1/M4 projection 비교](projection_m1_m4.png)
<!-- /M4_PROJECTION -->

M=4 신규 실험은 모두 returncode=0과 CPU reference `PASSED`를 직접 확보했다. 기존 로그를 덮어쓰지 않고 `_m4` 원시 파일명을 사용했다. 이 측정 작업에서는 RTL/kernel 기능·성능을 바꾸지 않았다. 다른 작업의 C4 host TMEM helper 변경은 두 C4 실험 시작 후 발생했고 실제 사용한 Oct-8 host/kernel 바이너리는 변경되지 않았다. 현재 checkout은 launch snapshot과 다르므로 정확한 재현에는 `raw/m4_projection_launch_sources/` 및 provenance의 측정 소스/바이너리 이력을 확인한다.

<!-- BATCH64_DECODE -->
## Llama3 decode batch 64: K/V projection

KV cache 1024의 첫 decode token을 기준으로 K/V projection 각각의 shape는 `M=64, N=1024, K=4096, QBLK=32, WTRANS=0, QDIR=0`이다. 동일 shape의 standalone deterministic vector 실행 하나를 K/V 공통 microbenchmark로 사용했다. 두 후보 모두 실제 M=64, REPS=1, CPU reference PASSED이고 accepted input fire=1,048,576을 확인했다. 두 다른 학습 weight를 각각 실행하거나 전체 batch decoder를 실행한 결과는 아니다. [생성 workload manifest](raw/llama3_decode_b64_shape_manifest_20261009.json)에 shape와 호출 수를 보존했다.

| 측정 단위 | backend | GEMM cycles | GEMM µs | 유효 MXU % | GEMM AXI GB/s | DMA–pipeline overlap % | C4/C3 speedup |
| --- | --- | --- | --- | --- | --- | --- | --- |
| KV M=1 | C3 | 219,638 | 2,196.380 | 7.460 | 1.202 | 56.499 | 1.882 |
| KV M=1 | C4 | 116,716 | 1,167.160 | 14.037 | 2.304 | 99.548 | 1.882 |
| KV M=4 | C3 | 224,586 | 2,245.860 | 29.181 | 1.202 | 74.315 | 1.929 |
| KV M=4 | C4 | 116,399 | 1,163.990 | 56.303 | 2.484 | 99.230 | 1.929 |
| KV M=64 | C3 | 1,146,321 | 11,463.210 | 91.473 | 0.354 | 99.608 | 1.086 |
| KV M=64 | C4 | 1,055,150 | 10,551.500 | 99.377 | 0.658 | 99.459 | 1.086 |

| 측정 단위 | backend | input fire | weight beats | input rows / 4-beat weight tile | GEMM AXI read B | write B | local physical read B | write B |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| KV M=1 | C3 | 16,384 | 65,536 | 1.000 | 2,638,976 | 1,792 | 3,672,064 | 2,689,024 |
| KV M=1 | C4 | 16,384 | 65,536 | 1.000 | 2,686,976 | 2,048 | 3,672,064 | 2,689,024 |
| KV M=4 | C3 | 65,536 | 65,536 | 4.000 | 2,691,840 | 7,232 | 5,251,072 | 2,891,776 |
| KV M=4 | C4 | 65,536 | 65,536 | 4.000 | 2,883,584 | 8,192 | 5,251,072 | 2,891,776 |
| KV M=64 | C3 | 1,048,576 | 65,536 | 64.000 | 3,927,808 | 130,112 | 36,831,232 | 6,946,816 |
| KV M=64 | C4 | 1,048,576 | 65,536 | 64.000 | 6,815,744 | 131,072 | 36,831,232 | 6,946,816 |

C3 K/V M=4→64: 연산량은 16배, latency는 5.104배, 유효 throughput은 3.135배다. input fire는 65,536→1,048,576, weight beats는 65,536→65,536다. Weight tile당 관측 input rows는 4.0→64.0로 변했다. 이 관측 비율로 weight tile의 64-row 재사용 여부를 확인한다. AXI bytes는 1.503배, bandwidth는 0.295배이고 후자는 bytes/time에서 계산되므로 독립적인 speedup 원인 증거가 아니다.

C4 K/V M=4→64: 연산량은 16배, latency는 9.065배, 유효 throughput은 1.765배다. input fire는 65,536→1,048,576, weight beats는 65,536→65,536다. Weight tile당 관측 input rows는 4.0→64.0로 변했다. 이 관측 비율로 weight tile의 64-row 재사용 여부를 확인한다. AXI bytes는 2.402배, bandwidth는 0.265배이고 후자는 bytes/time에서 계산되므로 독립적인 speedup 원인 증거가 아니다.

Batch 64 K/V에서 C4/C3 GEMM speedup은 1.086배이며 유효 MXU utilization은 C3 91.47%, C4 99.38%다. M=4에서의 C4/C3 speedup 1.929배와 함께 보고, 작은 M의 공급·스케줄링 이점이 batch 64에서도 유지되는지 판단한다. Pipeline overlap 99.61%/99.46%는 pipeline-nonempty가 DMA-active와 겹친 비율이며 MAC-active 비율이 아니다. 미구현 stall counter의 0은 stall 부재로 해석하지 않는다.

M=4→64에서 C4/C3 speedup은 1.929→1.086배로 줄었다. Batch64에서는 C4가 더 빠르다. 큰 M에서 공급·스케줄링 경로의 상대 이점을 작은 M과 같은 배수로 일반화하지 않는다. M64의 유효 peak 비율 자체는 C3 91.47%, C4 99.38%로 관측했으며, 이 결과를 M1/M4에서도 같은 utilization을 유지했다는 증거로 사용하지 않는다.

C3는 M=4→64에서 유효 utilization 29.18%→91.47%, GEMM AXI bandwidth 1.202→0.354 GB/s다. Array utilization 증가와 HBM bandwidth 변화의 방향을 함께 확인해야 하며, bandwidth만으로 compute 활용도나 memory 병목을 판단하지 않는다.

C4는 M=4→64에서 유효 utilization 56.30%→99.38%, GEMM AXI bandwidth 2.484→0.658 GB/s다. Array utilization 증가와 HBM bandwidth 변화의 방향을 함께 확인해야 하며, bandwidth만으로 compute 활용도나 memory 병목을 판단하지 않는다.

Model manifest, config·monitor 및 kernel binary 해시가 기존 cohort와 일치한다. 기존 C4 host의 TMEM allocator helper 추출은 할당식·순서·512 B 정렬·용량을 보존하고 이번 실행에서 제품 RTL/kernel을 변경하지 않았다. 이 근거로 기존 M1/M4를 비교에 재사용했다. 실행 시점 source snapshot과 실제 바이너리 및 비교 증거는 [provenance.json](provenance.json)에 보존한다.

전체 출력 DMA endpoint는 두 후보 모두 131,072 B로 검증됐다. GEMM-active AXI write는 C3 130,112 B, C4 131,072 B이며, C3에서는 GEMM-active gate가 마지막 output drain의 일부를 제외한다. Core-active AXI write는 각각 133,213/133,076 B로 epilogue·부수 traffic도 포함한다. 따라서 output 진행 중 16,384 B 단위의 write milestone은 간접 지표이며 직접 tile-done signal이 아니다. 최종 종료·출력 DMA 전체 byte·CPU reference PASSED를 함께 확인했다. AXI window/tail 합계는 각각의 관찰 구간 합계와 정확히 일치한다.

### QKᵀ 추가 실행 제외와 benchmark의 M 정렬 문제

사용자 요청에 따라 QKᵀ 추가 측정은 시작 전에 제외했다. GQA 논리 shape는 batch 64여도 `4×1025×128`이고 호출 수가 layer당 `64×8=512`로 늘어난다. 기존 perf_rev6의 QKᵀ 결과는 CLI `-m 4`를 주고 실제 input 4 rows를 공급한 측정이다. 반면 현재 `latency_on_hw` canonicalization은 M을 8, N을 32의 배수로 올리고 runner가 변환된 `measurement_args`를 전달한다. 기존 C4 rev4/rev5 raw DB에서도 **`-m 8 -n 1056 -k 128 -q 128 -t 1 -d 0`**를 확인했다. 이것은 저장 공간만 M_pad=8로 잡고 실제 M=4를 연산하는 host 동작과 다르며, 실제 8 rows를 실행한 benchmark다. 따라서 그 latency를 실제 4-row QKᵀ의 측정값으로 표현하거나 두 결과를 혼합하지 않는다. 본 작업에서는 해당 pipeline 설정이나 kernel을 변경하지 않았다. K/V M=64는 정렬 전후 인자가 같아 이 M 증가 문제의 영향을 받지 않는다.

Batch 전체 QKT 시간이나 전체 decoder latency는 이번에 측정하지 않았다. 기존 단일 호출 latency×512는 직렬 합산 추정으로만 사용할 수 있고 host launch·cache residency·fusion·서로 다른 KV 데이터 효과를 측정한 값은 아니다.

![Llama3 decode batch64 K/V 비교](llama3_decode_batch64.png)

<!-- /BATCH64_DECODE -->
