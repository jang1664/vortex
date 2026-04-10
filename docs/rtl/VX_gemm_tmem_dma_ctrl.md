# VX_gemm_tmem_dma_ctrl

## 개요

GEMM DMA 명령을 8채널 DMA engine 설정 레지스터로 변환하는 컨트롤러. 64바이트 bus-word 단위로 seg_size를 채널에 분배한다.

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

## Stride 설정

| 필드 | LD (HBM→TMEM) | ST (TMEM→HBM) |
|------|---------------|---------------|
| `SRC_ST0` | 512 | 64 |
| `DST_ST0` | 64 | 512 |
| `SRC_ST1` | `src_s0` (full) | `src_s0 >> 3` (bank-local) |
| `DST_ST1` | `dst_s0 >> 3` (bank-local) | `dst_s0` (full) |

- **ST0**: inner stride — HBM은 512B(채널 간격), TMEM은 64B(연속)
- **ST1**: outer stride — bank-local 주소 체계에 맞게 `>> 3` 변환

## 채널별 Config 레지스터 맵

| 인덱스 | 레지스터 | 값 |
|--------|----------|-----|
| 0 | CONTROL | `ch_active ? 1 : 0` |
| 1-2 | DST_BASE (LO/HI) | 채널별 dst_base |
| 3-4 | SRC_BASE (LO/HI) | 채널별 src_base |
| 5 | SRC_ST0 | 방향별 inner stride |
| 6 | DST_ST0 | 방향별 inner stride |
| 7 | SRC_ST1 | 방향별 outer stride |
| 8 | DST_ST1 | 방향별 outer stride |
| 9 | SRC_ST2 | 0 |
| 10 | DST_ST2 | 0 |
| 11 | BND0 | `ch_words` (채널별 bus-word 수) |
| 12 | BND1 | `bnd0` (원래 bound, multi-segment 반복) |
| 13 | BND2 | 1 |
| 14 | SEG_SIZE | 64 (항상 64B) |
| 15 | PAD | 0 |
| 16 | DIR | `dir_is_st` |

## Ready/Done 집합

```verilog
cfg_all_ready  = &(ch_active ? cfg_ready : 1'b1)   // 모든 활성 채널 ready
done_all_valid = &(ch_active ? done_valid : 1'b1)   // 모든 활성 채널 done
```

비활성 채널은 항상 ready/done이므로 FSM은 활성 채널만 기다린다.
