# KV quantization kernel 조건 변경의 latency 영향

2026-10-09. `kv_cache_quant_layout_fused_w4a16`의 최근 row-major 제한 추가를
전후 비교했다. **Prefill은 거의 동일하지만 decode append는 K +36.63%,
V +31.43% 느려졌다. 기존 tiled single-row fast path를 불필요하게 막은 성능 회귀다.**
측정 후 사용자 요청으로 조건 추가 3곳을 되돌렸다. 현재 공유 kernel.cpp는 HEAD 및
이 실험의 Before snapshot과 byte-for-byte 동일하다. After snapshot과 측정값은
성능 회귀 기록으로 보존했다. Decoder의 물리 행수/stride 인자 수정은 유지한다.

## 비교 조건

- 신규 configured build 두 개:
  `build_kv_quant_before_20261009/`, `build_kv_quant_after_20261009/`.
- Before: 현재 HEAD의 kernel.cpp. After: 작업트리 kernel.cpp.
  차이는 `src_layout == SRC_LAYOUT_ROW_MAJOR`를 넣은 조건문 3곳뿐이다.
  App과 관련 helper source snapshot은 `build_kv_quant_ab_20261009/sources/`에 보관했다.
- Variant: `prefill_reuse_inline_group1_source_weight_cursor` (tag9).
- 동일 host bench executable 및 runtime SHA256. Runtime은 현재 busy-poll 버전이다.
- C4: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update`,
  TH16/MXU16, 100 MHz. 같은 FPGA `0000:2a:00.1`, Slurm job 5762에서 A/B 교대로 실행.
- 각 case/version을 프로세스 3회, 각 프로세스에서 `--warmup=0 --iterations=3`으로 실행.
  아래 표는 과거 CSV의 warmup0/iterations1에 맞춰 **프로세스별 첫 launch 3회의 중앙값**이다.
  후속 launch 6회는 별도 표로 확인했다. 전원 측정은 실행하지 않았다.
- FPGA MCYCLE 기준이며 시간 환산은 cycles / 100 MHz. Host wall time은 runtime
  sleep 제거 영향이 있어 과거 CSV와 직접 비교하지 않았다.

과거 기준은 `outputs_llama3_main.th16_20261007_rev5_pipeline/C4/raw_db.csv`의
실측 행이다. 해당 KV quant 행은 rev4에서 재사용했으며 실제 image alias는
`improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_axi_fix`이다.
따라서 과거 대비에는 이미지·당시 소스 차이가 포함된다. **이번 조건 변경의 영향은
동일 현재 이미지에서 측정한 Before/After로 분리했다.** 기존 raw_db는 수정하지 않았다.

## FPGA cycles

| Case | 과거 CSV | Before | After | After / Before | After / 과거 |
|---|---:|---:|---:|---:|---:|
| Prefill K / 1024×128 | 2,194,157 | 2,192,971 | 2,193,104 | +0.006% | -0.048% |
| Prefill V / 1024×128 | 2,158,722 | 2,156,890 | 2,158,876 | +0.092% | +0.007% |
| Prefill K / 4096×128 | 8,457,108 | 8,460,211 | 8,457,064 | -0.037% | -0.001% |
| Prefill V / 4096×128 | 8,305,073 | 8,315,235 | 8,299,215 | -0.193% | -0.071% |
| Decode K append / 1×128 | 29,316 | 29,373 | 40,132 | +36.629% | +36.895% |
| Decode V append / 1×128 | 29,549 | 29,558 | 38,848 | +31.430% | +31.470% |

| Case | 과거 환산 ms | Before ms | After ms | 후속 launch After / Before |
|---|---:|---:|---:|---:|
| Prefill K / 1024×128 | 21.94157 | 21.92971 | 21.93104 | +0.080% |
| Prefill V / 1024×128 | 21.58722 | 21.56890 | 21.58876 | -0.052% |
| Prefill K / 4096×128 | 84.57108 | 84.60211 | 84.57064 | -0.024% |
| Prefill V / 4096×128 | 83.05073 | 83.15235 | 82.99215 | -0.013% |
| Decode K append / 1×128 | 0.29316 | 0.29373 | 0.40132 | +37.015% |
| Decode V append / 1×128 | 0.29549 | 0.29558 | 0.38848 | +31.611% |

모든 case는 N=128, QBLK=128이다. K는 signed asymmetric / GEMM-A source /
WTRANS1·QDIR0, V는 signed symmetric / GEMM-C source / WTRANS0·QDIR1이다.
K source_total_n=128, V source_total_n=1024, head offset=0을 과거와 동일하게 사용했다.
Decode는 source K=1, cache capacity65536, position1024에 한 token을 append한다.

## 원인과 수정 방향

이전 dispatcher는 `persistent_mode!=0, K=1, src_total_K=1` 등의 조건에서
전용 persistent fast path를 선택했다. 이번 변경이 row-major 조건을 추가해
latency_on_hw의 tiled 입력을 generic accessor 경로로 보냈다.

**물리 행수가 1이면 GEMM-A/C tiled 입력도 row-major처럼 연속이다.**
주소식에서 `cm=1, m0=0`이므로 `offset=(n/16)×1×16+n%16=n`이 된다.
따라서 이 경우 기존 contiguous fast path는 올바르며 row-major 제한이 불필요하다.

| Decode | Before instructions | After instructions |
|---|---:|---:|
| Decode K append / 1×128 | 29,078 | 37,485 |
| Decode V append / 1×128 | 27,883 | 35,694 |

Prefill은 persistent_mode=0이라 해당 경로 변경이 적용되지 않으며, 네 case 모두
Before/After instruction 수가 동일했다. 관측 cycle 차이는 0.2% 이내다.

연결 decoder의 padded single-row 입력은 **src_total_K=8**이다. 기존 조건도
`src_total_K==1`을 요구하므로 이미 이 fast path를 우회한다. 따라서 decoder에서
물리 행수/stride를 정확히 전달하는 수정은 유지하고, **공유 kernel의 row-major
조건 추가 3곳을 되돌리는 것이 맞다.** 이번 6-case A/B는 그 조건 변경만 분리했으며,
연결 decoder와 standalone bench의 서로 다른 layout/양자화 정책을 섞어 비교하지 않았다.

## 검증 범위 및 재현 자료

- 36회 bench 프로세스, 총 108회 kernel launch가 모두 returncode0으로 완료됐다.
- Before/After의 prefill K/V 1024 및 persistent append K/V correctness app도 PASS.
  주의: 기존 correctness app의 append helper는 row-major 입력을 사용한다.
  Bench 자체는 latency 측정용이며 tiled append 출력의 reference 검증을 수행하지 않는다.
- 원시 자료: `build_kv_quant_ab_20261009/`의 `cases.json`, `provenance.json`,
  `kernel_change.patch`, `runs.json`, `samples.csv`, `summary.json`, before/after 로그.
- 재현 script: 같은 폴더의 `build.sh`, `run.sh`, `run.py`, `summarize.py`.
  `run.sh`는 FPGA 1개를 할당한 srun 내부에서 실행하며, 각 configured build에서
  `ci/run_black.sh hw --no-srun --run-only --bench --fpga-bin <위 alias>`를 호출한다.
- [변경된 공유 kernel](../../../../tests/regression/kv_cache_quant_layout_fused_w4a16/kernel.cpp)
- [연결 decoder decode 결과](DECODE_B1_P1024.md)
