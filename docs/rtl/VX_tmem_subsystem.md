# VX_tmem_subsystem

## 개요

TMEM(Tensor Memory) 하위 시스템의 최상위 모듈. HBM ↔ TMEM ↔ GEMM 연산 유닛 간 데이터 이동을 담당한다.

```
HBM ↔ DMA Engine ↔ TMEM Banks ↔ Switches ↔ Local DMAs ↔ GEMM Unit
```

## 파라미터

| 파라미터 | 기본값 | 설명 |
|----------|--------|------|
| `NUM_BANKS` | 8 | TMEM 뱅크 수 (HBM 채널 수와 동일) |
| `BANK_SIZE` | 32KB | 뱅크당 크기 (총 256KB) |
| `DATA_SIZE` | 64 | membus 데이터 폭 (64B = 512-bit) |
| `GEMM_DATA_SIZE` | 64 | GEMM 유닛 포트 폭 |
| `TAG_WIDTH` | 8 | 태그 비트폭 |
| `AXI_ADDR_WIDTH` | `PLATFORM_MEMORY_ADDR_WIDTH` | AXI 주소 폭 |
| `W_CMD_BEATS` | `MXU_ROW / MXU_WLOAD_NUM` | Beats in one Weight command |
| `W_RD_OUTSTANDING` | `2 * W_CMD_BEATS` | Shared Weight response slots / wide-read contexts |

## 포트

| 포트 | 방향 | 설명 |
|------|------|------|
| `dma_cfg_if[8]` | 입력 | DMA 채널 설정 (gemm_dma_ctrl → DMA engine) |
| `dma_done_if[8]` | 출력 | DMA 완료 통지 (DMA engine → gemm_dma_ctrl) |
| `ldma_ctrl_if[5]` | 입력 | Local DMA 제어 (gemm_ctrl → local DMA) |
| `axi_m[8]` | AXI Master | HBM AXI 포트 (DMA engine이 구동) |
| `gemm_input_if` | membus Master | GEMM 입력 데이터 포트 |
| `gemm_weight_if` | membus Master | GEMM 가중치 포트 |
| `gemm_scale_if` | membus Master | GEMM scale 포트 |
| `gemm_zp_if` | membus Master | GEMM zero-point 포트 |
| `gemm_output_if` | membus Master | GEMM 출력 포트 |

## 내부 구성요소

### 1. DMA Engine (`u_dma_engine`)

8채널 HBM(AXI) ↔ TMEM(membus) 변환.

- `cfg_reg_if`로 각 채널의 전송 설정(시작 주소, 길이, 방향)을 받음
- `axi_m[ch]` ↔ `dma_to_tmem[ch]` 1:1 매핑
- 각 채널이 독립적으로 동작하며, 완료 시 `dma_done_if[ch]`로 통지

### 2. Switches (`u_switch_*`, x5)

각 Local DMA의 TMEM 접근을 주소 기반으로 적절한 뱅크에 라우팅 (1:N).

| 인스턴스 | 입력 | 출력 | 용도 |
|----------|------|------|------|
| `u_switch_input` | `ldma_to_switch[0]` | `in_switch_to_tmem[0..7]` | 입력 데이터 뱅크 분산 |
| `u_switch_weight` | `ldma_to_switch[1]` | `wt_switch_to_tmem[0..7]` | 가중치 뱅크 분산 |
| `u_switch_scale` | `ldma_to_switch[2]` | `sc_switch_to_tmem[0..7]` | scale 뱅크 분산 |
| `u_switch_zero_point` | `ldma_to_switch[3]` | `zp_switch_to_tmem[0..7]` | zero-point 뱅크 분산 |
| `u_switch_output` | `ldma_to_switch[4]` | `out_switch_to_tmem[0..7]` | 출력 데이터 뱅크 분산 |

스위치는 태그에 뱅크 선택 비트(`BANK_SEL_BITS`)를 추가하여, 응답 매핑에 사용한다.

#### Weight wide-read switch

`u_switch_weight`는 weight beat 하나를 임의의 sliding bank window가 아니라
정렬된 bank group으로만 fan-out한다. `NUM_BANKS=8`, `DATA_SIZE=64B`일 때
지원 설정의 mapping은 다음과 같다.

| `MXU_WLOAD_NUM` | Weight beat | Banks per beat | Legal bank groups | Command beats | Shared slots |
|---:|---:|---:|---|---:|---:|
| 4 | 64B | 1 | `{0}`, `{1}`, ..., `{7}` | 8 | 16 |
| 8 | 128B | 2 | `{0,1}`, `{2,3}`, `{4,5}`, `{6,7}` | 4 | 8 |
| 16 | 256B | 4 | `{0,1,2,3}`, `{4,5,6,7}` | 2 | 4 |
| 32 | 512B | 8 | `{0,1,2,3,4,5,6,7}` | 1 | 2 |

따라서 WLOAD8에서 `{1,2}`와 같은 비정렬 bank pair는 생성되지 않는다.
Weight command length and response capacity are separate elaboration-time
contracts. The command always spans one MXU K dimension, while the response
pool holds two complete commands.

```text
MXU_WLOAD_NUM * W_CMD_BEATS = MXU_ROW
W_RD_OUTSTANDING = 2 * W_CMD_BEATS
NUM_BANKS % BANKS_PER_BEAT = 0
```

각 request의 local-DMA slot ID(`tag.value` 하위 비트)가 switch context ID로
사용된다. Context는 원본 tag, 주소, byte enable, flags, target/issued/response
bank mask와 조립 중인 response data를 저장한다. Issue FIFO head context가
선택 bank 모두에 handshake할 때까지 issue ownership을 유지하므로 일부
bank만 ready여도 이미 accept한 bank에 중복 request를 보내지 않는다.

Bank response는 기존 `{bank_id, original_tag}`를 사용해 원래 context로
수집된다. 여러 context와 여러 bank의 response가 같은 cycle에 도착할 수
있지만, upstream response는 별도 accept-order FIFO 순서로만 retire한다.
`rsp_valid` 상태에서 upstream backpressure가 발생하면 head context가
유지되므로 response data와 tag도 안정적으로 유지된다. 모든 context가 찬
cycle의 response retire과 request accept를 동시에 수행하는 fall-through는
지원하지 않으며, `req_ready`는 retire 다음 cycle에 다시 올라간다.

### 3. TMEM Banks (`u_bank`, x8)

각 뱅크는 6포트 중재(arbitration)를 가진 SRAM.

| 포트 | 접속 | 태그 폭 |
|------|------|---------|
| port[0] | DMA direct (ch b → bank b, 1:1) | `SWITCH_TAG_WIDTH` |
| port[1] | input switch | `SWITCH_TAG_WIDTH` |
| port[2] | weight switch | `SWITCH_TAG_WIDTH` |
| port[3] | scale switch | `SWITCH_TAG_WIDTH` |
| port[4] | zero-point switch | `SWITCH_TAG_WIDTH` |
| port[5] | output switch | `SWITCH_TAG_WIDTH` |

- DMA 포트(0)는 태그 상위비트를 0으로 패딩하여 `SWITCH_TAG_WIDTH`에 맞춤
- 스위치 포트(1-5)는 스위치가 이미 뱅크 선택 비트를 포함한 태그를 전달

### 4. Local DMAs (`u_ldma_*`, x5)

TMEM과 GEMM 유닛 간 실제 데이터 이동을 수행. 방향에 따라 읽기/쓰기 포트가 결정된다.

| 인스턴스 | DIR | 방향 | lmem 포트 | gemm 포트 |
|----------|-----|------|-----------|-----------|
| `u_ldma_input` | overlap | LMEM→GEMM | `ldma_to_switch[0]` | `ldma_gemm[0]` → `gemm_input_if` |
| `u_ldma_weight` | overlap | LMEM→GEMM | `ldma_weight_to_tmem` | `ldma_gemm_weight` → `gemm_weight_if` |
| `u_ldma_scale` | overlap | LMEM→GEMM | `ldma_to_switch[2]` | `ldma_gemm[2]` → `gemm_scale_if` |
| `u_ldma_zero_point` | overlap | LMEM→GEMM | `ldma_to_switch[3]` | `ldma_gemm[3]` → `gemm_zp_if` |
| `u_ldma_output` | 1 | GEMM→LMEM | `ldma_to_switch[4]` | `ldma_gemm[4]` → `gemm_output_if` |

Scale and zero point have independent switch request ports and local-DMA
pipelines. Each physical TMEM bank is still single-port, so simultaneous
requests to the same bank are serialized by that bank's arbiter.

Scale and zero point use two independent ordered overlap executors and reject
passive prepare. Each executor stores four complete descriptors and owns an
eight-slot tagged response RAM shared only by that resource's in-flight
commands. Source requests remain command-granular and ordered, but they may
fill slots before the destination bank is safe to overwrite. The writer head
stores and checks the exact SC_CONSUME or ZP_CONSUME RID/target against a
registered consume level, then also honors the GEMM qparam `req_ready` signal.
Destination writes and completion cannot overtake an older command.

Qparam completion is caused by the final actual register write. The node
reports it through a registered pulse, and a full qparam command FIFO exposes
new capacity after its registered pop rather than through a same-cycle write
bypass. These causal boundaries prevent a GEMM-ready/completion/scheduler
combinational loop while retaining source-read overlap and exact overwrite
safety. The output local DMA retains its original start-only behavior.

Input uses a dedicated ordered overlap executor and rejects passive prepare.
It stores four complete variable-length command descriptors and shares one
eight-slot tagged response RAM across all in-flight commands. Independent
source and GEMM-destination heads preserve command-granular order while TMEM
reads run ahead of the irreversible GEMM admission boundary. Each slot records
its command sequence and beat index, so TMEM responses may return out of order
without changing destination order. The final actual `req_valid && req_ready`
admission reports normal command completion.

Weight uses a separate in-order overlap executor and rejects passive prepare.
It accepts up to two dependency-ready commands, stores both complete
descriptors, and uses independent read-command and write-command pointers.
All responses share one eight-entry RAM in WLOAD8. Source requests remain
command-granular (`N` then `N+1`), but reads for `N+1` may execute while the
four responses of `N` drain to the register port. Destination writes and
completion remain command-granular and ordered.

The node encodes `{load_dir, wreg_idx}` as an aligned Weight destination byte
base (`selector << log2(weight_beat_bytes)`). The overlap executor stores this
base in each command entry and converts the writer-head base back to the GEMM
beat address. Therefore enqueueing or reading command `N+1` cannot change the
destination selector while command `N` is still writing. Architectural notify
retirement waits for the final GEMM register-write event, including the
optional WLOAD_AT_ONCE register-write pipe; it does not retire on the earlier
DMA bus handshake.

`wreg_idx` is two bits and addresses four physical Weight banks. The subsystem
receives the current W0..W3 consume levels from the controller and compares
the writer head against the command's exact RID/target before allowing any
destination beat. Scale and zero-point retain independent two-bank paths.

The previous per-command passive prepare credits remain encoded for
compatibility, but the dedicated overlap executors do not consume them:

| Command class | Macro | Default beats |
|---|---|---:|
| Weight local DMA | Not used (dependency-ready commands issue into overlap FIFO) | - |
| Scale local DMA | Not used (source-ready commands issue into overlap FIFO) | - |
| Zero-point local DMA | Not used (source-ready commands issue into overlap FIFO) | - |

The Input, Scale, and Zero-point prefetch macros remain encoded in command
metadata for compatibility. Their dedicated executors obtain limits from
their private fixed eight-slot pools rather than passive prepare credit.

The descriptor length and physical DMA response-slot count remain hard caps,
so a configured credit does not create additional storage or issue requests
beyond the transfer end.

## 데이터 흐름

### 입력 경로 (HBM → GEMM)

```
HBM[0..7]
  → AXI bus
  → DMA Engine (8ch, AXI→membus 변환)
  → dma_to_tmem[0..7] (1:1, bank 직접 접근)
  → TMEM Bank[0..7] port[0]
  → TMEM Bank[0..7] port[1..5]
  → switch_to_tmem 역방향
  → Local DMA (ctrl_if 제어)
  → ldma_gemm[0..3]
  → gemm_input_if / gemm_weight_if / gemm_scale_if / gemm_zp_if
  → GEMM Unit
```

### 출력 경로 (GEMM → HBM)

```
GEMM Unit
  → gemm_output_if
  → ldma_gemm[4]
  → Local DMA output (DIR=1, GEMM→LMEM)
  → ldma_to_switch[4]
  → u_switch_output (1:N 뱅크 분산)
  → out_switch_to_tmem[0..7]
  → TMEM Bank[0..7] port[5] (쓰기)
  → TMEM Bank[0..7] port[0] (DMA 읽기)
  → dma_to_tmem[0..7]
  → DMA Engine (membus→AXI 변환)
  → AXI bus
  → HBM[0..7]
```

## 태그 처리

- **DMA 포트**: 원본 `TAG_WIDTH` 비트 태그에 상위에 `BANK_SEL_BITS`만큼 0을 패딩하여 `SWITCH_TAG_WIDTH`에 맞춤
- **스위치 포트**: 스위치가 자동으로 뱅크 선택 비트를 태그에 추가
- **태그 폭 계산**: `SWITCH_TAG_WIDTH = TAG_WIDTH + BANK_SEL_BITS` (`BANK_SEL_BITS = log2(NUM_BANKS)`)
