# GEMM-C를 GEMM-A layout으로 통일하는 RTL 및 cycle 비교 계획

작성일: 2026-10-06

상태: 2026-10-06 실행 완료. Baseline 및 수정 후 세 성능 case 모두 PASS. 결과는 [SUMMARY.md](gemm_c_to_a_layout_64b_store_results/SUMMARY.md)에 기록했다.

## 1. 목표와 실행 순서

현재 Improve GEMM-A의 layout을 기준으로 GEMM-C를 통일한다. 각 L1 DMA tile 내부에서는 실제 M행만 microtile 순서대로 연속 배치하고, M padding 공간은 해당 DMA tile 끝에 둔다.

출력은 L1 tile 전체가 준비될 때까지 모으지 않는다. 외부 DMA 정렬을 만족하는 최소 microtile 묶음이 LMEM에 준비되면 바로 store 명령을 발행해 입력/출력 DMA 교대 기회를 유지한다.

사용자 요청 순서를 반드시 지킨다.

1. **수정 전 RTL 및 기존 host로** M=1,4,256 / K=N=256의 functionality와 cycle baseline을 모두 확보한다. 모든 실행에 `--perf 3`을 사용한다.
2. RTL, 출력 layout을 해석하는 host 코드 및 직접 관련 검증 코드를 수정한다.
3. 같은 config, 같은 shape와 인자로 다시 VCS simulation을 실행하고 cycle 차이를 정리한다.

이번 문서는 실행 계획이다. 실제 작업을 시작할 때 blackbox 실행에는 `run-bb-common`, RTL 구현/검증에는 `rtl-improve` skill 절차를 따른다.

## 2. 고정할 실험 환경

| 항목 | 값 |
|---|---|
| App | `fpint_gemm_ffn_hw` |
| 실행 방식 | configured `build/`에서 `ci/run_black.sh xrt-vcs-sim` |
| Config | `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh` |
| Config 선택 근거 | `ci/fpga_bin_alias_map.yaml`의 `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_axi_fix`가 이 config를 참조 |
| Thread / MXU | TH16 / 16×16 |
| Shape | `(M,K,N) = (1,256,256), (4,256,256), (256,256,256)` |
| Quantization 및 반복 | `-q 32 -t 0 -d 0 -r 1`로 기존 기본값을 명시 |
| Performance counter | `--perf 3` |
| Functionality | reference 검증 활성화. `-p`, `--bench`, poll-only mode 사용하지 않음 |

`_axi_fix`는 FPGA binary alias이며 같은 이름의 config 파일은 없다. VCS에서는 위 config를 source하고 현재 worktree의 RTL을 compile한다. 하드웨어 binary 실행 결과를 baseline으로 대신하지 않는다.

사용자가 표기한 `-M/-K/-N`에 대응하는 이 앱의 실제 CLI는 **소문자 `-m/-k/-n`**이다.

## 3. 수정 전 baseline 보존

### 3.1 사전 확인

- `build/`를 사용하는 기존 simulation/build 프로세스가 없는지 확인한다. 세 shape는 같은 build에서 순차 실행한다.
- RTL, config, host, toolchain 상태를 기록한다: Git HEAD, worktree diff/status, config 원본 및 확장된 `CONFIGS`, configure 인자, VCS/compiler 버전, DMA 관련 환경변수/seed.
- 현재 worktree의 미커밋 변경은 baseline의 일부로 기록하고 임의로 정리하거나 되돌리지 않는다.
- source/template와 configure로 생성된 build 파일을 구분한다. 실제 compile 입력이 현재 source와 일치하는지 확인한다.
- 로그와 결과는 build 밖에 보관해 이후 configure/rebuild로 덮어쓰지 않도록 한다. 기존 결과 경로가 있으면 새로운 suffix를 사용한다.

권장 결과 경로:

```text
analysis_workspace/latency_on_hw/docs/gemm_c_to_a_layout_64b_store_results/
  baseline/                 # shape별 wrapper/simv 로그, exit status, counter
  modified/                 # 같은 세 shape의 수정 후 결과
  directed/                 # tail, odd M, repeated job 검증
  metadata/                 # config, source 상태, 명령어, 환경
  comparison.csv
  SUMMARY.md
```

### 3.2 실행 명령

아래는 Bash에서 실행할 baseline 명령이다. 로그 경로가 새 경로인지 먼저 확인한다.

```bash
set -euo pipefail
repo_root=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
results_root="$repo_root/analysis_workspace/latency_on_hw/docs/gemm_c_to_a_layout_64b_store_results"
mkdir -p "$repo_root/build" "$results_root/baseline" "$results_root/metadata"
cd "$repo_root/build"
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
source "$repo_root/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh"

for gemm_m in 1 4 256; do
  bash ci/run_black.sh xrt-vcs-sim \
    --app fpint_gemm_ffn_hw \
    --args "-m $gemm_m -k 256 -n 256 -q 32 -t 0 -d 0 -r 1" \
    --perf 3 \
    2>&1 | tee "$results_root/baseline/m${gemm_m}_k256_n256.log"
done
```

각 run이 종료되면 다음 run 전에 별도 `simv` 로그 등 wrapper가 덮어쓸 수 있는 자료도 해당 shape 디렉터리에 보존한다. Shell 종료 코드와 앱의 전체 functionality 결과를 모두 확인한다.

**세 baseline이 모두 PASS하고 counter와 원본 로그가 보존되기 전에는 RTL/host를 수정하지 않는다.** Baseline 실패 시 먼저 원인을 기록하고 해결하며, 해결 과정에서 RTL/host가 달라졌다면 세 baseline을 그 상태로 다시 확보한다.

## 4. 구현할 output layout 및 묶음 규칙

### 4.1 주소 정의

현재 output은 `align8(cur_m) × MXU_NT × 2` 간격으로 microtile을 저장한다. 수정 후에는 다음 배치를 사용한다.

```text
micro_bytes = cur_m × MXU_NT × FP16_BYTES

DRAM address = output_M_tile_base
             + global_N_DMA_tile_index × align8(cur_m) × DMA_NT × FP16_BYTES
             + local_microtile_index × micro_bytes

LMEM address = output_buffer_base + local_microtile_index × micro_bytes
```

M tile base, partition의 `m_start/n_start`, N tail은 기존 전역 좌표 의미를 유지한다. 마지막 N DMA tile의 예약 크기는 유효한 실행 N폭을 기준으로 계산해 host와 맞춘다.

A의 packing과 input DMA/연산 bound는 변경하지 않는다. GEMM-C를 다음 GEMM-A로 직접 사용할 수 있는 조건은 양쪽의 M tile 크기, microtile 폭, 생산자 DMA_NT와 소비자 DMA_KT가 일치하는 경우이다. 이번 config에서 해당 형상을 기록한다.

### 4.2 최소 store 묶음

정렬 단위는 literal 64 대신 RTL의 `MEM_BLOCK_SIZE`를 사용한다. 이번 실험에서는 64B이다.

microtile 전체를 묶는 최소 개수의 정의:

```text
group_microtiles = alignment_bytes / gcd(alignment_bytes, micro_bytes)
group_store_bytes = group_microtiles × micro_bytes
```

이 식은 동작 명세이다. RTL에 runtime GCD/divider를 추가하지 않는다. 기존 power-of-two geometry와 하위 비트 정렬 판정을 이용해 누적 byte count가 정렬 경계에 도달했는지 판단한다.

| M | MXU_NT | Microtile bytes | 묶을 microtile 수 | Store bytes |
|---:|---:|---:|---:|---:|
| 1 | 16 | 32 | 2 | 64 |
| 3 | 16 | 96 | 2 | 192 |
| 4 | 16 | 128 | 1 | 128 |
| 128 또는 M=256의 각 M tile | 16 | 4096 | 1 | 4096 |

단순히 `누적 bytes >= 64`로 판정하지 않는다. M=3의 96B는 이 조건을 만족하지만 다음 시작 주소를 정렬하지 못한다.

마지막 묶음이 정렬 크기보다 짧으면 해당 DMA tile 끝에서만 전송 길이를 올림한다. 추가 전송 bytes가 예약된 padding 범위 안에 있는지 확인한다. Padding의 값은 수치 검증 대상이 아니며, 다음 유효 데이터나 다른 tile 영역을 덮어써서는 안 된다.

## 5. RTL 및 software 변경 범위

### 5.1 FSM 변경

주요 대상: `hw/rtl/core/gemm/VX_gemm_fsm.sv`.

- 기존 `output_nb_stride/bytes`, 출력 주소 계산, `S_O_ACC2LMEM`과 `S_O_LMEM2DRAM`을 활용해 최소한으로 변경한다.
- 묶음의 첫 LMEM/DRAM 주소와 누적 유효 bytes를 유지한다. 묶음 시작 주소가 마지막 microtile 주소로 덮어써지지 않게 한다.
- 각 microtile의 ACC→LMEM 복사를 발행한 후, 정렬 경계 또는 DMA tile 끝이면 store를 발행한다. 그 외에는 다음 ACC→LMEM 복사로 진행한다.
- 실제 MXU/ACC의 M bound는 `cur_m`을 유지한다. 연산이나 FP16 conversion을 수정하지 않는다.
- 외부 DMA의 입력 우선순위 및 output chunk 제한은 유지한다. L1 tile 전체를 기다리는 일괄 store로 바꾸지 않는다.
- 비정렬 외부 DMA를 활성화하거나 새로운 data buffer/gather datapath를 추가하지 않는다.

### 5.2 완료 의존성

현재 FSM은 `acc_copy_issue_q[group]`와 `o_store_issue_q`를 따로 관리한다. 이 분리를 유지한다.

- ACC→LMEM 복사마다 copy count를 증가시킨다.
- 실제 발행한 store마다 store count를 증가시킨다. M=1의 두 microtile은 copy 2개 / store 1개이다.
- 묶음 store는 해당 묶음의 모든 local write가 TMEM에 도착한 후에만 읽기를 시작한다. 마지막 copy의 완료 카운터가 앞선 copy 완료까지 보장하는지 executor의 순서 보장도 확인한다.
- output buffer 재사용과 accumulator group 재사용 wait를 보존한다.
- final drain은 microtile 개수가 아닌 실제 store 발행 수를 기준으로 한다.
- 기존 assertion, debug metadata, completion/progress count 소비 코드에 copy/store 1:1 가정이 있는지 확인하고 필요한 곳만 수정한다.

로컬 출력 경로는 현재 MXU16의 32B row 단위를 지원한다. 외부 DMA는 64B 정렬된 묶음만 받는다. 이 경계가 실제 elaboration과 trace에서도 맞는지 검증한다.

### 5.3 Host 및 소비자

- `tests/regression/fpint_gemm_ffn_hw/main.cpp`: C unpack/verification을 새 DMA-tile layout에 맞춘다. 수치 reference 자체는 변경하지 않는다.
- `tests/regression/fpint_gemm_ffn_hw/layout.h`: 기존 크기/정렬 helper를 재사용해 output 예약·전송 크기를 표현한다. Input helper의 의미는 유지한다.
- 같은 output layout을 사용하는 `bench_main.cpp`, TVM adapter 및 테스트를 검색해 영향 목록을 작성한다. 이번 regression의 정확성에 필요한 부분을 수정하고, 외부 소비자 전환 필요 사항은 결과 문서에 명시한다.
- 새 layout을 기존 FPGA binary의 output 형식으로 오인하지 않도록 RTL/소프트웨어 조합을 기록한다.
- Naive 및 TCU 경로는 변경 범위에서 제외한다. 불필요한 공통 refactoring은 하지 않는다.

## 6. 수정 후 검증과 cycle 비교

### 6.1 필수 before/after simulation

수정된 source가 build에 반영되도록 configure-generated 파일과 dependency를 확인하고 실제 RTL/kernel rebuild를 보장한다. 같은 환경에서 다음 명령을 실행한다.

```bash
set -euo pipefail
repo_root=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
results_root="$repo_root/analysis_workspace/latency_on_hw/docs/gemm_c_to_a_layout_64b_store_results"
mkdir -p "$results_root/modified"
cd "$repo_root/build"
source "$repo_root/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh"

for gemm_m in 1 4 256; do
  bash ci/run_black.sh xrt-vcs-sim \
    --app fpint_gemm_ffn_hw \
    --args "-m $gemm_m -k 256 -n 256 -q 32 -t 0 -d 0 -r 1" \
    --perf 3 \
    2>&1 | tee "$results_root/modified/m${gemm_m}_k256_n256.log"
done
```

Counter는 실제 `--perf 3` 출력을 기준으로 선택한다.

- 주 지표: GEMM `total_cycles`.
- 함께 기록: core/kernel cycles, functionality, job count, 제공되는 compute/stall 및 DMA bytes/count.
- Job별, core별, aggregate counter를 혼동하지 않고 before/after에 같은 집계 방법을 적용한다.
- Simulation의 wall-clock 실행 시간을 GEMM latency로 사용하지 않는다.
- DMA counter가 command 수인지 burst/beat 수인지 확인한다. 예상 store 명령 수는 필요한 최소 trace로 검증하고, 성능 본 측정에는 추가 diagnostic을 넣지 않는다.

예상 FSM store 명령 수(DMA_MT=DMA_NT=128, MXU_NT=16, K=N=256, 전체 행렬 1회 실행):

| M | Baseline | Modified | 이유 |
|---:|---:|---:|---|
| 1 | 16 | 8 | 각 N tile의 8 microtile을 2개씩 묶음 |
| 4 | 16 | 16 | microtile 하나가 이미 128B로 정렬됨 |
| 256 | 32 | 32 | M tile 2개이며 각 microtile이 정렬됨 |

### 6.2 작은 directed 검증

성능 비교의 3 shape와 별도로, 변경과 직접 관련된 다음 case를 작은 K로 검증한다. 기존 app/verification과 assertion을 우선 사용하고, 필요한 경우 `--tagged`를 사용한다.

| Shape `(M,K,N)` | 확인 사항 |
|---|---|
| `(1,16,16)` | microtile 하나만 남은 32B tail을 64B store해도 예약 범위 안에 있음 |
| `(1,16,48)` | 정상 64B 묶음 이후 마지막 32B tail 처리 |
| `(3,16,48)` | 단순 `>=64` 판정으로 처리할 수 없는 96B microtile 및 tail |
| `(132,16,144)` | M/N DMA tile 경계와 양쪽 tail 주소 |
| `(1,16,32)`, `-r 2` | 동일 buffer를 사용하는 job 재실행 및 완료 카운터 reset/drain |

새 layout의 offset 검증에서는 서로 다른 microtile을 구별할 수 있는 값을 사용한다. Host의 독립적인 layout 검사로 출력 offset이 같은 형상의 A packing과 일치하고 tail 전송이 다음 유효 영역과 겹치지 않는지 확인한다.

## 7. 성과물과 완료 조건

`comparison.csv`와 `SUMMARY.md`에 아래 표를 채운다. 측정하지 않은 값을 예상 수치로 채우지 않는다.

| M | K | N | Baseline PASS | Modified PASS | Baseline GEMM cycles | Modified GEMM cycles | Delta cycles | Delta % | Core cycles before/after |
|---:|---:|---:|---|---|---:|---:|---:|---:|---|
| 1 | 256 | 256 | 미실시 | 미실시 | — | — | — | — | — |
| 4 | 256 | 256 | 미실시 | 미실시 | — | — | — | — | — |
| 256 | 256 | 256 | 미실시 | 미실시 | — | — | — | — | — |

`Delta % = (modified / baseline - 1) × 100`이며 음수가 개선을 뜻한다.

완료 조건:

- 수정 전 3 case의 원본 로그를 보존한다.
- 수정 후 3 case와 directed case가 functionality PASS하고 assertion 실패나 hang이 없어야 한다.
- M=1에서는 2 microtile/64B 단위로 store하며 L1 tile 전체를 모으기 위해 추가로 기다리지 않는다.
- Input layout/compute bound를 유지하고 C의 유효 데이터 위치를 A layout과 일치시킨다.
- DMA input/output 교대가 가능한 기존 priority/chunk 제어를 유지한다.
- Cycle 증감을 실측으로 설명한다. M=4/256은 store 수가 같아도 FSM 제어 변경으로 cycle 차이가 생길 수 있으므로, 사전에 차이가 없다고 보장하지 않는다. 악화 시 원인을 조사하고 기록한다.
- 최종 diff에서 변경과 무관한 편집을 제외한다.
