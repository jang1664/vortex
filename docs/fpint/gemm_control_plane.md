# GEMM Control Plane 아키텍처 분석

> **대상 파일**: `VX_gemm_fsm.sv`, `VX_gemm_sync.sv`, `VX_lmem_dma.sv`, `VX_lmem_dma_misal.sv`  
> **브랜치**: fpint

---

## 1. 전체 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────┐
│                     VX_gemm_fsm (FSM)                       │
│  cfg_reg_if → Job 파싱 → 타일링 → 커맨드 발행              │
│                                                             │
│  [S_IDLE] → [PRE0] → [PRE1] → [WAIT_CUR] → [MXU loop]    │
│                                  → [OUTPUT] → [ADVANCE]     │
└────────────────┬────────────────────────────────────────────┘
                 │ gemm_fsm_if (cmd + start / idle + done)
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                    VX_gemm_sync (Router)                     │
│  WAIT/NOTIFY → 내부 소비 (sync_regs)                        │
│  Normal CMD  → opcode 기반 라우팅 (5개 child)               │
│                                                             │
│  sync_regs[0..8] ← child node들의 완료 신호 수집           │
└──┬──────┬──────┬──────┬──────┬──────────────────────────────┘
   │      │      │      │      │
   ▼      ▼      ▼      ▼      ▼
  [0]    [1]    [2]    [3]    [4]
  Input  Weight Scale  Output  DMA
  LDMA   LDMA   /ZP    Acc→   DRAM
  +ARM          LDMA   LMEM   ↔LMEM
   │      │      │      │      │
   ▼      ▼      ▼      ▼      ▼
  VX_lmem_dma / VX_lmem_dma_misal 인스턴스들
  (각각 lmem_bus_if + gemm_bus_if 로 메모리 접근)
```

### 핵심 데이터 흐름

```
DRAM ──DMA──▶ LMEM(Double Buffer) ──LDMA──▶ GEMM Unit 내부 레지스터
                                              │
                                    MXU 연산 (Input × Weight)
                                              │
                                    ZP Correction + Scale
                                              │
                                    Accumulator Memory (FP32)
                                              │
DRAM ◀──DMA── LMEM(OBUF) ◀──LDMA── FP32→FP16 변환
```

---

## 2. VX_gemm_fsm.sv — 마스터 FSM

### 2.1 역할
- **Config Register**에서 GEMM Job 파라미터 수신 (M, N, K, 각 base address 등)
- 3중 타일 루프 (M-tile × N-tile × K-tile) 스케줄링
- 커맨드를 **한 사이클에 하나씩** `gemm_fsm_if`를 통해 발행
- Double-buffering + Ping-pong으로 DMA preload와 연산을 오버랩

### 2.2 Config Register 맵

| Reg# | 내용 | 비고 |
|------|------|------|
| 0 | Control (LSB = start bit) | start 펄스 |
| 1 | INPUT_BASE (DRAM) | FP16 |
| 2 | WEIGHT_BASE (DRAM) | INT4 packed |
| 3 | OUTPUT_BASE (DRAM) | FP16 |
| 4 | SCALE_BASE (DRAM) | FP16 |
| 5 | ZP_BASE (DRAM) | FP16 |
| 6~7 | LMEM_IBUF0/1_BASE | Input double buffer |
| 8~9 | LMEM_WBUF0/1_BASE | Weight double buffer |
| 10~11 | LMEM_SZBUF0/1_BASE | Scale+ZP double buffer |
| 12 | LMEM_OBUF_BASE | Output buffer (single) |
| 13 | {N[63:32], M[31:0]} | 행렬 크기 |
| 14 | {qblk[63:32], K[31:0]} | K차원 + quant block |

### 2.3 타일링 파라미터 (Compile-time 고정)

```
DMA Tile:  MT=128, NT=128, KT=128
MXU Tile:  MXU_KT=32, MXU_NT=32

DMA Tile 수:
  mt_dim = ceil(M / MT)
  nt_dim = ceil(N / NT)
  kt_dim = ceil(K / KT)
  tile_total = mt_dim × nt_dim × kt_dim

MXU 마이크로 타일 수 (DMA Tile 내부):
  nt_mxu_dim = ceil(nt_eff / MXU_NT)
  kt_mxu_dim = kt_eff / MXU_KT     (나누어떨어진다고 가정)
```

### 2.4 타일 인덱싱

```
Linear tile index: tile = ((nt × mt_dim) + mt) × kt_dim + kt

tile_decode(tile) → (nt, mt, kt)
  kt = tile % kt_dim
  mt = (tile / kt_dim) % mt_dim
  nt = (tile / kt_dim) / mt_dim
```

### 2.5 Double Buffering 체계

```
buf_sel = tile_index[0]    (짝수 타일 → buf0, 홀수 타일 → buf1)
gen     = (tile >> 1) + 1  (같은 버퍼의 세대 번호)

예: tile 0 → buf0, gen=1
    tile 1 → buf1, gen=1
    tile 2 → buf0, gen=2  (buf0 재사용, 이전 store 완료 대기 필요)
    tile 3 → buf1, gen=2
```

### 2.6 FSM 상태 흐름 (전체)

```
┌─── S_IDLE ◀───────────────────────────────────────────┐
│     │ cfg start                                        │
│     ▼                                                  │
│  ┌─ Warmup Phase ─────────────────────────────┐       │
│  │ PRE0_LD_I → _W → _SC → _ZP → _DONE_NTF   │       │
│  │ PRE1_LD_I → _W → _SC → _ZP → _DONE_NTF   │       │
│  └────────────────────────────────────────────┘       │
│     │                                                  │
│     ▼                                                  │
│  ┌─ Steady State (per DMA tile) ──────────────────┐   │
│  │                                                │   │
│  │  WAIT_CUR_TILE_READY                           │   │
│  │     │                                          │   │
│  │     ▼                                          │   │
│  │  ┌─ MXU Loop (per micro tile) ──────────────┐ │   │
│  │  │                                          │ │   │
│  │  │  PRE_CUR_W → _NTF                       │ │   │
│  │  │  PRE_CUR_SC → PRE_CUR_ZP → _NTF        │ │   │
│  │  │  WAIT_CUR_W → WAIT_CUR_SZ               │ │   │
│  │  │  PRE_NEXT_W → _NTF (if has_next)        │ │   │
│  │  │  PRE_NEXT_SC → PRE_NEXT_ZP → _NTF      │ │   │
│  │  │  ARM_GEMM → ARM_GEMM_NTF               │ │   │
│  │  │  WAIT_GEMM_DONE ──────┐                 │ │   │
│  │  │     │ has_next_mxu    │ !has_next_mxu   │ │   │
│  │  │     ▼                 │                 │ │   │
│  │  │  (loop: WAIT_CUR_W)  │                 │ │   │
│  │  └──────────────────────-┘                 │ │   │
│  │                          │                  │ │   │
│  │  ┌─ Output Phase ───────▼──────────────┐  │ │   │
│  │  │  O_ACC2LMEM → _NTF                  │  │ │   │
│  │  │  O_WAIT_ACC2LMEM_DONE               │  │ │   │
│  │  │  O_LMEM2DRAM → _NTF                 │  │ │   │
│  │  └──────────────────────────────────────┘  │ │   │
│  │     │                                       │ │   │
│  │     ▼                                       │ │   │
│  │  ADVANCE_TILES                              │ │   │
│  │     │                                       │ │   │
│  │  ┌─ Preload Next Tile ─────────────────┐   │ │   │
│  │  │  PRE_NEXT_WAIT_REUSE                │   │ │   │
│  │  │  PRE_NEXT_LD_I → _W → _SC → _ZP    │   │ │   │
│  │  │  → _DONE_NTF                        │   │ │   │
│  │  └──┬──────────────────────────────────┘   │ │   │
│  │     │                                       │ │   │
│  │     └──▶ WAIT_CUR_TILE_READY (다음 타일)    │ │   │
│  └─────────────────────────────────────────────┘ │   │
│                                                   │   │
│  (마지막 타일 완료) ──────────────────────────────┘   │
└───────────────────────────────────────────────────────┘
```

### 2.7 Opcode 맵 (커맨드 종류)

| Opcode | 이름 | 설명 | 라우팅 대상 |
|--------|------|------|------------|
| `0xF0` | OP_WAIT | sync_reg 조건 대기 | Sync 내부 소비 |
| `0xF1` | OP_NOTIFY | sync_reg 갱신 | 마지막 CMD의 child |
| `0x10` | OP_DMA_LD | DRAM → LMEM | child[4] DMA |
| `0x11` | OP_DMA_ST | LMEM → DRAM | child[4] DMA |
| `0x20` | OP_W_LDMA_MXU | LMEM → GEMM weight buf | child[1] Weight |
| `0x21` | OP_SC_LDMA_MXU | LMEM → GEMM scale buf | child[2] Scale/ZP |
| `0x24` | OP_ZP_LDMA_MXU | LMEM → GEMM zp buf | child[2] Scale/ZP |
| `0x22` | OP_I_LDMA_ARM | LMEM → GEMM input + GEMM 시작 | child[0] Input |
| `0x23` | OP_O_ACC2LMEM | GEMM acc_mem → LMEM | child[3] Output |

### 2.8 커맨드 패킷 구조 (`gemm_unified_cmd_t`)

```
instr[7:0]   = opcode
instr[15:8]  = flags (buf_sel, mxu_buf, QDIR, is_accum, is_last 등)
instr[31:16] = size_bytes (DMA 전송 크기)
rs1_data     = 용도별 (dst addr, reg_id 등)
rs2_data     = 용도별 (src addr, target value 등)
```

### 2.9 MXU 마이크로 타일 루프 상세

한 DMA 타일 내에서 MXU 크기 단위로 반복:

```
for kt_mxu in 0..kt_mxu_dim-1:
  for nt_mxu in 0..nt_mxu_dim-1:
    mxu_linear = kt_mxu * nt_mxu_dim + nt_mxu

    1) Weight preload (현재 mxu_buf)
    2) Scale preload → ZP preload (현재 mxu_buf)
    3) Wait W ready, Wait SZ ready
    4) Weight/SZ preload (다음 mxu_buf, ping-pong) ← if has_next
    5) ARM: Input LDMA + GEMM 시작
    6) Wait GEMM done
    7) mxu_buf 토글, 다음 micro tile로
```

- **is_accum**: `global_k != 0` → 이전 K 타일 결과에 accumulate
- **is_last**: `global_k + MXU_KT >= K` → 마지막 K 타일, 결과 확정

### 2.10 LMEM 메모리 레이아웃

```
SZBUF 레이아웃:
  [0 .. groups_full*NT*2 - 1]     : Scale (FP16)
  [groups_full*NT*2 .. end]       : Zero Point (FP16)
  (groups_full = ceil(KT / qblk))

Accumulator Memory:
  base = 0x0 (독립 주소 공간)
  각 MXU N-slice: nt_mxu * (mt_eff * MXU_NT * 4bytes)
```

---

## 3. VX_gemm_sync.sv — 동기화 라우터

### 3.1 역할
- FSM에서 오는 커맨드를 **opcode에 따라 5개 child 중 하나로 라우팅**
- **WAIT**: sync_reg 조건 확인, 미충족 시 FSM을 stall (idle=0)
- **NOTIFY**: 마지막 normal cmd와 같은 child로 전달
- **sync_regs[0..8]**: 각 child DMA가 완료 시 update

### 3.2 라우팅 테이블

| Route | Child | 대상 Opcode |
|-------|-------|------------|
| 0 | Input LDMA + ARM | `OP_I_LDMA_ARM` |
| 1 | Weight LDMA | `OP_W_LDMA_MXU` |
| 2 | Scale/ZP LDMA | `OP_SC_LDMA_MXU`, `OP_ZP_LDMA_MXU` |
| 3 | Output (Acc→LMEM) | `OP_O_ACC2LMEM` |
| 4 | DRAM DMA | `OP_DMA_LD`, `OP_DMA_ST` |

### 3.3 Backpressure 모델

```
can_accept 판단:
  WAIT   → wait_satisfied (sync_regs[reg_id] >= target)
  NOTIFY → child_idle (해당 child가 idle 상태인지)
  Normal → child_idle (해당 child가 idle 상태인지)

FSM 쪽에 보내는 신호:
  flag.idle = (!in_valid) ? 1 : can_accept
  → FSM은 idle=1일 때만 다음 커맨드 발행 (can_emit = gemm_fsm_if.flag.idle)
```

### 3.4 Sync Register 관리 (9개)

| Reg# | 이름 | 용도 |
|------|------|------|
| 0 | RID_T0 | buf0 DMA tile preload done |
| 1 | RID_W0 | buf0 MXU weight preload done |
| 2 | RID_SZ0 | buf0 MXU scale/zp preload done |
| 3 | RID_G0 | buf0 GEMM done marker |
| 4 | RID_O | Output store done marker |
| 5 | RID_T1 | buf1 DMA tile preload done |
| 6 | RID_W1 | buf1 MXU weight preload done |
| 7 | RID_SZ1 | buf1 MXU scale/zp preload done |
| 8 | RID_G1 | buf1 GEMM done marker |

### 3.5 Sync Update 정책

```
value[31] == 1 → SET: sync_regs[reg_id] = value[30:0]
value[31] == 0 → ADD: sync_regs[reg_id] += value[30:0]
```

**주의**: 5개 노드가 동시에 같은 reg를 업데이트하면 race condition 발생 가능.
현재는 unrolled로 우선순위 기반 (node0 > node1 > ... > node4).

---

## 4. VX_lmem_dma.sv — Aligned DMA 엔진

### 4.1 역할
- **LMEM ↔ GEMM Unit** 간 데이터 전송
- `DIR=0`: LMEM → GEMM (Read from LMEM, Write to GEMM)
- `DIR=1`: GEMM → LMEM (Read from GEMM, Write to LMEM)
- **seg_size는 BUS_BYTES의 배수**라고 가정 (aligned 전용)

### 4.2 제약 조건
- `lmem_bus_if.DATA_SIZE == gemm_bus_if.DATA_SIZE` (같은 bus width)
- `seg_size`는 `BUS_BYTES`의 배수
- start 신호는 idle 상태에서 1 펄스만

### 4.3 3D Nested Loop

```
for i2 in 0..bound[2]-1:
  for i1 in 0..bound[1]-1:
    for i0 in 0..bound[0]-1:
      src_addr = base_addr[0] + i0*stride[0][0] + i1*stride[0][1] + i2*stride[0][2] + beat_off
      dst_addr = base_addr[1] + i0*stride[1][0] + i1*stride[1][1] + i2*stride[1][2] + beat_off
      
      // seg_size 바이트를 BUS_BYTES 단위로 전송
      for beat_off in 0..seg_size step BUS_BYTES:
        READ src → rd_buf
        WRITE rd_buf → dst
```

### 4.4 FSM 상태 흐름

```
S_IDLE → S_RD_REQ → S_RD_WAIT → S_WR_REQ → S_WR_WAIT
                                    │
                         ┌──────────┤
                         │          │
                  (seg 내 다음 beat) (seg 완료, 다음 index)
                         │          │
                         ▼          │
                    S_RD_REQ    (마지막 index?)
                                    │
                              ┌─────┴─────┐
                              │           │
                          S_SYNC      S_RD_REQ
                              │       (다음 segment)
                          S_DONE
                              │
                          S_IDLE
```

### 4.5 Sync 완료 통지

전체 3D loop 완료 후 `gemm_sync_if`로 `{reg_idx, reg_value}` 전송.
→ `VX_gemm_sync`의 sync_regs가 업데이트됨.

---

## 5. VX_lmem_dma_misal.sv — Misaligned DMA 엔진

### 5.1 역할
- `VX_lmem_dma`와 동일한 기능이지만 **seg_size가 BUS_BYTES의 배수가 아닌 경우** 처리
- **Window Buffer**를 사용하여 source와 destination의 misalignment 해결

### 5.2 핵심 차이점 (vs aligned 버전)

| 항목 | VX_lmem_dma (aligned) | VX_lmem_dma_misal |
|------|----------------------|-------------------|
| seg_size 제약 | BUS_BYTES 배수 | 제한 없음 |
| Misalign 처리 | 없음 | Window buffer 사용 |
| FSM 상태 수 | 7개 | 10개 |
| 복잡도 | 낮음 | 높음 (window 관리) |

### 5.3 Window Buffer 메커니즘

```
┌─────────────────────────────────────────┐
│  Window Buffer (2 × BUS_BYTES)          │
│                                         │
│  [byte0][byte1]...[byteN]  (win_valid)  │
│   ▲                                     │
│   │ src_rsp_fire: append BUS_BYTES      │
│   │ wr_commit:    consume wr_nbytes     │
│   │ src_drop:     초기 misalign 제거    │
└─────────────────────────────────────────┘

Source Read:
  src_rd_ptr = align_down(base_src_seg)   // bus 정렬된 시작
  src_rd_end = align_up(base_src_seg + seg_size)  // bus 정렬된 끝
  src_drop   = base_src_seg % BUS_BYTES   // 앞쪽 버릴 바이트

Destination Write:
  lane      = dst_byte_addr % BUS_BYTES   // bus 내 시작 lane
  beat_room = BUS_BYTES - lane            // 이 beat에서 쓸 수 있는 바이트
  wr_nbytes = min(remaining, beat_room)   // 실제 쓸 바이트
  wr_byteen = mask_range(lane, wr_nbytes) // byte enable 마스크
```

### 5.4 FSM 상태 흐름

```
S_IDLE → S_PREP_SEG → S_DECIDE
                          │
              ┌───────────┼───────────┐
              │           │           │
         (need more)  (src_drop)  (enough)
              │           │           │
         S_SRC_RD_REQ  S_DECIDE   S_DST_WR_REQ
              │        (drop후)       │
         S_SRC_RD_WAIT            S_DST_WR_WAIT (DIR=0만)
              │                       │
              └───▶ S_DECIDE ◀────────┘
                          │
                   (segment 완료)
                          │
                     S_ADV_SEG
                          │
                ┌─────────┼─────────┐
                │                   │
           (마지막 idx)        (다음 idx)
                │                   │
            S_SYNC            S_PREP_SEG
                │
            S_DONE → S_IDLE
```

### 5.5 핵심 로직: S_DECIDE 판단

```
if (src_drop != 0 && win_valid >= src_drop):
    → stay S_DECIDE (sequential에서 drop 수행)
else if (need_src > win_valid && src_rd_ptr < src_rd_end):
    → S_SRC_RD_REQ (window에 데이터 부족, 더 읽기)
else:
    → S_DST_WR_REQ (window에 충분, 쓰기 진행)
```

---

## 6. 인터페이스 정리

### 6.1 VX_gemm_fsm_if

```
ctrl (master → slave):
  .cmd   : gemm_unified_cmd_t  (opcode, flags, size, rs1, rs2 등)
  .start : 1-bit               (커맨드 유효 펄스)

flag (slave → master):
  .idle  : 1-bit               (수신 가능 = ready)
  .done  : 1-bit               (작업 완료)
```

### 6.2 VX_lmem_dma_ctrl_if

```
master → slave:
  .start          : 시작 펄스
  .src_base_addr  : source 시작 주소 (32-bit)
  .dst_base_addr  : dest 시작 주소 (32-bit)
  .src_strides[3] : source 3D stride
  .dst_strides[3] : dest 3D stride
  .bounds[3]      : 3D loop 반복 횟수
  .seg_size       : 1회 전송 크기 (bytes)
  .reg_idx        : 완료 시 sync reg 번호
  .reg_value      : 완료 시 sync value

slave → master:
  .idle            : IDLE 상태
  .done            : DONE 상태 (1-cycle 펄스)
```

### 6.3 VX_gemm_sync_if

```
master (DMA node → Sync):
  .valid   : 업데이트 유효
  .reg_idx : 갱신할 sync register 번호
  .value   : 갱신 값 (bit[31]=1이면 SET, 아니면 ADD)

slave (Sync → DMA node):
  .ready   : 항상 1 (현재 구현)
```

---

## 7. 전체 실행 시나리오 예시

### M=256, N=256, K=128, qblk=32인 경우

```
타일 크기: MT=128, NT=128, KT=128
mt_dim=2, nt_dim=2, kt_dim=1
tile_total = 2 × 2 × 1 = 4

타일 순서 (linear):
  tile 0: (nt=0, mt=0, kt=0) → buf0, gen=1
  tile 1: (nt=0, mt=1, kt=0) → buf1, gen=1
  tile 2: (nt=1, mt=0, kt=0) → buf0, gen=2
  tile 3: (nt=1, mt=1, kt=0) → buf1, gen=2

MXU micro tile (per DMA tile):
  nt_mxu_dim = 128/32 = 4
  kt_mxu_dim = 128/32 = 4
  총 16개 micro tile per DMA tile
```

### 실행 순서

```
1. [Warmup] Tile 0 preload (I,W,SC,ZP → LMEM buf0) + NOTIFY
2. [Warmup] Tile 1 preload (I,W,SC,ZP → LMEM buf1) + NOTIFY
3. [Tile 0] WAIT tile0 ready
4. [Tile 0] MXU loop ×16: W→MXU, SC/ZP→MXU, ARM GEMM, WAIT done
5. [Tile 0] Output: Acc→LMEM→DRAM
6. [Advance] cur=tile1, preload tile2 into buf0 (WAIT buf0 reuse)
7. [Tile 1] WAIT tile1 ready → MXU loop → Output
8. [Advance] cur=tile2, preload tile3 into buf1 (WAIT buf1 reuse)
9. [Tile 2] WAIT tile2 ready → MXU loop → Output
10. [Advance] cur=tile3, no more preload
11. [Tile 3] WAIT tile3 ready → MXU loop → Output
12. [Done] → S_IDLE
```

---

## 8. 핵심 동기화 패턴 정리

### 8.1 DMA Tile Preload Done

```
FSM: NOTIFY(RID_T{buf}, 4*gen+4, SET)   // preload 완료 마킹
FSM: WAIT(RID_T{buf}, 4*gen+4)          // preload 완료 대기
```

### 8.2 MXU Weight/SZ Preload

```
FSM: W_LDMA_MXU → NOTIFY(RID_W{mxu_buf}, linear+1, SET)
FSM: WAIT(RID_W{mxu_buf}, linear+1)

FSM: SC_LDMA_MXU → ZP_LDMA_MXU → NOTIFY(RID_SZ{mxu_buf}, linear+1, SET)
FSM: WAIT(RID_SZ{mxu_buf}, linear+1)
```

### 8.3 GEMM Done

```
FSM: I_LDMA_ARM (GEMM 시작) → NOTIFY(RID_G{mxu_buf}, target, SET)
// (i_ldma child가 완료 시 sync_if로 전달 → sync_regs 업데이트)
FSM: WAIT(RID_G{mxu_buf}, target)
```

### 8.4 Output Store / Buffer Reuse

```
FSM: O_ACC2LMEM → NOTIFY(RID_O, 2*gen+1, SET)     // acc→lmem 완료
FSM: WAIT(RID_O, 2*gen+1)
FSM: O_LMEM2DRAM → NOTIFY(RID_O, +1, ADD)         // lmem→dram 완료 (add)
// → RID_O = 2*gen+2

// 다음 같은 버퍼 사용 시:
FSM: WAIT(RID_O, 2*prev_gen+2)                     // 이전 store 완료 대기
```

---

## 9. 공부 팁: 추적해볼 시나리오

1. **단일 타일** (M≤128, N≤128, K≤128): Warmup PRE0만 수행, MXU loop 한 번
2. **2개 타일**: Double buffering의 preload 오버랩 동작 확인
3. **K 방향 축적**: `is_accum`/`is_last` 플래그 변화 추적
4. **Misaligned 전송**: INT4 packed weight가 seg_size=BUS_BYTES 배수가 아닌 경우
