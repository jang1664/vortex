# LSU Unit 계층 구조 — 상세 분석

파일 위치: `hw/rtl/core/VX_lsu_unit.sv`, `VX_lsu_slice.sv`, `VX_mem_unit.sv`

목적(한 문장)
- LSU (Load-Store Unit) 계층은 코어의 메모리 접근 명령을 처리하며, dispatch → execute → local/global 분기 → coalescing → cache 순서로 요청을 처리하고 응답을 병합합니다.

---

## LSU 계층 구조 개요

```
VX_lsu_unit (최상위)
  ↓
VX_dispatch_unit (명령어 분배)
  ↓
VX_lsu_slice [NUM_LSU_BLOCKS] (병렬 실행 슬라이스)
  ↓
VX_mem_scheduler (요청 스케줄링)
  ↓
VX_mem_unit (메모리 유닛)
  ↓
VX_lmem_switch (local/global 분기)
  ├─ local_out_if → VX_lsu_mem_arb → VX_local_mem
  └─ global_out_if → VX_mem_coalescer → D-Cache
```

---

## 1. `VX_lsu_unit.sv` — LSU 최상위 모듈

### 주요 파라미터
- `INSTANCE_ID` : 인스턴스 이름 (디버깅용)
- `BLOCK_SIZE` = `NUM_LSU_BLOCKS` : 병렬 LSU 블록 수
- `NUM_LANES` = `NUM_LSU_LANES` : 레인 수 (SIMD 폭)

### 주요 포트
- `dispatch_if[ISSUE_WIDTH]` (slave) : Dispatch 단계에서 오는 명령어
- `commit_if[ISSUE_WIDTH]` (master) : Commit 단계로 가는 결과
- `lsu_mem_if[NUM_LSU_BLOCKS]` (master) : 메모리 인터페이스 (각 블록당)

### 내부 구조
```systemverilog
VX_dispatch_unit
  - dispatch_if[ISSUE_WIDTH] → execute_if[NUM_LSU_BLOCKS]
  - 명령어를 NUM_LSU_BLOCKS로 분배
  - OUT_BUF=3 (버퍼링)

VX_lsu_slice [NUM_LSU_BLOCKS]
  - 각 블록별로 독립적인 LSU 처리
  - execute_if → result_if (처리 결과)
  - lsu_mem_if (메모리 요청/응답)
    - bitwidth는 XLEN [bit]

VX_gather_unit
  - result_if[NUM_LSU_BLOCKS] → commit_if[ISSUE_WIDTH]
  - 각 블록의 결과를 병합하여 commit 단계로 전달
  - OUT_BUF=3
```

---

## 2. `VX_lsu_slice.sv` — LSU 실행 슬라이스

### 주요 기능
1. **주소 계산**: `full_addr = rs1_data + offset`
2. **메모리 타입 판별**: IO / Local / Global
3. **요청 스케줄링**: Fence, Write/Read 처리
4. **응답 포맷팅**: 부분 읽기(byte, half-word) → 전체 워드 확장

### 주소 타입 판별 (VX_lsu_slice.sv:68-80)

```systemverilog
// 각 레인별로 주소 타입 판별
for (genvar i = 0; i < NUM_LANES; ++i) begin
    wire [MEM_ADDRW-1:0] block_addr = full_addr[i][MEM_ASHIFT +: MEM_ADDRW];
    
    // IO 주소 범위
    wire [MEM_ADDRW-1:0] io_addr_start = IO_BASE_ADDR >> MEM_ASHIFT;
    wire [MEM_ADDRW-1:0] io_addr_end = IO_END_ADDR >> MEM_ASHIFT;
    assign mem_req_flags[i][MEM_REQ_FLAG_IO] = (block_addr >= io_addr_start) && (block_addr < io_addr_end);
    
    // Local memory 주소 범위
    wire [MEM_ADDRW-1:0] lmem_addr_start = LMEM_BASE_ADDR >> MEM_ASHIFT;
    wire [MEM_ADDRW-1:0] lmem_addr_end = (LMEM_BASE_ADDR + (1 << LMEM_LOG_SIZE)) >> MEM_ASHIFT;
    assign mem_req_flags[i][MEM_REQ_FLAG_LOCAL] = (block_addr >= lmem_addr_start) && (block_addr < lmem_addr_end);
end
```

**핵심**: 각 레인의 주소를 **독립적으로** 판별 → 하나의 warp 내에서 **레인별로 다른 메모리 타입 접근 가능!**

### Fence 처리

```systemverilog
reg fence_lock;

// Fence 요청 시 EOP까지 기다린 후 lock
always @(posedge clk) begin
    if (mem_req_fire && req_is_fence && execute_if.data.eop) begin
        fence_lock <= 1;
    end
    if (mem_rsp_fire && rsp_is_fence && mem_rsp_eop_pkt) begin
        fence_lock <= 0;
    end
end
```

- Fence는 메모리 일관성 보장을 위한 동기화 명령
- Fence 후 모든 이전 메모리 연산이 완료될 때까지 대기

### Multi-Packet 추적 (PID_BITS != 0)

```systemverilog
// 여러 패킷으로 나뉜 load 응답의 SOP/EOP 추적
reg [LSUQ_IN_SIZE-1:0][PID_BITS:0] pkt_ctr;  // 패킷 카운터
reg [LSUQ_IN_SIZE-1:0] pkt_sop, pkt_eop;     // SOP/EOP 플래그

VX_allocator pkt_allocator (
    .acquire_en (mem_req_rd_eop_fire),    // 읽기 요청 EOP 시 할당
    .acquire_addr(pkt_waddr),
    .release_en (mem_rsp_eop_pkt_fire),   // 응답 EOP 패킷 시 해제
    .release_addr(pkt_raddr)
);
```

- 큰 데이터를 여러 패킷으로 분할 전송 시 순서 추적
- SOP (Start Of Packet), EOP (End Of Packet) 플래그로 경계 표시

### TAG 구성

```systemverilog
assign mem_req_tag = {
    execute_if.data.uuid,        // 디버깅용 고유 ID
    execute_if.data.wid,         // Warp ID
    execute_if.data.PC,          // Program Counter
    execute_if.data.wb,          // Writeback 필요 여부
    execute_if.data.rd,          // 목적지 레지스터
    execute_if.data.op_type,     // LSU 연산 타입
    req_align,                   // 주소 정렬 정보
    execute_if.data.pid,         // Packet ID
    pkt_waddr,                   // 패킷 할당 주소
    req_is_fence                 // Fence 플래그
};
```

---

## 3. `VX_mem_unit.sv` — 메모리 유닛

### 주요 기능
1. **Local/Global 분기**: `VX_lmem_switch`로 주소 타입별 라우팅
2. **Local memory 처리**: `VX_lsu_mem_arb` → `VX_local_mem`
3. **Coalescing**: 여러 레인 요청을 큰 단위로 병합
4. **D-Cache 연결**: Coalesced 요청을 D-Cache로 전달

### Local Memory 경로 (LMEM_ENABLE)

```systemverilog
// 1. Local/Global 분기
VX_lmem_switch lmem_switch (
    .lsu_in_if    (lsu_mem_if[i]),
    .global_out_if(lsu_dcache_if[i]),   // Global → D-Cache
    .local_out_if (lsu_lmem_if[i])      // Local → Local Mem
);

// 2. Local memory 중재 (여러 LSU 블록 → 하나의 Local Mem)
VX_lsu_mem_arb lmem_arb (
    .bus_in_if  (lsu_lmem_if),          // [NUM_LSU_BLOCKS]
    .bus_out_if (lmem_arb_if)           // [1]
);

// 3. LSU 인터페이스 → 메모리 버스 변환
VX_lsu_adapter lmem_adapter (
    .lsu_mem_if (lmem_arb_if[0]),
    .mem_bus_if (lmem_adapt_if)         // [NUM_LSU_LANES]
);

// 4. Local memory 인스턴스
VX_local_mem local_mem (
    .mem_bus_if (lmem_adapt_if)         // [NUM_LSU_LANES]
);
```

### Global Memory 경로 (D-Cache)

```systemverilog
// 1. Coalescing (작은 요청 → 큰 요청 병합)
VX_mem_coalescer mem_coalescer (
    .in_req_*  (lsu_dcache_if[i]),           // LSU_WORD_SIZE
    .out_req_* (dcache_coalesced_if[i])     // DCACHE_WORD_SIZE
);

// 2. LSU 인터페이스 → 메모리 버스 변환
VX_lsu_adapter dcache_adapter (
    .lsu_mem_if (dcache_coalesced_if[i]),
    .mem_bus_if (dcache_bus_if[i * DCACHE_CHANNELS + j])
);
```

---

## 4. Local/Global 동시 접근 가능성 분석

### 질문: "하나의 warp에서 local과 global access가 동시에 존재할 수 있는가?"

**답: 예, 가능합니다!**

### 증거 1: `VX_lsu_slice.sv` 레인별 독립 판별

```systemverilog
// 각 레인마다 독립적으로 주소 타입 판별
for (genvar i = 0; i < NUM_LANES; ++i) begin
    assign mem_req_flags[i][MEM_REQ_FLAG_LOCAL] = (block_addr >= lmem_addr_start) && (block_addr < lmem_addr_end);
end
```

- Lane 0: 주소 0x1000 (Global) → `flags[0][LOCAL] = 0`
- Lane 1: 주소 0x8000 (Local) → `flags[1][LOCAL] = 1`
- Lane 2: 주소 0x1004 (Global) → `flags[2][LOCAL] = 0`
- **동일한 warp, 동일한 load/store 명령이지만 레인별 주소가 다르면 타입도 다름!**

### 증거 2: `VX_lmem_switch.sv` 레인별 마스크 분리

```systemverilog
// 레인별 local 여부를 마스크로 표현
wire [NUM_LSU_LANES-1:0] is_addr_local_mask;
for (genvar i = 0; i < NUM_LSU_LANES; ++i) begin
    assign is_addr_local_mask[i] = lsu_in_if.req_data.flags[i][MEM_REQ_FLAG_LOCAL];
end

// Global/Local 존재 여부 체크
wire is_addr_global = | (lsu_in_if.req_data.mask & ~is_addr_local_mask);
wire is_addr_local  = | (lsu_in_if.req_data.mask & is_addr_local_mask);

// Global 버퍼: Local이 아닌 레인만 마스크
.data_in ({
    lsu_in_if.req_data.mask & ~is_addr_local_mask,  // Global 레인만 활성화
    ...
})

// Local 버퍼: Local 레인만 마스크
.data_in ({
    lsu_in_if.req_data.mask & is_addr_local_mask,   // Local 레인만 활성화
    ...
})
```

**핵심 동작**:
- 하나의 요청이 들어오면 레인별 마스크를 분리
- Global 경로: `mask & ~is_addr_local_mask` (Global 레인만)
- Local 경로: `mask & is_addr_local_mask` (Local 레인만)
- **두 경로 모두 동시에 활성화 가능!**

### 증거 3: 준비 신호 조합

```systemverilog
assign lsu_in_if.req_ready = (req_global_ready && is_addr_global)
                          || (req_local_ready && is_addr_local);
```

- **OR 연산**: Global 또는 Local 중 하나만 준비되어도 ready
- 만약 둘 다 있으면? **둘 다 준비될 때까지 대기**
- 증명: 동시 접근 고려한 설계!

### 실제 시나리오 예시

```c
// OpenCL Kernel 예시
__kernel void mixed_access(__global int *g_data, __local int *l_data) {
    int gid = get_global_id(0);
    int lid = get_local_id(0);
    
    // 조건부 접근 - warp divergence 발생
    if (lid < 8) {
        int val = l_data[lid];        // Lane 0~7: Local memory
    } else {
        int val = g_data[gid];        // Lane 8~15: Global memory
    }
}
```

**Warp 실행**:
- Lane 0~7: Local memory 주소 → `flags[0~7][LOCAL] = 1`
- Lane 8~15: Global memory 주소 → `flags[8~15][LOCAL] = 0`
- **하나의 load 명령, 하나의 warp, 하지만 두 메모리 타입 동시 접근!**

---

## Bitwidth 변화 과정

LSU에서 메모리까지의 데이터 경로에서 bitwidth가 어떻게 변화하는지 정리한다.

### 주요 파라미터 정의

| 파라미터 | 정의 | 예시 (RV32, 4 lanes) |
|----------|------|----------------------|
| `XLEN` | 레지스터 폭 | 32 bits |
| `XLENB` | XLEN을 바이트로 | 4 bytes |
| `NUM_LSU_LANES` | LSU 레인 수 | 4 |
| `LSU_WORD_SIZE` | LSU 워드 크기 = XLENB | 4 bytes |
| `LSU_LINE_SIZE` | LSU 라인 크기 = MIN(LANES × XLENB, L1_LINE_SIZE) | 16 bytes |
| `DCACHE_WORD_SIZE` | D-Cache 워드 크기 = LSU_LINE_SIZE | 16 bytes |
| `DCACHE_CHANNELS` | D-Cache 채널 수 = (LANES × LSU_WORD_SIZE) / DCACHE_WORD_SIZE | 1 |

### Global Memory 경로

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           Global Memory Path                                        │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  Execute Stage                                                                      │
│       │                                                                             │
│       │  rs1_data, rs2_data: NUM_LSU_LANES × XLEN bits                             │
│       │  예: 4 lanes × 32 bits = 128 bits (데이터)                                  │
│       ▼                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ VX_lsu_slice                                                                │   │
│  │   Interface: VX_lsu_mem_if                                                  │   │
│  │   - mask:   NUM_LSU_LANES bits (4 bits)                                     │   │
│  │   - addr:   NUM_LSU_LANES × LSU_ADDR_WIDTH                                  │   │
│  │   - data:   NUM_LSU_LANES × LSU_WORD_SIZE × 8 = 4 × 4 × 8 = 128 bits       │   │
│  │   - byteen: NUM_LSU_LANES × LSU_WORD_SIZE = 4 × 4 = 16 bits                │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│       │                                                                             │
│       │  VX_lsu_mem_if (NUM_LANES=4, DATA_SIZE=LSU_WORD_SIZE=4)                    │
│       ▼                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ VX_lmem_switch                                                              │   │
│  │   Input:  lsu_in_if (4 lanes × 32-bit words)                                │   │
│  │   Output: global_out_if (동일, mask만 필터링)                                │   │
│  │                                                                             │   │
│  │   ※ Bitwidth 변화 없음, mask만 분리                                         │   │
│  │   REQ_DATAW = NUM_LSU_LANES + 1 + NUM_LSU_LANES × (LSU_WORD_SIZE +          │   │
│  │               LSU_ADDR_WIDTH + MEM_FLAGS_WIDTH + LSU_WORD_SIZE × 8)         │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│       │                                                                             │
│       │  VX_lsu_mem_if (NUM_LANES=4, DATA_SIZE=4)                                  │
│       ▼                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ VX_mem_coalescer (조건부: NUM_LSU_LANES > 1 && LSU_WORD_SIZE != DCACHE_WORD)│   │
│  │                                                                             │   │
│  │   Input:  NUM_REQS = NUM_LSU_LANES = 4                                      │   │
│  │           DATA_IN_SIZE = LSU_WORD_SIZE = 4 bytes                            │   │
│  │           → 4 lanes × 32 bits = 128 bits                                    │   │
│  │                                                                             │   │
│  │   Output: OUT_REQS = NUM_REQS / DATA_RATIO                                  │   │
│  │                    = 4 / (16/4) = 4 / 4 = 1                                 │   │
│  │           DATA_OUT_SIZE = DCACHE_WORD_SIZE = 16 bytes                       │   │
│  │           → 1 channel × 128 bits = 128 bits                                 │   │
│  │                                                                             │   │
│  │   ※ 레인 수 감소 (4 → 1), 워드 크기 증가 (4B → 16B)                         │   │
│  │   ※ 인접 주소 요청을 하나의 라인 요청으로 병합                               │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│       │                                                                             │
│       │  VX_lsu_mem_if (NUM_LANES=DCACHE_CHANNELS=1, DATA_SIZE=16)                 │
│       ▼                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ VX_lsu_adapter                                                              │   │
│  │                                                                             │   │
│  │   Input:  VX_lsu_mem_if (SIMD 스타일, 마스크 기반)                           │   │
│  │           NUM_LANES = DCACHE_CHANNELS = 1                                   │   │
│  │           DATA_SIZE = DCACHE_WORD_SIZE = 16 bytes                           │   │
│  │                                                                             │   │
│  │   Output: VX_mem_bus_if[DCACHE_CHANNELS] (개별 버스 스타일)                  │   │
│  │           각 채널: DATA_SIZE = 16 bytes = 128 bits                          │   │
│  │                                                                             │   │
│  │   ※ Bitwidth 변화 없음, 인터페이스 스타일만 변환                            │   │
│  │   ※ VX_stream_unpack으로 SIMD → 개별 요청 분리                              │   │
│  │   ※ VX_stream_pack으로 개별 응답 → SIMD 병합                                │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│       │                                                                             │
│       │  VX_mem_bus_if[DCACHE_CHANNELS] (DATA_SIZE=16)                             │
│       ▼                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ D-Cache                                                                     │   │
│  │                                                                             │   │
│  │   요청: DCACHE_CHANNELS × DCACHE_WORD_SIZE × 8                              │   │
│  │       = 1 × 16 × 8 = 128 bits                                               │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

**Global 경로 요약** (RV32, 4 lanes 예시):

| 단계 | 모듈 | Lanes/Channels | Word Size | Total Data Bits |
|------|------|----------------|-----------|-----------------|
| 1 | VX_lsu_slice | 4 | 4 bytes | 128 bits |
| 2 | VX_lmem_switch | 4 | 4 bytes | 128 bits |
| 3 | VX_mem_coalescer | 1 | 16 bytes | 128 bits |
| 4 | VX_lsu_adapter | 1 | 16 bytes | 128 bits |
| 5 | D-Cache | 1 | 16 bytes | 128 bits |

※ **총 bitwidth는 동일 (128 bits)**, 레인 수와 워드 크기가 트레이드오프

---

### Local Memory 경로

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           Local Memory Path                                         │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  Execute Stage                                                                      │
│       │                                                                             │
│       │  rs1_data, rs2_data: NUM_LSU_LANES × XLEN bits                             │
│       ▼                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ VX_lsu_slice                                                                │   │
│  │   Interface: VX_lsu_mem_if                                                  │   │
│  │   - data: NUM_LSU_LANES × LSU_WORD_SIZE × 8 = 4 × 4 × 8 = 128 bits         │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│       │                                                                             │
│       │  VX_lsu_mem_if (NUM_LANES=4, DATA_SIZE=4)                                  │
│       ▼                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ VX_lmem_switch                                                              │   │
│  │   Input:  lsu_in_if (4 lanes × 32-bit words)                                │   │
│  │   Output: local_out_if (동일, mask만 필터링)                                 │   │
│  │                                                                             │   │
│  │   ※ Bitwidth 변화 없음                                                      │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│       │                                                                             │
│       │  VX_lsu_mem_if (NUM_LANES=4, DATA_SIZE=4)                                  │
│       ▼                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ VX_lsu_mem_arb (NUM_LSU_BLOCKS > 1인 경우)                                  │   │
│  │                                                                             │   │
│  │   Input:  NUM_LSU_BLOCKS개의 VX_lsu_mem_if                                  │   │
│  │   Output: 1개의 VX_lsu_mem_if (Round-Robin 중재)                            │   │
│  │                                                                             │   │
│  │   ※ 여러 LSU 블록의 요청을 하나로 중재                                       │   │
│  │   ※ 한 번에 하나의 블록만 통과 → Bitwidth 동일                              │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│       │                                                                             │
│       │  VX_lsu_mem_if (NUM_LANES=4, DATA_SIZE=4)                                  │
│       ▼                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ VX_lsu_adapter (for Local Memory)                                           │   │
│  │                                                                             │   │
│  │   Input:  VX_lsu_mem_if (SIMD 스타일)                                        │   │
│  │           NUM_LANES = NUM_LSU_LANES = 4                                     │   │
│  │           DATA_SIZE = LSU_WORD_SIZE = 4 bytes                               │   │
│  │                                                                             │   │
│  │   Output: VX_mem_bus_if[NUM_LSU_LANES] (개별 버스)                          │   │
│  │           각 레인: DATA_SIZE = 4 bytes = 32 bits                            │   │
│  │                                                                             │   │
│  │   ※ SIMD 요청을 개별 메모리 포트 요청으로 분리                               │   │
│  │   ※ 총 Bitwidth 동일, 4개의 독립 포트로 분리                                │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│       │                                                                             │
│       │  VX_mem_bus_if[NUM_LSU_LANES] (각 DATA_SIZE=4)                             │
│       ▼                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ VX_local_mem                                                                │   │
│  │                                                                             │   │
│  │   NUM_REQS = NUM_LSU_LANES = 4                                              │   │
│  │   WORD_SIZE = LSU_WORD_SIZE = 4 bytes                                       │   │
│  │   NUM_BANKS = LMEM_NUM_BANKS (configurable)                                 │   │
│  │                                                                             │   │
│  │   요청: 4 ports × 32 bits = 128 bits (병렬 액세스)                          │   │
│  │                                                                             │   │
│  │   ※ 뱅크 충돌 시 직렬화됨                                                    │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

**Local 경로 요약** (RV32, 4 lanes 예시):

| 단계 | 모듈 | Lanes/Ports | Word Size | Total Data Bits |
|------|------|-------------|-----------|-----------------|
| 1 | VX_lsu_slice | 4 | 4 bytes | 128 bits |
| 2 | VX_lmem_switch | 4 | 4 bytes | 128 bits |
| 3 | VX_lsu_mem_arb | 4 | 4 bytes | 128 bits |
| 4 | VX_lsu_adapter | 4 × 1 | 4 bytes | 128 bits |
| 5 | VX_local_mem | 4 ports | 4 bytes | 128 bits |

※ **Local Memory는 Coalescing 없음** → 레인 수와 워드 크기 유지
※ 각 레인이 독립적인 메모리 포트로 변환되어 병렬 액세스

---

### Global vs Local 경로 비교

| 특성 | Global Memory | Local Memory |
|------|---------------|--------------|
| Coalescing | 있음 (4 lanes → 1 channel) | 없음 |
| Word Size | 작음 → 큼 (4B → 16B) | 유지 (4B) |
| 레이턴시 | 높음 (Cache miss 가능) | 낮음 (SRAM 직접 액세스) |
| 대역폭 | Cache line 기반 | 레인별 독립 포트 |
| 병목 | Memory coalescing 효율 | 뱅크 충돌 |

---

## 핵심 정리

### Local/Global 동시 접근
- ✅ **가능함**: 레인별 주소가 다르면 메모리 타입도 다를 수 있음
- ✅ **설계 의도**: `VX_lmem_switch`는 레인별 마스크 분리 로직 내장
- ✅ **SIMT 모델**: 모든 스레드가 같은 명령어 실행하지만, 레지스터 값(주소)은 다름
- ✅ **Divergence**: Warp divergence 시 일부는 local, 일부는 global 접근 가능

### 성능 영향
- 동시 접근 시 두 경로 모두 준비될 때까지 대기 → 레이턴시 증가
- Coalescing 효율 감소 (요청이 분산됨)
- 최적 성능: 모든 레인이 같은 메모리 타입 접근

---

## 읽기 포인트

### VX_lsu_unit.sv
- Dispatch/Gather 구조 (line 40~60)
- 블록별 병렬 처리 (line 43~56)

### VX_lsu_slice.sv
- 주소 타입 판별 (line 68~80) — **레인별 독립 판별**
- Fence 처리 (line 124~140)
- Multi-packet 추적 (line 220~270)
- TAG 구성 (line 281~294)
- 응답 포맷팅 (line 415~439) — 부분 읽기 확장

### VX_mem_unit.sv
- Local/Global 분기 (line 47~63)
- Local memory 경로 (line 65~125)
- Coalescing (line 153~216)
- D-Cache 어댑터 (line 226~245)

---

## 관련 파일

- `VX_lmem_switch.sv`: Local/Global 분기 스위치 (레인별 마스크 처리)
- `VX_mem_scheduler.sv`: 메모리 요청 스케줄링
- `VX_mem_coalescer.sv`: 요청 병합 (작은 요청 → 큰 요청)
- `VX_dispatch_unit.sv`, `VX_gather_unit.sv`: 명령어 분배/결과 병합

---

생성: `docs/rtl/core/LSU_hierarchy.md` (한글, LSU 계층 구조 및 local/global 동시 접근 분석)
