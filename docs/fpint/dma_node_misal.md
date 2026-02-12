# VX_dma_node_misal.sv — DCACHE ↔ LMEM DMA 엔진 분석

> **파일**: `hw/rtl/core/VX_dma_node_misal.sv`  
> **브랜치**: fpint  
> **역할**: Data Cache와 Local Memory 사이의 Misaligned DMA 전송

---

## 1. 개요

```
┌─────────────┐                              ┌─────────────┐
│   DCACHE    │◀── dcache_bus_if ──▶│         │   LMEM      │
│  (Global)   │                     │  DMA    │  (Local)    │
│             │    L2G (dir=0)      │  Node   │             │
│             │ ◀────────────────── │         │             │
│             │    G2L (dir=1)      │  misal  │             │
│             │ ──────────────────▶ │         │             │
└─────────────┘                     │         └─────────────┘
                                    │
                    cfg_reg_if ────▶│  (LSU에서 DMA descriptor 전달)
```

### 핵심 특징
- **양방향**: L2G (LMEM→DCACHE) 또는 G2L (DCACHE→LMEM) 방향 선택
- **3D Nested Loop**: 3차원 stride/bound로 복잡한 메모리 레이아웃 대응
- **Misaligned 지원**: seg_size에 제한 없음 (bus width 배수 불필요)
- **Zero Padding**: 세그먼트 끝에 자동 zero padding 삽입
- **Window Buffer**: 소스 측 misalignment을 흡수하는 스트리밍 버퍼

---

## 2. VX_lmem_dma_misal.sv와의 비교

| 항목 | VX_lmem_dma_misal (GEMM 내부) | VX_dma_node_misal (Core 레벨) |
|------|-------------------------------|-------------------------------|
| **위치** | GEMM Unit 내부 | Core 레벨 (LSU ↔ LMEM) |
| **인터페이스** | lmem_bus_if + gemm_bus_if | dcache_bus_if + lmem_bus_if |
| **소스/목적지** | LMEM ↔ GEMM 레지스터 | DCACHE ↔ LMEM |
| **방향 파라미터** | DIR (compile-time) | direction_bit (runtime) |
| **Padding** | 없음 | Zero Padding 지원 |
| **Sync** | gemm_sync_if로 완료 통지 | done 시그널 (1-cycle) |
| **Bus Width** | 동일 가정 | DCACHE ≥ LMEM (배수 가정) |
| **Config** | VX_lmem_dma_ctrl_if | VX_config_reg_if (15-word descriptor) |
| **Window** | 단일 (src 측) | 이중 (lmem용 + dcache용) |

---

## 3. Config Descriptor (15 Words)

LSU에서 `cfg_reg_if`를 통해 전달되는 DMA descriptor:

```
64-bit 레지스터를 32-bit word로 unpack:
  R0 = {desc_w[1], desc_w[0]}
  R1 = {desc_w[3], desc_w[2]}
  ...
  R7 = {desc_w[14], desc_w[13]}   (padding 포함)
```

| Word# | 이름 | 설명 |
|-------|------|------|
| 0 | control_reg | bit[0]=start, bit[1]=direction |
| 1 | (reserved) | — |
| 2 | src_base | Source 시작 바이트 주소 |
| 3 | dst_base | Destination 시작 바이트 주소 |
| 4 | src_stride[0] | Source dim0 stride (bytes) |
| 5 | dst_stride[0] | Dest dim0 stride (bytes) |
| 6 | src_stride[1] | Source dim1 stride (bytes) |
| 7 | dst_stride[1] | Dest dim1 stride (bytes) |
| 8 | src_stride[2] | Source dim2 stride (bytes) |
| 9 | dst_stride[2] | Dest dim2 stride (bytes) |
| 10 | bound[0] | Dim0 반복 횟수 |
| 11 | bound[1] | Dim1 반복 횟수 |
| 12 | bound[2] | Dim2 반복 횟수 |
| 13 | seg_size | 1회 전송 크기 (bytes) |
| 14 | padding | 끝에서 zero padding 바이트 수 |

### Direction Bit

```
direction_bit = 0: L2G (LMEM → DCACHE)
  src = LMEM,   dst = DCACHE
  Window: win_lmem (LMEM에서 읽어서 버퍼링)
  Write:  DCACHE (write response 대기)

direction_bit = 1: G2L (DCACHE → LMEM)
  src = DCACHE,  dst = LMEM
  Window: win_dcache (DCACHE에서 읽어서 버퍼링)
  Write:  LMEM (req handshake로 commit, response 불필요)
```

---

## 4. 3D Nested Loop + Segment

### 주소 계산

```
for i2 in 0..bound[2]-1:
  for i1 in 0..bound[1]-1:
    for i0 in 0..bound[0]-1:

      base_src_seg = src_base + i0*src_stride[0] + i1*src_stride[1] + i2*src_stride[2]
      base_dst_seg = dst_base + i0*dst_stride[0] + i1*dst_stride[1] + i2*dst_stride[2]

      // seg_size 바이트를 전송 (마지막 padding 바이트는 0으로 채움)
      transfer(base_src_seg, base_dst_seg, seg_size, padding)
```

### Segment 내 바이트 흐름

```
seg_size = 100, padding = 20 의 경우:

|←─── valid_total = 80 ───→|←── padding = 20 ──→|
[source data: 80 bytes     ] [zero: 20 bytes     ]
|←──────────── seg_size = 100 ──────────────────→|
```

- `valid_total = seg_size - padding`
- `out_off < valid_total` → source에서 실제 데이터 읽기
- `out_off >= valid_total` → zero 쓰기 (source 읽기 불필요)

---

## 5. FSM 상태 흐름

### 5.1 공통 부분

```
S_IDLE ──(cfg_fire && start_bit)──▶ S_PREP_SEG
                                        │
                              ┌─────────┴─────────┐
                              │ dir=0 (L2G)       │ dir=1 (G2L)
                              ▼                   ▼
                        S_L2G_DECIDE         S_G2L_DECIDE
                           ...                  ...
                              │                   │
                              └─────────┬─────────┘
                                        ▼
                                   S_ADV_SEG
                                        │
                              ┌─────────┴─────────┐
                              │ 마지막 index       │ 다음 index
                              ▼                   ▼
                           S_DONE           S_PREP_SEG
                              │
                           S_IDLE
```

### 5.2 L2G (LMEM → DCACHE) 상세

```
S_PREP_SEG
    │ win_lmem 초기화, lmem_rd_ptr/end/drop 설정
    ▼
S_L2G_DECIDE ◀──────────────────────────────┐
    │                                        │
    ├─ (lmem_drop && enough) → stay (drop)   │
    │                                        │
    ├─ (need_src > win_valid                 │
    │   && lmem_rd_ptr < end)                │
    │       │                                │
    │       ▼                                │
    │   S_L2G_SRC_RD_REQ                    │
    │       │ lmem read request              │
    │       ▼                                │
    │   S_L2G_SRC_RD_WAIT                   │
    │       │ lmem_rsp → append to win_lmem  │
    │       └────────────────────────────────┘
    │
    └─ (window에 충분)
        │
        ▼
    S_L2G_DST_WR_REQ
        │ dcache write (valid data + zero padding)
        ▼
    S_L2G_DST_WR_WAIT
        │ dcache_rsp → consume win_lmem, advance out_off
        │
        ├─ (out_off + wr_nbytes >= seg_size) → S_ADV_SEG
        └─ (계속) → S_L2G_DECIDE
```

**L2G 특징:**
- Source: **LMEM** (read request → response 대기 → window에 append)
- Dest: **DCACHE** (write request → **response 대기 필요**)
- Window: `win_lmem` 사용

### 5.3 G2L (DCACHE → LMEM) 상세

```
S_PREP_SEG
    │ win_dcache 초기화, dcache_rd_ptr/end/drop 설정
    ▼
S_G2L_DECIDE ◀──────────────────────────────┐
    │                                        │
    ├─ (dcache_drop && enough) → stay (drop) │
    │                                        │
    ├─ (need_src > win_valid                 │
    │   && dcache_rd_ptr < end)              │
    │       │                                │
    │       ▼                                │
    │   S_G2L_SRC_RD_REQ                    │
    │       │ dcache read request            │
    │       ▼                                │
    │   S_G2L_SRC_RD_WAIT                   │
    │       │ dcache_rsp → append to win      │
    │       └────────────────────────────────┘
    │
    └─ (window에 충분)
        │
        ▼
    S_G2L_DST_WR_REQ
        │ lmem write (valid data + zero padding)
        │ req_fire로 즉시 commit (response 불필요!)
        │ consume win_dcache, advance out_off
        │
        ├─ (out_off + wr_nbytes >= seg_size) → S_ADV_SEG
        └─ (계속) → S_G2L_DECIDE
```

**G2L 특징:**
- Source: **DCACHE** (read request → response 대기 → window에 append)
- Dest: **LMEM** (write request → **req handshake만으로 commit, WR_WAIT 상태 없음!**)
- Window: `win_dcache` 사용

---

## 6. Window Buffer 메커니즘

### 6.1 구조

```
WIN_BYTES = 2 × MAX_BYTES (= 2 × DCACHE_BYTES)

┌─────────────────────────────────────────────┐
│  Window Buffer (2 × DCACHE_BYTES)           │
│                                             │
│  [byte0][byte1]...[byteN-1]                │
│   ▲ head (LSB)        ▲ win_valid          │
│                                             │
│  Operations:                                │
│  1. Append: rsp → win[valid*8 +: BUS*8]    │
│  2. Drop:   win >>= (drop * 8)             │
│  3. Consume: win >>= (src_bytes * 8)        │
└─────────────────────────────────────────────┘
```

### 6.2 이중 Window (L2G vs G2L)

```
direction_bit = 0 (L2G):
  ┌──────────┐     ┌──────────┐     ┌──────────┐
  │  LMEM    │────▶│ win_lmem │────▶│ DCACHE   │
  │  (src)   │read │ (buffer) │write│ (dst)    │
  └──────────┘     └──────────┘     └──────────┘

direction_bit = 1 (G2L):
  ┌──────────┐     ┌────────────┐     ┌──────────┐
  │  DCACHE  │────▶│ win_dcache │────▶│  LMEM    │
  │  (src)   │read │ (buffer)   │write│  (dst)   │
  └──────────┘     └────────────┘     └──────────┘
```

### 6.3 Misalignment 처리 흐름

**예: src_base = 0x03, LMEM_BYTES = 4 (L2G)**

```
Step 1: S_PREP_SEG
  lmem_drop   = 0x03 & 0x03 = 3      ← 앞 3바이트 버려야 함
  lmem_rd_ptr = align_down(0x03, 4) = 0x00
  lmem_rd_end = align_up(0x03 + valid_total, 4)

Step 2: S_L2G_SRC_RD_REQ → S_L2G_SRC_RD_WAIT
  Read 0x00: [byte0 byte1 byte2 byte3] → win_lmem에 append
  win_lmem_valid = 4

Step 3: S_L2G_DECIDE
  lmem_drop=3, win_valid=4 → drop 조건 충족!
  win_lmem >>= (3*8)  → [byte3 _ _ _]
  win_lmem_valid = 1, lmem_drop = 0

Step 4: S_L2G_DECIDE
  need_src와 win_valid 비교 → 부족하면 SRC_RD_REQ → 충분하면 DST_WR_REQ
```

---

## 7. Zero Padding 처리

### 데이터 생성 로직 (Destination Write)

```systemverilog
for (b = 0; b < BUS_BYTES; b++) begin
  if ((b >= lane) && (b < lane + wr_nbytes)) begin
    if ((b - lane) < src_bytes) begin
      wr_data[b*8 +: 8] = window[(b - lane)*8 +: 8];  // 실제 데이터
    end else begin
      wr_data[b*8 +: 8] = 8'h00;                       // zero padding
    end
  end
end
```

**핵심 변수:**
- `wr_nbytes`: 이번 beat에서 쓰는 총 바이트 (data + padding)
- `src_bytes`: 이번 beat에서 window에서 가져오는 실제 바이트 (padding 제외)
- `wr_nbytes - src_bytes`: zero로 채울 바이트 수

### 예시

```
seg_size=10, padding=3, valid_total=7, out_off=5

remaining = 10 - 5 = 5
src_bytes = min(7 - 5, wr_nbytes) = min(2, wr_nbytes)
→ 2바이트는 실제 데이터, 나머지는 zero padding
```

---

## 8. L2G vs G2L 핵심 차이 요약

| 항목 | L2G (LMEM→DCACHE) | G2L (DCACHE→LMEM) |
|------|-------------------|-------------------|
| Source Read | LMEM (LMEM_BYTES 단위) | DCACHE (DCACHE_BYTES 단위) |
| Dest Write | DCACHE | LMEM |
| Write Commit | **rsp 대기** (S_L2G_DST_WR_WAIT) | **req handshake** (S_G2L_DST_WR_REQ에서 즉시) |
| Window | win_lmem | win_dcache |
| Alignment granularity | LMEM_BYTES | DCACHE_BYTES |
| Dst lane 계산 | `dst % DCACHE_BYTES` | `dst % LMEM_BYTES` |
| Byteen mask | `mask_dcache_range()` | `mask_lmem_range()` |

**G2L에 WR_WAIT 상태가 없는 이유:**
- LMEM은 단순 SRAM이므로 write response를 돌려주지 않음
- `req_ready`만 확인하면 write가 commit됨

---

## 9. 3D Index Advance 로직

```
S_ADV_SEG에서:

if (out_off >= seg_size):         // 세그먼트 완료 확인
  out_off = 0
  
  if (i_dim[0] + 1 < bound[0]):   // dim0 먼저 증가
    i_dim[0]++
  else:
    i_dim[0] = 0
    if (i_dim[1] + 1 < bound[1]): // dim1 carry
      i_dim[1]++
    else:
      i_dim[1] = 0
      if (i_dim[2] + 1 < bound[2]): // dim2 carry
        i_dim[2]++
      else:
        i_dim[2] = 0
        state = S_DONE             // 모든 차원 완료!
```

**S_DONE → S_IDLE**: 1-cycle pulse 후 자동 복귀

---

## 10. UUID 추적

```systemverilog
dma_uuid = {wid[UUID_WIDTH/2-1:0], tid[UUID_WIDTH/2-1:0]}
```

- `wid`: Work-item ID
- `tid`: Thread ID
- 모든 bus request의 `tag.uuid`에 할당 → 캐시/메모리 시스템에서 DMA 요청 추적 가능

---

## 11. VX_lmem_dma_misal과의 아키텍처 관계

```
┌──────────────────────────────────────────────────────────────┐
│                          Core                                │
│                                                              │
│  ┌──────────┐    cfg_reg_if    ┌───────────────────┐        │
│  │   LSU    │ ───────────────▶ │ VX_dma_node_misal │        │
│  │          │                  │  (DCACHE↔LMEM)    │        │
│  └──────────┘                  └─────┬───────┬─────┘        │
│                                      │       │              │
│                            dcache_bus_if  lmem_bus_if       │
│                                      │       │              │
│                                      ▼       ▼              │
│                                  ┌──────┐ ┌──────┐          │
│                                  │DCACHE│ │ LMEM │          │
│                                  └──────┘ └──┬───┘          │
│                                              │              │
│                              lmem_bus_if / gemm_bus_if      │
│                                              │              │
│                                 ┌────────────┴────────────┐ │
│                                 │      GEMM Unit          │ │
│                                 │                         │ │
│                                 │  ┌───────────────────┐  │ │
│                                 │  │VX_lmem_dma_misal  │  │ │
│                                 │  │  (LMEM↔GEMM regs) │  │ │
│                                 │  └───────────────────┘  │ │
│                                 └─────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘

데이터 흐름 (GEMM 전체):
  DRAM → DCACHE → [VX_dma_node_misal] → LMEM → [VX_lmem_dma_misal] → GEMM Unit
  DRAM ← DCACHE ← [VX_dma_node_misal] ← LMEM ← [VX_lmem_dma_misal] ← GEMM Unit
```

---

## 12. 공부 팁: 디버깅/추적 시나리오

1. **기본 aligned 전송**: seg_size = BUS_BYTES × N, padding = 0, base가 정렬됨
   - DECIDE → DST_WR 즉시 진행, drop 없음
2. **Misaligned source**: src_base가 정렬되지 않음
   - PREP_SEG에서 drop 값 확인 → DECIDE에서 drop 적용 과정 추적
3. **Zero padding**: padding > 0
   - out_off가 valid_total에 도달한 이후의 write 데이터 확인 (0x00)
4. **2D strided 전송**: bound[0]=4, stride 다름
   - ADV_SEG에서 i_dim 증가 → base_src_seg/base_dst_seg 변화 추적
5. **L2G vs G2L 차이**: G2L에서 WR_WAIT 없이 req_fire로 commit 되는 점 확인
