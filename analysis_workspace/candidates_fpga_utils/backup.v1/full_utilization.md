# Candidate full-design FPGA utilization

조회 시점: 2026-09-30T18:13:57+09:00. 입력 목록은 [candidate_fpga_bins.yaml](candidate_fpga_bins.yaml)이며, C1은 `tcu_th32_c1_rev2`를 사용했다.

FPGA shell, platform 연결 로직 및 Vortex 커널을 모두 포함하는 `level0_wrapper` 전체 자원 사용량이다. 각 칸은 **절대값 (U55C 전체 용량 대비 비율)**이다.

| Candidate | 보고서 단계 | LUT | FF | DSP | BRAM tile | URAM |
|---|---|---:|---:|---:|---:|---:|
| C1 | 최종 routed | 558,117 (42.81%) | 668,331 (25.63%) | 1,100 (12.19%) | 617.5 (30.63%) | 32 (3.33%) |
| C2 | **pre-opt; PnR 미완료** | 869,782 (66.72%) | 851,608 (32.66%) | 3,112 (34.49%) | 1,323.5 (65.65%) | 0 (0.00%) |
| C3 | 최종 routed | 731,331 (56.10%) | 675,852 (25.92%) | 2,056 (22.78%) | 750.5 (37.23%) | 92 (9.58%) |
| C4 | 최종 routed | 779,323 (59.78%) | 634,130 (24.32%) | 2,275 (25.21%) | 733.5 (36.38%) | 156 (16.25%) |

## 분모와 단위

| 자원 | U55C 전체 용량 | 집계 기준 |
|---|---:|---|
| LUT | 1,303,680 | CLB LUTs. C2는 최신 hierarchical 보고서의 최상위 Total LUTs 사용. |
| FF | 2,607,360 | CLB Registers. |
| DSP | 9,024 | DSP block 개수. |
| BRAM | 2,016 | 36 Kb tile 기준: RAMB36 + RAMB18 / 2. |
| URAM | 960 | URAM block 개수. |

비율은 `사용량 / 전체 용량 × 100`으로 다시 계산했다. RAMB18 한 개는 36 Kb BRAM tile의 절반이므로 BRAM 값에 `.5`가 나타날 수 있다.

## C2의 보고서 선택

- 지정된 C2 경로에는 completed placed/routed utilization 보고서나 opt/placed/routed checkpoint가 없다.
- 가장 최근 utilization 보고서는 `hier_utilization.rpt`이며, 생성 시각은 **2026-09-30 18:05:17**이다. 최상위 `level0_wrapper` 행을 사용했다.
- `xrt_backup/pre_opt_hook.tcl:16`에서 hierarchical 보고서를 생성하며, 실행 로그에서도 보고서 생성 직후 `Command: opt_design`이 확인된다. 따라서 실제 단계는 **linked pre-opt**다.
- 헤더의 `Design State : Physopt postRoute`는 전체 디자인에 이미 구현된 shell이 포함된 상태를 반영한다. C2 커널의 route 완료를 의미하지 않는다.
- 조회 시점에는 `.vivado.begin.rst`에 기록된 PID 2948077의 Vivado 프로세스가 살아 있고 `runme.log`가 `opt_design`의 timer update까지 진행한 상태였다. 지정된 현재 빌드 경로에서 실패 종료나 최종 PnR 완료는 확인되지 않았다. 이 표는 조회 시점에 확보된 마지막 보고서의 값이다.
- 이전 `init_report_utilization_0.rpt`(17:04:11)의 CLB LUTs는 **869,551 (66.70%)**이고 최신 hierarchical Total LUTs는 **869,782 (66.72%)**다. 이 표는 최신 보고서 값을 채택했다. 일반 CLB 보고서에는 LUT combining 보정이 적용되므로 LUT 집계 방식 차이를 함께 기록했다.
- C2의 BRAM은 `1295 + 57 / 2 = 1323.5` tile이다.

C2의 수치는 C1/C3/C4의 routed 수치와 구현 단계가 다르다. 최종 PnR 결과로 해석하지 않는다.

## 원본과 저장된 자료

| Candidate | 입력값 | 사용한 보고서 | 보고서 날짜 |
|---|---|---|---|
| C1 | `tcu_th32_c1_rev2` | [impl_1_full_util_routed.rpt](reports/C1_full_util_routed.rpt) | Wed Jul 22 03:24:28 2026 |
| C2 | `build/hw/syn/xilinx/xrt/th32_c1_tcu_naive_m32_tcol32_pnr_spreadlogic_high_20260930_1421_xilinx_u55c_gen3x16_xdma_3_202210_1_hw` | [hier_utilization.rpt](reports/C2_pre_opt_utilization_excerpt.rpt) | Wed Sep 30 18:05:17 2026 |
| C3 | `naive_gemm_th32_tcol32_hwexp_dcache` | [impl_1_full_util_routed.rpt](reports/C3_full_util_routed.rpt) | Tue Jul 21 19:45:16 2026 |
| C4 | `improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem` | [impl_1_full_util_routed.rpt](reports/C4_full_util_routed.rpt) | Sun Aug 30 06:37:16 2026 |

- [full_utilization.csv](full_utilization.csv): 절대값, 전체 용량, 반올림 전 비율 및 원본 보고서 경로.
- [full_utilization_sources.json](full_utilization_sources.json): 조회 시각, 입력 YAML snapshot/hash, 실제 빌드 경로, 보고서 헤더와 원본 행 번호.
- `reports/`: C1/C3/C4의 full routed 보고서 사본 및 C2의 최신 보고서 헤더·최상위 행 발췌.
