# DMA Bound21 / Native Product / MAX_DIMS 검증 결과

## 결론

- 21-bit unsigned bound, native-width product, `MAX_DIMS=1..3` specialization을 구현했다.
- focused parity, 기존 VCS regression, GEMM integration 55-case sweep 및 xrt-vcs FPINT GEMM QDIR 0/1은 모두 통과했다.
- 차원 specialization은 Vivado netlist에서 inactive counter, bound/stride correction state 및 multiplier를 실제 제거했다.
- 기존 GEMM OOC worst였던 output DMA의 `write_bytes_remaining_r` product 경로는 top 100 setup path에서 사라졌다.
- 7 ns GEMM node 전체 setup gate는 아직 실패한다. 새 worst는 DMA가 아니라 GEMM FSM의 `kt_dim_q`에서 child command queue BRAM 입력으로 가는 기존 control/decode 경로다.

## RTL simulation

### Focused parity와 contract

`build_verify_dma_parity_i1` 결과:

- 32B/64B baseline padding parity: PASS
- aligned `MAX_DIMS=1/2` 대 `MAX_DIMS=3`: PASS
- misaligned `MAX_DIMS=1/2` 대 `MAX_DIMS=3`: PASS
- G2L/L2G, partial/full beat, backpressure, OOO response, outstanding overlap: PASS
- 32x21 multiplier: 최대값 1개와 random 127개를 각 positive case에서 PASS
- nonzero padding, 22번째 bound bit, inactive 1D/2D bound, invalid `MAX_DIMS=0/4`, unequal width negative test: 기대한 assertion PASS
- 전체 focused regression: 13/13 PASS

Standalone unequal-width dimension tests:

- aligned MAX1: entry 7 done 455 ns, entry 11 done 915 ns, memory compare PASS
- aligned MAX2: entry 7 done 905 ns, entry 11 done 2065 ns, memory compare PASS
- misaligned MAX1/MAX2: PASS

초기 standalone 실패는 RTL 문제가 아니라 TB가 새 lookahead `data_release`를 구동하지 않고, `ready`가 `S_DONE`에서도 high인 chain protocol을 IDLE로 오인한 문제였다. TB를 현재 interface 계약에 맞춘 뒤 모두 통과했다.

### 기존 regression

다음 VCS target이 모두 PASS했다.

- `dma_engine`, `dma_node`
- `lmem_dma`, `lmem_dma_misal`, `lmem_weight_gather_dma`
- input/qparam/weight overlap DMA의 FF/RAM mode
- `gemm_dma_ctrl`, `gemm_dma_ctrl_naive_pipeline`, `gemm_tmem_dma_ctrl`
- `gemm_node_improve`: 55/55 PASS

`gemm_dma_ctrl` TB는 제거된 scalar interface 필드를 사용하고 있어 처음 compile에 실패했다. 현재 direct-command ABI(`instr[31:4]`, `stride`, `bound`, op 1/2/3)에 맞춘 뒤 descriptor word, backend done 및 NOTIFY까지 PASS했다.

## xrt-vcs FPINT GEMM

Config: `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh`

| Case | Result | Cycles | IPC |
| --- | --- | ---: | ---: |
| QDIR=0, M/N/K/QBLK=32 | PASS | 5,873 | 1.064703 |
| QDIR=1, M/N/K/QBLK=32 | PASS | 5,873 | 1.064703 |

두 방향 모두 bit-exact 결과가 같고 cycle도 동일하다. 별도의 pre-change xrt-vcs log가 같은 TH16 config로 남아 있지 않아 integration 단계의 전후 percentage는 직접 산출할 수 없지만, dual-DUT focused test에서는 request/handshake/done cycle이 baseline `MAX_DIMS=3`과 일치했다.

## DMA OOC resource와 구조 제거

Part: `xcu55c-fsvh2892-2L-e`, Vivado 2025.1, 64B/64B interface.

### Aligned 8-channel engine

| MAX_DIMS | LUT | FF | RAMB36 | RAMB18 | DSP |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 29,322 | 8,920 | 56 | 16 | 0 |
| 2 | 37,320 | 11,440 | 56 | 16 | 64 |
| 3 | 42,049 | 13,990 | 56 | 16 | 128 |

MAX3 대비 MAX1은 LUT 12,727개(30.3%), FF 5,070개(36.2%), DSP 128개를 줄였고 BRAM은 증가하지 않았다.

### Misaligned unit

| MAX_DIMS | LUT | FF | RAMB36 | RAMB18 | DSP |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 6,757 | 3,417 | 9 | 3 | 0 |
| 2 | 7,750 | 3,705 | 9 | 3 | 8 |
| 3 | 7,302 | 4,009 | 9 | 3 | 16 |

MAX2 LUT가 MAX3보다 큰 것은 DSP/LUT mapping trade-off지만, FF와 DSP는 차원에 따라 단조 감소하고 BRAM은 동일하다. MAX1은 MAX3 대비 LUT 545개, FF 592개, DSP 16개가 감소했다.

Vivado removal log는 다음을 확인했다.

- MAX1: `bound_r[1:2]`, read/write dimension 1/2 counter, 모든 `stride_bound_r` 제거
- MAX2: `bound_r[2]`, dimension 2 counter, D1 correction state 제거
- aligned MAX2 multiplier dependency mask가 4 bit에서 2 bit로 trim
- DSP count가 `2 * (MAX_DIMS - 1)` 규칙과 일치

DMA OOC script의 Vivado synthesis/report 생성은 모두 성공했다. 후처리 단계는 로컬 Python에 `hwexplorer` 의존성이 없어 exit code 2였으며, 이 문서의 수치는 생성된 Vivado hierarchy/timing report에서 직접 읽었다.

## GEMM node 7 ns OOC

이전 비교 결과 `build/gemm-node-ooc-7ns-r3`:

- WNS -4.247 ns
- worst: child command queue BRAM clock → `u_ldma_output/write_bytes_remaining_r[63]`
- data path 11.182 ns, 39 logic levels, multiplier/DSP chain 포함

현재 결과:

- WNS -1.917 ns, TNS -11048.302 ns, failing endpoints 19,108
- worst: `VX_gemm_fsm/kt_dim_q[1]` → child scheduler command queue BRAM data input
- data path 8.588 ns, 39 logic levels
- top 100 setup path에 `write_bytes_remaining_r`, `descriptor_write_bytes`, `stride_bound` 또는 local DMA product 경로 없음

Output local DMA hierarchy 비교:

| Result | LUT | FF | RAMB36 | RAMB18 | DSP |
| --- | ---: | ---: | ---: | ---: | ---: |
| prior r3 | 3,651 | 1,050 | 7 | 1 | 32 |
| current | 2,064 | 523 | 7 | 1 | 2 |

Target output DMA는 LUT 43.5%, FF 50.2%, DSP 93.8%가 감소했고 BRAM은 동일하다. GEMM node 전체 수치는 LUT 301,753→297,115, FF 155,148→151,822, DSP 2,298→2,212이며 BRAM/URAM은 동일하다. 전체 차이에는 같은 worktree의 response-DPRAM 변경도 포함되므로, target output DMA hierarchy와 worst-path 제거를 이번 최적화의 직접 증거로 사용한다.

7 ns setup violation의 새 worst는 DMA bound/native-product 범위를 벗어난 GEMM FSM command construction 및 child queue write 경로다. 이 경로는 별도 timing 최적화 대상으로 분리한다.

## 정적 audit

- 관련 DMA core/local executor에 32-bit `bound_r`, `prep_bound_r`, dimension counter가 남지 않았다.
- bound/seg-size/index 관련 64-bit 선확장 곱셈이 남지 않았다.
- 32-bit config/MMIO descriptor word와 register index는 유지됐다.
- production local input/weight/scale/zp/output DMA는 `MAX_DIMS=1`, HBM/TMEM engine과 CPU generic DMA는 `MAX_DIMS=3`이다.
- `bash -n`과 `git diff --check`가 PASS했다.
