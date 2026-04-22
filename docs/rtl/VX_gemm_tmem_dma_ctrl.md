# VX_gemm_tmem_dma_ctrl

## 개요

GEMM DMA 명령을 8채널 DMA engine 설정 레지스터로 변환하는 컨트롤러. 64바이트 bus-word 단위로 seg_size를 채널에 분배하고, Phase 1 refactor 이후로는 **2D (bank × beat) descriptor**를 발행한다. 자세한 설계는 `agent-tasks/dma-burst-reorder/plan.md` 참조.

```
gemm_ctrl ──cmd──> VX_gemm_tmem_dma_ctrl ──cfg_reg_if[0..7]──> VX_dma_engine
                                         <──done_if[0..7]──────
                    │
                    └──gemm_sync_if──> gemm_sync (완료 통지)
```

## FSM

```
S_IDLE ──start──> S_PROG ──cfg_all_ready──> S_WAIT_DONE ──done_all──> S_DONE ──> S_IDLE
  │                                                                                  ^
  └──start(OP_NOTIFY)──> S_NOTIFY ──sync_ready──> S_DONE ──────────────────────────┘
```

| 상태 | 동작 |
|------|------|
| `S_IDLE` | `gemm_dma_ctrl_if.start` 대기. 명령 캡처 후 `cmd_q`에 저장 |
| `S_PROG` | 활성 채널에 `cfg_reg_if` 레지스터 쓰기. 모든 채널 ready시 다음 상태 |
| `S_WAIT_DONE` | 모든 활성 채널의 `done_if.valid` 대기 |
| `S_DONE` | `gemm_dma_ctrl_if.done` = 1. 다시 IDLE로 |
| `S_NOTIFY` | OP_NOTIFY 명령: `gemm_sync_if`로 reg_idx/value 전송 |

## 명령 해석

`cmd_q`에서 opcode/필드 추출:

| 필드 | 원본 | 설명 |
|------|------|------|
| `cmd_op` | `cmd_q.instr[3:0]` | OP_DMA_LD(1), OP_DMA_ST(2), OP_NOTIFY(3) |
| `dir_is_st` | `cmd_op == OP_DMA_ST` | 0=HBM→TMEM, 1=TMEM→HBM |
| `src_base` | `cmd_q.rs2_data` | 소스 시작 주소 |
| `dst_base` | `cmd_q.rs1_data` | 목적지 시작 주소 |
| `seg_size` | `{4'd0, cmd_q.instr[31:4]}` | 전체 전송 크기 (바이트) |
| `bound` | `{16'd0, cmd_q.bound}` | 반복 횟수 (bnd0) |
| `stride` | `cmd_q.stride[31:16]`, `cmd_q.stride[15:0]` | 소스/목적지 stride |

## 채널 분배 로직

seg_size를 64B bus-word 단위로 8채널에 분배:

```
num_words  = seg_size >> 6          // 총 bus-word 수
words_quot = num_words >> 3         // 채널당 기본 word 수
words_rem  = num_words[2:0]         // 나머지

ch[ch]의 word 수 = words_quot + (ch < words_rem ? 1 : 0)
```

- `ch_words == 0`인 채널은 비활성 (`ch_active = 0`)
- 비활성 채널은 cfg/done에서 자동으로 ready/done으로 간주

## 주소 변환

HBM과 TMEM의 주소 체계가 다르므로 방향에 따라 변환:

| 필드 | LD (HBM→TMEM) | ST (TMEM→HBM) |
|------|---------------|---------------|
| `ch_src_base` | `src_base + ch * 64` | `src_base >> 3` |
| `ch_dst_base` | `dst_base >> 3` | `dst_base + ch * 64` |

- **HBM 측**: 채널당 64바이트 오프셋 (`ch * 64`)으로 interleave
- **TMEM 측**: byte 주소를 word 주소로 변환 (`>> 3`). DMA 채널 N → bank N 1:1 직접 매핑이므로 interleave 오프셋 불필요

## 2D Burst-Reorder Descriptor (Phase 1)

채널마다 descriptor를 **bank × beat** 2D loop 형태로 발행한다. Inner(beat) 루프는 같은 HBM bank 내 연속 beat들을 순서대로 치고, Outer(bank) 루프는 채널에 매핑된 bank를 순회한다. 이렇게 하면 downstream `VX_dma_engine`이 reorder 없이 각 inner 루프를 AXI INCR burst 하나로 발사할 수 있다.

### Burst 기하 (localparam)

```
NUM_BURST_GROUPS    = PLATFORM_MEMORY_NUM_BANKS / NUM_CHANNELS   // U55C: 4
BEAT_STRIDE_HBM_B   = PLATFORM_MEMORY_NUM_BANKS * MEM_BLOCK_SIZE // 2048 (interleave)
BANK_STRIDE_HBM_B   = HBM_BUS_STRIDE                             // 512
BEAT_STRIDE_TMEM_B  = NUM_BURST_GROUPS * MEM_BLOCK_SIZE          // 256
BANK_STRIDE_TMEM_B  = MEM_BLOCK_SIZE                             // 64
MAX_BEATS_PER_BURST = 4096 / MEM_BLOCK_SIZE                      // 64 (AXI 4KB 경계)
```

### Burst mode 결정 (채널별)

```
burst_mode = (ch_words >= NUM_BURST_GROUPS)
          && ((ch_words % NUM_BURST_GROUPS) == 0)
          && ((ch_words / NUM_BURST_GROUPS) <= MAX_BEATS_PER_BURST)
```

### Stride / BND 설정

| 모드 | BND0 | BND1 | SRC/DST ST0 (beat) | SRC/DST ST1 (bank) |
|------|------|------|----|----|
| `burst_mode=1` (LD) | `ch_words / NUM_BURST_GROUPS` | `NUM_BURST_GROUPS` | SRC=2048, DST=256 | SRC=512, DST=64 |
| `burst_mode=1` (ST) | 동 | 동 | SRC=256, DST=2048 | SRC=64, DST=512 |
| fallback (LD) | 1 | `ch_words` | 0 | SRC=512, DST=64 |
| fallback (ST) | 1 | `ch_words` | 0 | SRC=64, DST=512 |

- Fallback은 `ch_words`가 `NUM_BURST_GROUPS`로 나누어 떨어지지 않거나 그보다 작을 때 사용 (예: scale/zp DMA의 `ch_words=2`).

## 채널별 Config 레지스터 맵

| 인덱스 | 레지스터 | 값 |
|--------|----------|-----|
| 0 | CONTROL | `ch_active ? 1 : 0` |
| 1-2 | DST_BASE (LO/HI) | 채널별 dst_base |
| 3-4 | SRC_BASE (LO/HI) | 채널별 src_base |
| 5 | SRC_ST0 | burst_mode: beat stride (HBM 2048 / TMEM 256). fallback: 0 |
| 6 | DST_ST0 | burst_mode: beat stride. fallback: 0 |
| 7 | SRC_ST1 | burst_mode: bank stride (HBM 512 / TMEM 64). fallback: HBM/TMEM stride |
| 8 | DST_ST1 | burst_mode: bank stride. fallback: TMEM/HBM stride |
| 9 | SRC_ST2 | 0 (Q2 reserved) |
| 10 | DST_ST2 | 0 (Q2 reserved) |
| 11 | BND0 | burst_mode: beats per bank. fallback: 1 |
| 12 | BND1 | burst_mode: `NUM_BURST_GROUPS`. fallback: `ch_words` |
| 13 | BND2 | 1 (Q2 reserved, bound>1 재도입용) |
| 14 | SEG_SIZE | 64 (항상 한 beat = 한 bus word) |
| 15 | PAD | 0 |
| 16 | DIR | `dir_is_st` |

> **Note**: `cmd.bound > 1` 경로는 제거됨. SVA로 `bound == 1`을 강제한다.
> 기존 `src_s0 / dst_s0` 필드는 더 이상 ST1에 전달되지 않고 `UNUSED_VAR`로 묶여 있다.

## Ready/Done 집합

```verilog
cfg_all_ready  = &(ch_active ? cfg_ready : 1'b1)   // 모든 활성 채널 ready
done_all_valid = &(ch_active ? done_valid : 1'b1)   // 모든 활성 채널 done
```

비활성 채널은 항상 ready/done이므로 FSM은 활성 채널만 기다린다.
