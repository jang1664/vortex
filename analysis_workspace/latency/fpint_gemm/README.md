# fpint GEMM naive/improve latency analysis

## 결론

이 조건에서 `fpint_gemm_ffn_hw_naive`가 느린 주원인은 **연산량이나 외부
ready/valid stall이 아니라, shared-LMEM/gather 기반 하위 DMA 경로가 GEMM 명령을
느리고 단편적으로 처리해 상위 명령 FIFO를 오래 막는 것**이다. Improve 경로는
TMEM + 8-channel local DMA 구조로 동일한 데이터를 더 연속적으로 공급하고 DMA와
MXU를 겹쳐 실행한다.

측정 workload는 두 구현 모두 `-m 32 -n 32 -k 128 -q 32 -t 0 -d 0`이며,
각각 아래 조합을 사용했다.

| case | config | blackbox app |
|---|---|---|
| improve | `configs/improve_th32_tcol32_hwexp_dcache.sh` | `fpint_gemm_ffn_hw` |
| naive | `configs/naive_gemm_th32_tcol32_hwexp_dcache.sh` | `fpint_gemm_ffn_hw_naive` |

두 실행은 모두 `PASSED`였고 compile/simulation log에 fatal error는 없었다.

## 성능 결과

| metric | improve | naive | naive - improve |
|---|---:|---:|---:|
| core cycles | 8,850 | 10,550 | **+1,700 (+19.21%)** |
| GEMM jobs total cycles | 487 | 1,489 | **+1,002** |
| GEMM FSM window | 412 | 1,260 | **+848** |
| compute cycles | 216 | 340 | **+124** |
| GEMM-unit command latency 합 | 224 | 348 | **+124** |
| DMA+MXU overlap | 180 (36.961%) | 0 (0%) | **-180** |
| MAC count | 32,768 | 32,768 | 0 |
| accelerator stall cycles | 4 | 4 | 0 |
| instructions | 12,969 | 13,113 | +144 |
| IPC | 1.465 | 1.243 | -0.222 |

`core cycles` 기준 improve는 naive보다 16.11% 짧고, 반대로 naive는 improve보다
19.21% 느리다. 동일한 32,768 MAC을 수행하며 accelerator stall count도 같으므로
계산량 차이가 원인은 아니다. 늘어난 polling instruction은 느린 accelerator를 더
오래 기다린 결과의 성격이 강하다.

## FSDB 근거

### 1. 명령 FIFO가 하위 파이프라인을 기다린 시간이 병목과 일치한다

GEMM FSM의 `can_emit`을 막는 `parent_q_full`의 active time은 다음과 같다.

| metric | improve | naive | delta |
|---|---:|---:|---:|
| FSM window | 412 | 1,260 | +848 |
| parent FIFO full | 354 | 1,205 | **+851** |

FIFO-full 증가분 851 cycle이 FSM 지연 증가분 848 cycle과 측정 오차 범위에서
일치한다. 따라서 상위 FSM 자체의 계산보다, FIFO 아래의 local-DMA/GEMM command
consumer가 늦게 비워지는 것이 직접 병목이다.

가장 긴 단일 FSM 체류도 이를 보여 준다.

- improve: `S_MXU_PRE_CUR_SZ_NTF` 92 cycles, `S_MXU_WAIT_GEMM_DONE` 61 cycles,
  `S_O_LMEM2DRAM` 59 cycles
- naive: `S_MXU_PRE_CUR_ZP` 796 cycles, `S_MXU_PRE_NEXT_W_NTF` 184 cycles,
  `S_MXU_ARM_GEMM_NTF` 96 cycles, `S_O_WAIT_ACC2LMEM_DONE` 79 cycles

주의할 점은 `S_MXU_PRE_CUR_ZP`의 796 cycles를 “zero-point 계산 시간”으로
해석하면 안 된다는 것이다. 이 state에서는 다음 명령을 enqueue하려 하지만 parent
FIFO가 차 있어 기다리므로, 하위 파이프라인 전체의 배출 지연이 이 state에
누적되어 보인다.

### 2. 동일한 beat 수를 처리하지만 naive의 command latency가 길고 가변적이다

FSDB의 각 control interface에서 `start -> done`을 측정했다.

| command | improve samples (cycles) | naive samples (cycles) | 합계 delta |
|---|---|---|---:|
| weight DMA | 22, 22, 22, 22 | 50, 50, 62, 50 | +124 |
| quant DMA | 15, 15, 15, 15, 16, 15, 15, 15 | 29, 29, 29, 39, 29, 43, 29, 29 | +135 |
| input DMA | 46, 46, 46, 46 | 65, 90, 80, 65 | +116 |
| GEMM unit | 56, 56, 56, 56 | 77, 102, 92, 77 | **+124** |

Improve는 command latency가 거의 고정적인 반면 naive는 더 길고 변동한다.
특히 GEMM-unit 합계의 +124 cycles는 PERF counter의 compute-cycle 차이 +124와
정확히 같다.

### 3. 외부 consumer backpressure나 데이터 양 차이는 아니다

FSM window의 DMA-to-GEMM request를 계산하면 두 구현이 같은 양을 처리한다.

| request | improve accepted | naive accepted | valid && !ready stall |
|---|---:|---:|---:|
| input | 128 cycles | 128 cycles | 양쪽 모두 0 |
| weight | 32 cycles | 32 cycles | 양쪽 모두 0 |
| scale/zero | 8 cycles | 8 cycles | 양쪽 모두 0 |

즉 GEMM 쪽이 `ready`를 내리지 않아 생긴 stall은 아니다. 차이는 요청이 준비되는
시점과 burst 모양이다.

- Improve input: 32-cycle 연속 burst 4개
- Naive input: 16-cycle burst 8개
- Improve의 최초 유효 데이터는 FSM 시작 후 115 cycles에 나오지만, naive는
  최초 scale beat가 834 cycles에야 나온다.
- Naive weight도 일부 3+5, 2+6 cycle로 쪼개지는 반면 improve는 8-cycle burst가
  안정적으로 반복된다.

이는 `req_valid && !req_ready` stall이 아니라 shared local-memory의 gather,
arbiter, command/synchronization schedule 때문에 producer가 늦게/단편적으로
데이터를 만드는 현상이다.

## RTL/config와의 연결

Improve config는 `GEMM_IMPROVE`, `TMEM_BANK_SIZE=32768`,
`NUM_DMA_CHANNELS=8`을 사용한다. 파형 hierarchy에도 8-channel DMA와 input,
weight, scale/zero, output LDMA가 분리된 `u_tmem_subsystem`이 나타난다. 이 구조가
tile-native 연속 burst와 36.961% DMA/MXU overlap을 만든다.

Naive config는 `GEMM_NAIVE`와 1 MiB LMEM을 사용하며, RTL hierarchy는
`u_input_lmem_dma`, `u_weight_gather_dma`, `u_quant_param_lmem_dma`,
`u_output_lmem_dma` 및 shared-LMEM arbitration을 거친다. 같은 request beat 수에도
command latency가 길고 burst가 쪼개지며 overlap이 0%인 현재 파형과 일관된다.

Naive의 outstanding slot은 오히려 16으로 improve의 8보다 크다. 따라서 이 작은
workload에서 outstanding 부족이 root cause라는 설명은 맞지 않는다. 또한 두
config는 memory interface, LMEM size, outstanding depth도 함께 다르므로, 이 결과는
`GEMM_NAIVE` 한 매크로만의 독립 효과가 아니라 **두 config/backend 조합 전체의
비교**로 해석해야 한다.

## 재현 방법

`run_black.sh`는 config가 바뀌었다고 기존 `simv`를 자동 재빌드하지 않으므로 각
case마다 source 후 `make -B`로 simulator를 다시 만들었다.

```bash
cd build

source ../configs/improve_th32_tcol32_hwexp_dcache.sh
CONFIGS+=" -DPERF_ENABLE"
PATH=/usr/bin:$PATH FSDB_DUMP=1 make -B -C sim/xrtsim_vcs simv CONFIGS="$CONFIGS"
PATH=/usr/bin:$PATH timeout 1800 ./ci/run_black.sh xrt-vcs-sim \
  --app fpint_gemm_ffn_hw --args "-m 32 -n 32 -k 128 -q 32 -t 0 -d 0" --perf 3

source ../configs/naive_gemm_th32_tcol32_hwexp_dcache.sh
CONFIGS+=" -DPERF_ENABLE"
PATH=/usr/bin:$PATH FSDB_DUMP=1 make -B -C sim/xrtsim_vcs simv CONFIGS="$CONFIGS"
PATH=/usr/bin:$PATH timeout 1800 ./ci/run_black.sh xrt-vcs-sim \
  --app fpint_gemm_ffn_hw_naive --args "-m 32 -n 32 -k 128 -q 32 -t 0 -d 0" --perf 3
```

저장한 FSDB를 public `fsdb_cli` Python API로 다시 계산하려면 repository root에서
실행한다.

```bash
PYTHONPATH=tools python3 analysis_workspace/latency/fpint_gemm/analyze_fpint_gemm.py
```

## 산출물

- `metrics.json`: PERF 및 주요 FSDB 수치
- `analyze_fpint_gemm.py`: `fsdb_cli` API 기반 재현 분석기
- `runs/improve/`: improve compile log, sim log, FSDB와 sidecar
- `runs/naive/`: naive compile log, sim log, FSDB와 sidecar

FSDB sidecar는 `fsdbreport`가 full waveform을 읽는 데 필요하므로 함께 보존했다.
