# Table VI / Fig. 15 FPGA 전환: 분석 및 실행 계획

상태: **승인된 native mapping 최소 실험 완료. 결과 및 재현 명령은 README.md와 results/에 저장. 원고 미수정.**
분석일: 2026-09-30. 현재 harness commit: `bc67d9555`.
Fig. 5와 같은 RTL 기준은 `f1f6303b112e060e56f0512294bd86f2be373b26`.
`vortex_fpint/`는 이 workspace에 없으며, 참고 자료는 현재 저장소의
`analysis_workspace/arr_level_comparison/`에 있음.

## 결론과 우선순위

1. Table VI: FPGA engine 자원/처리량 표로 교체 가능. **native DSP 매핑을 기본**으로
   하고 LUT, FF, DSP, BRAM36, URAM 및 MAC/cycle을 함께 보고한다.
2. Fig. 15a: WoQ/WKV의 자원별 breakdown과 증가량으로 교체 가능성이 높음.
   input scaler만의 비용은 기존 FPGA 계층 보고서에서 이미 확인됨.
   전체 WoQ→WKV overhead는 새 matched WoQ 합성이 필요함.
3. Fig. 15b: 기존 C4 post-route 계층 보고서로 자원별 breakdown 작성 가능.
   shell 포함/제외 및 메모리 분류를 먼저 고정한다.
4. 전력과 Fmax는 별도 단계. ASIC TOPS/W, power 비율을 FPGA 값으로 환산하지 않는다.
5. DSP-free 합성은 선택적인 민감도 실험으로만 수행한다. LUT 지표를 단순하게
   만들기 위한 기본 실험으로 삼지 않는다.

## 확인한 원래 실험의 범위

- 활성 원고: `paper/overleaf_fpga/main_highlight.tex:1633` 이후의
  `tab:array-level`, `fig:arr-level-break`, `fig:area-breakdown`.
  아래 `comment` 환경에는 이전 수치가 남아 있으므로 섞지 않는다.
- Table VI 실제 비교는 FP TCU / WoQ GEMM / WKV GEMM의 세 행이다.
  이 표 자체에는 AxCore, FIGLUT 등 타 논문 RTL이 들어 있지 않다.
- `analysis_workspace/arr_level_comparison/extract.py`는 TCU를 256 MAC/cycle,
  WoQ와 WKV를 각각 1024 MAC/cycle로 계산한다. 기존 caption의 단일
  “32x32 array” 표현을 모든 행에 적용하면 부정확하다.
- 원래 TCU는 ASIC용 BHF 구현이며, Fig. 5 FPGA TCU는 실제 Xilinx DSP/IP 구현이다.
  FPGA 결과는 새로운 backend의 결과로 명시한다.
- `hw/syn/synopsys/gemm_unit_breakdown/scripts/preprocess.py`는
  `hw/rtl/patch/`를 overlay하고 `FPU_FPNEW`를 사용한다.
  patch의 WKV/WoQ는 **ACC 저장소를 외부 포트로 뺀** 엔진이다.
  Fig. 5 FPGA의 `core/gemm/VX_gemm_unit`은 내부 256 KiB ACC를 포함한다.
- ASIC CSV의 WKV/WoQ area는 각각 699361.995 / 662696.067 um²이다.
  3.41%는 input scaler가 WKV 전체에서 차지하는 비율이고,
  전체 WKV 증가량 / WoQ는 약 5.53%다. 두 분모/의미를 구분해야 한다.
  원고의 5.2%는 면적 효율의 감소율이다.
- `hw/rtl/patch/VX_vec_fp16_mul.sv`와 FP32 관련 vector wrapper는
  `USE_LATENCY1_IP`를 전달하지 않는다. 반면 production GEMM은 명시적으로 1을
  전달한다. `LATENCY=0`은 FPNEW 쪽 입력-buffer 모델과 연결된 값이며
  Vivado IP의 0-cycle 지정이 아니다. 매크로만 바꾸면 기본 latency IP가
  선택되므로 기존 patch를 그대로 Vivado에 넣어 비교하지 않는다.
- 기존 `tb_VX_*gemm_unit_top.sv`는 랜덤 switching/FSDB용 벤치이다.
  valid를 높이고 랜덤 주소를 넣는 것만으로 기능·유효 처리량이 검증되지 않는다.

## 실제 FPGA 매핑에서 이미 확인한 사실

기존 Fig. 5 OOC synthesis + RAM patch + opt_design 결과이며 **새 측정이 아니다**.

| 범위 | LUT | FF | DSP | BRAM36 환산 | 명목 GOPS @100 MHz |
| --- | ---: | ---: | ---: | ---: | ---: |
| FP TCU (256 MAC/cycle) | 80662 | 126202 | 1024 | 1 | 51.2 |
| WKV production GEMM (1024 MAC/cycle) | 147203 | 50704 | 1857 | 58 | 204.8 |
| WKV 내 input scaler 32개 합계 | 3360 | 2304 | 32 | 0 | 해당 없음 |

scaler 합계는 `gen_in_scaler[0..31].u_in_scaler` 계층 행만 한 번씩 합산했다.
WKV 엔진의 LUT 대비 2.283%, DSP 대비 1.723%다. 이는 **부품 점유율**이며
새 WoQ 대비 증가량이나 모든 추가 mux/control 비용을 나타내지 않는다.

- `core/gemm/VX_pe_tree_new.sv:48`: 곱셈 product에 `use_dsp="yes"`.
- `libs/VX_reduce_tree_pipelined_v2.sv:120`: pair_sum에도 `use_dsp="yes"`.
- WKV `u_mxu` 계층에는 DSP 1696개가 있으며 PE self 행에는 1024개가 있다.
  따라서 GEMM DSP 전체를 FP scaler 또는 1024개의 곱셈만으로 설명할 수 없다.
  세부 primitive attribution은 구현 단계에서 추출한다.
- 실제 PE 입력 폭은 기본 매크로에서 signed 12-bit selected mantissa × INT4다.
  곱셈 후 block shift로 넓은 aligned 형식을 복원한다. “31-bit × INT4 곱셈
  1024개”라는 가정으로 FPGA 비용을 계산하면 안 된다.
- WoQ PE 파일은 현재 WKV PE의 이름/주석만 바꾼 사본이고, 둘 다 같은 DSP
  속성을 가진다. WoQ weight-register RTL은 column-load 경로를 제거한다.
- scaler의 추가 DSP 32개는 이미 존재하므로 “DSP는 같고 LUT만 증가”를 기본
  가정으로 삼을 수 없다. 전체 ΔDSP=32인지도 새 합성 전에는 확정하지 않는다.

## 지표와 그림 설계

주 표의 권장 열:
`engine, precision, MAC/cycle, reference MHz, LUT, FF, DSP, BRAM36eq, URAM,
nominal GOPS, GOPS/kLUT, GOPS/DSP`.

`GOPS = 2 * MAC_per_cycle * f_MHz / 1000` (II=1인 compute peak 기준).
현재 TCU 대비 WKV 수치는 GOPS/kLUT 2.19x, GOPS/DSP 2.21x지만,
이는 위 production scope에만 해당하며 새 WoQ/외부-ACC 비교 수치가 아니다.

- GOPS/kLUT는 **LUT 효율**, GOPS/DSP는 **DSP 효율**이다. 서로 다른 자원을
  공짜로 가정한 조건부 지표이므로 둘을 모두 표기하고 절대 자원 수를 남긴다.
- LUT+임의상수×DSP를 silicon area처럼 합산하지 않는다. BRAM/URAM도 LUT로
  환산하지 않는다. 필요하면 LUT/GOPS와 DSP/GOPS의 2차원 plot을 사용한다.
- `-max_dsp N`은 사용량 상한이지 동일 DSP 개수·동일 계산 능력 보장 수단이
  아니다. DSP padding 또는 이유 없는 매핑 변경으로 iso-DSP를 만들지 않는다.
- WoQ→WKV 증가량은 자원 r마다 `Δr=r_WKV-r_WoQ`, `Δr/r_WoQ`로 보고한다.
  scaler 점유율 `r_scaler/r_WKV`와 나란히 쓰되 혼동하지 않는다.
- Fig. 15a는 LUT와 DSP의 별도 stacked bars로 MXU/preprocess/postprocess/
  input scaler/control을 보여준다. FF/BRAM은 표로 보완한다.
- Fig. 15b는 자원마다 독립적인 막대/비율을 쓴다. ASIC의 단일 area pie나
  “memory 55%”, “tensor path 5.5%”를 그대로 유지하지 않는다.
- OOC 합성 단계에서는 100 MHz를 명목 기준으로만 쓴다. Fmax는 동일 조건의
  배치·배선 및 timing 검증을 수행한 뒤 OOC 또는 system scope를 명시한다.

## 권장 최소 실험: native mapping, 같은 production RTL 기반

### 단계 A — 기능과 경계 고정

- Fig. 5 config/도구/commit을 고정하고 기존 TCU/WKV 결과를 기준점으로 사용.
- production `VX_gemm_unit_top`을 감싸는 실험용 WoQ wrapper에서
  `ctrl_quant_dir=QDIR_COL` 및 weight-load 주소의 방향 bit `[1]=0`을
  **compile-time constant**로 만든다. buffer 선택 bit `[0]`, weight/activation/
  scale/zero-point 데이터와 합법적 제어 입력은 그대로 유지한다.
- quant_dir만 고정하면 weight transpose/load 경로가 남을 수 있다.
  `core/gemm/VX_gemm_unit.sv:466`의 두 독립 제어를 모두 제한해야 한다.
- 이는 “같은 FPGA 엔진에서 WKV 기능을 제거한 WoQ ablation”으로 명명한다.
  과거 ASIC의 별도 WoQ RTL과 bit-identical하다고 주장하지 않는다.
- WKV/WoQ는 같은 ACC 256 KiB, 같은 BRAM 정책, 같은 precision, 같은 pipeline,
  같은 FP IP settings/C_Rate=1을 사용한다. storage는 표에 별도 표시한다.
  TCU까지 iso-storage라고 부르지 않는다.
- 표 제목은 이 경계를 반영한 “FPGA compute-engine resource efficiency”로
  바꾸는 것이 적절하다. 논문 수정은 이 계획의 범위 밖이다.

엄밀히 기존 ASIC의 “ACC 제외 engine” 경계를 유지해야 한다면, 위 **두 엔진
모두**에 동일한 ACC-externalization adapter를 적용해 다시 합성한다.
한쪽에만 patch를 쓰거나 기존 hierarchy의 RAM/LUT 값을 단순히 빼지 않는다.
이 추가 실험은 최소 실험과 다른 scope ID로 기록하고 수치를 혼합하지 않는다.

### 단계 B — 작은 기능 검증 후 합성

- 먼저 WoQ와 WKV의 Q-COL/row-load 동작을 같은 입력으로 비교한다.
  scale/zero-point, double-buffer 전환, 복수 K tile 누산, output backpressure,
  reset/flush를 포함한 self-checking 검증이 필요하다.
- WKV Q-ROW와 column-load 기능은 별도로 확인하여 대조군을 만드는 과정에서
  WKV 기능 자체를 상수화하거나 잘라내지 않았음을 검증한다.
- Xilinx FP IP 모델에서 latency와 valid/data 정렬, C_Rate=1을 확인한다.
  기존 랜덤 power bench는 이 검증을 대체하지 않는다.
- 이후 Fig. 5와 같은 OOC → async-BRAM patch → constrained opt_design.
  WoQ 신규 측정과 기존 WKV/TCU의 도구·source hash·IP config가 일치할 때만
  기존 결과를 재사용한다. 공통 RTL/config 변경이 필요하면 matched pair 재합성.
- 성공 조건: blackbox=0, 모든 sequential clock 정의, 기대한 연산 경로 유지,
  1024-MAC 구조/합법적 출력 유지, WoQ 전용 제거 경로 확인, hierarchy sum 검증.
- hierarchy 합성 최적화가 logic을 다른 scope로 옮길 수 있으므로 실제
  WKV-WoQ top 차이와 input-scaler hierarchy 귀속 비용을 분리한다.

### 단계 C — 필요할 때만 DSP-free 민감도 실험

- 목적은 “동일 device에서 DSP를 사용하지 않았을 때도 경향이 유지되는가”이다.
- signal-level `use_dsp="yes"`를 포함해 multiplier, reduction, zero-point,
  기타 inferred arithmetic의 매핑 정책을 모두 점검한다.
- 모든 사용 FP IP를 별도 module/cache 이름으로 생성하고
  `C_Mult_Usage=No_Usage` 등 해당 IP의 무-DSP 설정을 명시한다.
  단순 top-level `use_dsp=no`나 합성 `-max_dsp 0`만으로 충분하다고 가정하지 않는다.
- 새 XCI의 precision/rounding/exception/handshake/latency/rate를 비교하고
  실제 `DSP48E2==0`, unresolved blackbox==0을 검사한다.
- latency 변경이 필요하면 모든 관련 sideband/bypass 경로를 맞추고 재검증한다.
  실현 불가능한 100 MHz에 명목 GOPS를 붙여 achieved efficiency로 보고하지 않는다.
- “DSP-free”여도 FF/CARRY/BRAM/URAM은 남는다. 전체 비용이 LUT 하나로
  표현된다는 뜻이 아니다. native 결과와 별도 열/그림으로 분리한다.

## Fig. 15b: 기존 C4 post-route 자료를 먼저 사용

확인한 경로:
`/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin/`.
`hier_utilization.rpt`는 Vivado 2025.1의 `Physopt postRoute` 결과다.
같은 폴더에 `impl_1_full_util_routed.rpt`와 routed timing report가 있다.

- 전체 `level0_wrapper`: 809907 LUT / 643744 FF / 2275 DSP /
  703 RAMB36 + 65 RAMB18 / 156 URAM.
- `vortex_afu_1`: 632736 LUT / 424927 FF / 2271 DSP /
  506 RAMB36 + 59 RAMB18 / 156 URAM.
- GEMM 계층: 148898 LUT / 50391 FF / 1857 DSP / 60 URAM.
  이는 ACC가 BRAM인 Fig. 5 OOC와 다른 구현이므로 합쳐 쓰지 않는다.

shell/PCIe/XRT infrastructure와 accelerator를 분리하고 SIMT, cache/LMEM,
TMEM, ACC, GEMM logic, T-DMA, interconnect, residual을 비중복 집계한다.
현재 계층의 기본 백분율은 partition 기준이 섞이고 URAM에 0.00%도 나오므로
그대로 복사하지 말고 선택한 분모(예: accelerator total)로 다시 계산한다.
같은 계층 안의 primitive를 자원 유형별로 분류해 합계 일치를 검증한다.

C1/C3도 위와 같은 이름의 보고서가 있지만, C2 지정 bin 경로에서는 해당
세 파일을 찾지 못했다. Fig. 15b의 C4 재작성은 가능하고, C1–C4 확장은 별도
report discovery와 build provenance 확인 후 진행한다.
기존 `hw/syn/xilinx/xrt/report_memory_system_cost.tcl`은 fabric/DMA/storage
분류와 routed 지표 추출의 참고가 된다.

## 전력 실험의 별도 조건

TOPS/W 및 scaler power 0.60%는 이번 자원 실험에서 대체 값을 내지 않는다.
추가하려면 합법적 traffic과 충분한 warmup/active 구간의 activity를 수집하고,
같은 동작/처리량 조건의 post-route SAIF-annotated power를 비교해야 한다.
annotation coverage, clocks, voltage/temperature, static/dynamic, region scope를
기록하며 vectorless 기본값이나 ASIC FSDB 결과를 실측 board power로 부르지 않는다.
board TOPS/W나 J/token은 전체 시스템 실제 처리량과 전력 측정의 별도 실험이다.

## 재현 산출물 계획

Fig. 5 harness를 재사용하되 기존 dataset은 수정하지 않는다.
새 scope/mapping별 config, RTL commit/patch diff, 151-file 방식의 dependency
snapshot hashes, XCI/resolved IP properties, synthesis/implementation commands,
clock constraints, reports, checkpoint hashes, functional test seed/log,
resource attribution rules, CSV/JSON/PDF, report-to-CSV verifier를 저장한다.

최소 구성의 결과 ID는 `fp_tcu_native`, `wkv_native`, `woq_derived_native`.
외부 ACC/무-DSP 실험은 별도 suffix를 사용한다. 새 결과는 raw counts와 실제
source provenance가 확보된 뒤에만 최종 표/그림으로 확정한다.
현재 계획 단계에서 확인한 preliminary data는 `results/provenance/analysis_evidence.json`에 저장했다.

## Vendor 근거

- AMD UG901 2025.1 USE_DSP: signal 속성이 module 속성보다 우선하며
  산술 구조의 DSP 추론 정책을 조절한다.
  https://docs.amd.com/r/2025.1-English/ug901-vivado-synthesis/USE_DSP
- AMD Floating-Point Operator v7.1 PG060: DSP slice usage 설정과 latency/
  cycles-per-operation은 별개의 선택이고 rate>1은 하드웨어 재사용을 의미한다.
  https://docs.amd.com/api/khub/documents/ym1A7qsltTGP_saZFTrikQ/content
