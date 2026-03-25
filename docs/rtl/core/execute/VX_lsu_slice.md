# `core/VX_lsu_slice.sv` — Load/Store Unit Slice

## 개요

Load/Store 연산을 처리하는 실행 유닛 슬라이스. 메모리 주소 계산, 데이터 정렬, 메모리 스케줄링, 응답 데이터 포맷팅을 담당한다. VX_lsu_unit에서 인스턴스화되며, 각 슬라이스는 독립적인 메모리 요청 파이프라인을 가진다.

## 아키텍처

```
                     ┌─────────────────────────────────────────────────────────────────┐
                     │                         VX_lsu_slice                            │
                     │                                                                 │
execute_if ─────────┼──→ ┌───────────────────┐                                        │
                     │    │   Address Calc    │                                        │
                     │    │  rs1 + offset     │                                        │
                     │    └────────┬──────────┘                                        │
                     │             │                                                   │
                     │    ┌────────▼──────────┐                                        │
                     │    │  Address Flags    │ (I/O, Local Memory 판별)               │
                     │    └────────┬──────────┘                                        │
                     │             │                                                   │
                     │    ┌────────▼──────────┐     ┌─────────────────┐               │
                     │    │  Byteen/Data Fmt  │     │   Fence Lock    │               │
                     │    │  (8/16/32/64-bit) │     │   (동기화 처리)  │               │
                     │    └────────┬──────────┘     └────────┬────────┘               │
                     │             │                         │                         │
                     │    ┌────────▼─────────────────────────▼────────┐               │
                     │    │              VX_mem_scheduler             │               │
                     │    │    (요청 스케줄링, 응답 재정렬)              │               │
                     │    └────────┬──────────────────────────────────┘               │
                     │             │                                                   │
                     │    ┌────────▼──────────┐                                        │
                     │    │ Load Response Fmt │ (부호/무부호 확장)                     │
                     │    └────────┬──────────┘                                        │
                     │             │                                                   │
                     │    ┌────────▼──────────────────────────────────┐               │
                     │    │           VX_stream_arb                   │               │
                     │    │   (rsp_buf ◀──── no_rsp_buf)              │               │
                     │    │   Load응답   ◀──── Store/Fence완료          │               │
                     │    └────────┬──────────────────────────────────┘               │
                     │             │                                                   │
                     └─────────────┼───────────────────────────────────────────────────┘
                                   │
                     ┌─────────────┴─────────────┐
                     ▼                           ▼
               result_if                    lsu_mem_if
           (→ Commit Stage)              (→ Memory Subsystem)
```

## 모듈 파라미터

| 파라미터 | 설명 |
|----------|------|
| `INSTANCE_ID` | 디버깅용 인스턴스 이름 |

## 주요 로컬 파라미터

| 파라미터 | 계산식 | 설명 |
|----------|--------|------|
| `NUM_LANES` | `NUM_LSU_LANES` | LSU 레인 수 (SIMD 폭) |
| `PID_BITS` | `CLOG2(NUM_THREADS / NUM_LANES)` | Packet ID 비트 수 |
| `LSUQ_SIZEW` | `LOG2UP(LSUQ_IN_SIZE)` | LSU 큐 주소 비트 |
| `REQ_ASHIFT` | `CLOG2(LSU_WORD_SIZE)` | 워드 내 바이트 정렬 시프트 |
| `MEM_ASHIFT` | `CLOG2(MEM_BLOCK_SIZE)` | 메모리 블록 주소 시프트 |
| `TAG_WIDTH` | `UUID_WIDTH + TAG_ID_WIDTH` | 메모리 태그 전체 폭 |

## 인터페이스

| 인터페이스 | 방향 | 설명 |
|-----------|------|------|
| `execute_if` | slave | 실행 요청 입력 (VX_execute_if) |
| `result_if` | master | 연산 결과 출력 (VX_result_if) |
| `lsu_mem_if` | master | 메모리 요청/응답 (VX_lsu_mem_if) |

---

## 핵심 동작 로직

### 1. 주소 계산 (Full Address Calculation)

```systemverilog
wire [NUM_LANES-1:0][`XLEN-1:0] full_addr;
for (genvar i = 0; i < NUM_LANES; ++i) begin : g_full_addr
    assign full_addr[i] = execute_if.data.rs1_data[i] + `SEXT(`XLEN, execute_if.data.op_args.lsu.offset);
end
```

각 레인별로 **rs1 (base address) + offset (immediate)** 를 계산하여 전체 메모리 주소를 생성한다.

### 2. 주소 타입 플래그 계산 (Address Type Flags)

```systemverilog
wire [MEM_ADDRW-1:0] block_addr = full_addr[i][MEM_ASHIFT +: MEM_ADDRW];

// I/O 영역 판별
wire [MEM_ADDRW-1:0] io_addr_start = MEM_ADDRW'(`XLEN'(`IO_BASE_ADDR) >> MEM_ASHIFT);
wire [MEM_ADDRW-1:0] io_addr_end = MEM_ADDRW'(`XLEN'(`IO_END_ADDR) >> MEM_ASHIFT);
assign mem_req_flags[i][MEM_REQ_FLAG_IO] = (block_addr >= io_addr_start) && (block_addr < io_addr_end);

// Local Memory 영역 판별 (LMEM_ENABLE 시)
assign mem_req_flags[i][MEM_REQ_FLAG_LOCAL] = (block_addr >= lmem_addr_start) && (block_addr < lmem_addr_end);
```

| 플래그 | 설명 |
|--------|------|
| `MEM_REQ_FLAG_FLUSH` | Fence 명령어 |
| `MEM_REQ_FLAG_IO` | I/O 주소 영역 |
| `MEM_REQ_FLAG_LOCAL` | Local Memory 주소 (Scratchpad) |

### 3. Byte Enable 생성 (Byteen Formatting)

액세스 크기에 따라 바이트 인에이블 마스크를 생성:

```systemverilog
case (inst_lsu_wsize(execute_if.data.op_type))
    0: begin // 8-bit (LB/SB)
        mem_req_byteen_w[req_align[i]] = 1'b1;
    end
    1: begin // 16-bit (LH/SH)
        mem_req_byteen_w[{req_align[i][REQ_ASHIFT-1:1], 1'b0}] = 1'b1;
        mem_req_byteen_w[{req_align[i][REQ_ASHIFT-1:1], 1'b1}] = 1'b1;
    end
    2: begin // 32-bit (LW/SW) - XLEN_64에서만
        mem_req_byteen_w[...] = 1'b1; // 4바이트
    end
    default: mem_req_byteen_w = {LSU_WORD_SIZE{1'b1}}; // 64-bit (LD/SD)
endcase
```

### 4. Store 데이터 정렬 (Store Data Formatting)

Store 데이터를 정렬된 위치로 시프트:

```systemverilog
always @(*) begin
    mem_req_data[i] = execute_if.data.rs2_data[i];
    case (req_align[i])
        1: mem_req_data[i][`XLEN-1:8]  = execute_if.data.rs2_data[i][`XLEN-9:0];
        2: mem_req_data[i][`XLEN-1:16] = execute_if.data.rs2_data[i][`XLEN-17:0];
        3: mem_req_data[i][`XLEN-1:24] = execute_if.data.rs2_data[i][`XLEN-25:0];
        // ... RV64에서는 4~7도 처리
        default:;
    endcase
end
```

### 5. Fence 처리 (Fence Handling)

Fence 명령어는 이전 메모리 연산이 완료될 때까지 후속 연산을 블로킹:

```systemverilog
reg fence_lock;

always @(posedge clk) begin
    if (reset) begin
        fence_lock <= 0;
    end else begin
        // Fence 요청 발행 시 lock 설정
        if (mem_req_fire && req_is_fence && execute_if.data.eop) begin
            fence_lock <= 1;
        end
        // Fence 응답 완료 시 lock 해제
        if (mem_rsp_fire && rsp_is_fence && mem_rsp_eop_pkt) begin
            fence_lock <= 0;
        end
    end
end

// Fence lock 동안 새 요청 블로킹
assign mem_req_valid = execute_if.valid && ~req_skip && ... && ~fence_lock;
```

### 6. 다중 패킷 응답 추적 (Multi-Packet Response Tracking)

`NUM_THREADS > NUM_LANES`인 경우, 하나의 명령어가 여러 패킷으로 분할된다. 응답이 순서대로 오지 않을 수 있으므로 SOP/EOP를 추적:

```systemverilog
if (PID_BITS != 0) begin : g_pid
    reg [`LSUQ_IN_SIZE-1:0][PID_BITS:0] pkt_ctr;  // 패킷 카운터
    reg [`LSUQ_IN_SIZE-1:0] pkt_sop, pkt_eop;      // SOP/EOP 플래그

    VX_allocator #(
        .SIZE (`LSUQ_IN_SIZE)
    ) pkt_allocator (
        .acquire_en  (mem_req_rd_eop_fire),  // Load 요청의 EOP에서 할당
        .acquire_addr(pkt_waddr),
        .release_en  (mem_rsp_eop_pkt_fire), // 응답의 EOP에서 해제
        .release_addr(pkt_raddr),
        ...
    );

    // SOP/EOP 패킷 플래그 계산
    assign mem_rsp_sop_pkt = pkt_sop[pkt_raddr];
    assign mem_rsp_eop_pkt = mem_rsp_eop && pkt_eop[pkt_raddr] && (pkt_ctr[pkt_raddr] == 1);
end
```

### 7. Load 응답 데이터 포맷팅 (Load Response Formatting)

메모리에서 읽은 데이터를 정렬하고 부호/무부호 확장:

```systemverilog
wire [15:0] rsp_data16 = rsp_align[i][1] ? rsp_data32[31:16] : rsp_data32[15:0];
wire [7:0]  rsp_data8  = rsp_align[i][0] ? rsp_data16[15:8] : rsp_data16[7:0];

always @(*) begin
    case (inst_lsu_fmt(rsp_op_type))
        LSU_FMT_B:  rsp_data[i] = `XLEN'(signed'(rsp_data8));    // LB
        LSU_FMT_H:  rsp_data[i] = `XLEN'(signed'(rsp_data16));   // LH
        LSU_FMT_BU: rsp_data[i] = `XLEN'(unsigned'(rsp_data8));  // LBU
        LSU_FMT_HU: rsp_data[i] = `XLEN'(unsigned'(rsp_data16)); // LHU
        LSU_FMT_W:  rsp_data[i] = `XLEN'(signed'(rsp_data32));   // LW
        // RV64에서는 LWU, LD도 처리
        default: rsp_data[i] = 'x;
    endcase
end
```

### 8. NaN-Boxing (FP Load)

RV64에서 FLW (32비트 FP Load)시 상위 32비트를 1로 채움:

```systemverilog
`ifdef XLEN_64
`ifdef EXT_F_ENABLE
    wire rsp_is_float = rsp_rd[5];  // rd[5]=1이면 FP 레지스터
    LSU_FMT_W: rsp_data[i] = rsp_is_float ?
        (`XLEN'(rsp_data32) | 64'hffffffff00000000) :  // NaN-boxing
        `XLEN'(signed'(rsp_data32));
`endif
`endif
```

---

## 메모리 요청 태그 (Tag) 구조

태그에는 응답 처리에 필요한 모든 정보가 패킹됨:

```systemverilog
assign mem_req_tag = {
    execute_if.data.uuid,     // 디버그용 고유 ID
    execute_if.data.wid,      // Warp ID
    execute_if.data.PC,       // Program Counter
    execute_if.data.wb,       // Write-back 필요 여부
    execute_if.data.rd,       // 목적지 레지스터
    execute_if.data.op_type,  // Load/Store 타입
    req_align,                // 바이트 정렬 오프셋
    execute_if.data.pid,      // Packet ID
    pkt_waddr,                // 패킷 큐 주소
    req_is_fence              // Fence 여부
};
```

---

## 응답 경로 분리

Store 요청과 Load 요청의 응답 경로가 다름:

```systemverilog
// Store/Fence: 응답 불필요 (no_rsp_buf)
wire no_rsp_buf_enable = (mem_req_rw && ~execute_if.data.wb) || req_skip;

// Load: 메모리 응답 필요 (rsp_buf)
VX_elastic_buffer #(...) rsp_buf (
    .valid_in  (mem_rsp_valid),
    .data_in   ({rsp_uuid, rsp_wid, mem_rsp_mask, rsp_pc, rsp_wb, rsp_rd, rsp_data, ...}),
    ...
);

VX_elastic_buffer #(...) no_rsp_buf (
    .valid_in  (no_rsp_buf_valid),
    .data_in   ({execute_if.data.uuid, execute_if.data.wid, ...}),
    ...
);

// 두 경로를 우선순위 아비터로 병합 (Load 응답 우선)
VX_stream_arb #(
    .NUM_INPUTS (2),
    .ARBITER    ("P")  // Priority: result_rsp_if 우선
) rsp_arb (...);
```

---

## 사용 서브모듈

| 모듈 | 용도 |
|------|------|
| `VX_mem_scheduler` | 메모리 요청 스케줄링 및 응답 재정렬 |
| `VX_allocator` | 다중 패킷 추적을 위한 큐 주소 할당 |
| `VX_elastic_buffer` | 응답 버퍼링 (rsp_buf, no_rsp_buf) |
| `VX_stream_arb` | Load/Store 응답 경로 병합 |

### VX_mem_scheduler 인스턴스

```systemverilog
VX_mem_scheduler #(
    .INSTANCE_ID (`SFORMATF(("%s-memsched", INSTANCE_ID))),
    .CORE_REQS   (NUM_LANES),        // 레인 수만큼 동시 요청
    .MEM_CHANNELS(NUM_LANES),        // 메모리 채널 수
    .WORD_SIZE   (LSU_WORD_SIZE),    // 워드 크기
    .LINE_SIZE   (LSU_WORD_SIZE),    // 라인 크기
    .ADDR_WIDTH  (LSU_ADDR_WIDTH),   // 주소 폭
    .FLAGS_WIDTH (MEM_FLAGS_WIDTH),  // 플래그 폭
    .TAG_WIDTH   (TAG_WIDTH),        // 태그 폭
    .CORE_QUEUE_SIZE (`LSUQ_IN_SIZE),  // 입력 큐 크기
    .MEM_QUEUE_SIZE (`LSUQ_OUT_SIZE),  // 출력 큐 크기
    .UUID_WIDTH  (UUID_WIDTH),
    .RSP_PARTIAL (1),                // 부분 응답 지원
    .MEM_OUT_BUF (0),
    .CORE_OUT_BUF(0)
) mem_scheduler (...);
```

---

## 데이터 흐름

```
execute_if.data
     │
     ├── rs1_data[NUM_LANES] ──→ full_addr 계산 (+ offset)
     │                                │
     │                                ├──→ mem_req_addr (주소)
     │                                └──→ mem_req_flags (I/O, Local)
     │
     ├── rs2_data[NUM_LANES] ──→ mem_req_data (Store 데이터 정렬)
     │
     ├── op_type ──→ inst_lsu_wsize() ──→ mem_req_byteen
     │           └──→ inst_lsu_is_fence() ──→ fence_lock
     │
     ├── op_args.lsu.is_store ──→ mem_req_rw
     │
     └── tmask ──→ mem_req_mask

     ┌──────────────────────┐
     │   VX_mem_scheduler   │
     │                      │
     │  core_req ──→ mem_req │──→ lsu_mem_if.req
     │  core_rsp ←── mem_rsp │←── lsu_mem_if.rsp
     └──────────────────────┘
                │
                ▼
     ┌──────────────────────┐
     │  Load Response Fmt   │
     │  - 정렬 추출          │
     │  - 부호/무부호 확장   │
     │  - NaN-boxing        │
     └──────────────────────┘
                │
                ▼
         result_if.data
```

---

## 메모리 정렬 검증

Misaligned 메모리 액세스는 지원되지 않음:

```systemverilog
for (genvar i = 0; i < NUM_LANES; ++i) begin : g_missalign
    wire lsu_req_fire = execute_if.valid && execute_if.ready;
    `RUNTIME_ASSERT(
        (~lsu_req_fire || ~execute_if.data.tmask[i] || req_is_fence ||
         (full_addr[i] % (1 << inst_lsu_wsize(execute_if.data.op_type))) == 0),
        ("%t: misaligned memory access, wid=%0d, PC=0x%0h, addr=0x%0h, wsize=%0d!",
            $time, execute_if.data.wid, to_fullPC(execute_if.data.PC),
            full_addr[i], inst_lsu_wsize(execute_if.data.op_type))
    )
end
```

---

## 지원 명령어

### Load 명령어

| 명령어 | LSU_FMT | 설명 |
|--------|---------|------|
| LB | LSU_FMT_B | 8비트 부호 확장 로드 |
| LH | LSU_FMT_H | 16비트 부호 확장 로드 |
| LW | LSU_FMT_W | 32비트 로드 |
| LBU | LSU_FMT_BU | 8비트 무부호 로드 |
| LHU | LSU_FMT_HU | 16비트 무부호 로드 |
| LD | LSU_FMT_D | 64비트 로드 (RV64) |
| LWU | LSU_FMT_WU | 32비트 무부호 로드 (RV64) |
| FLW | LSU_FMT_W | 32비트 FP 로드 (NaN-boxing) |
| FLD | LSU_FMT_D | 64비트 FP 로드 |

### Store 명령어

| 명령어 | wsize | 설명 |
|--------|-------|------|
| SB | 0 | 8비트 스토어 |
| SH | 1 | 16비트 스토어 |
| SW | 2 | 32비트 스토어 |
| SD | 3 | 64비트 스토어 (RV64) |
| FSW | 2 | 32비트 FP 스토어 |
| FSD | 3 | 64비트 FP 스토어 |

### Fence 명령어

| 명령어 | 설명 |
|--------|------|
| FENCE | 메모리 순서 보장 |

---

## 관련 파일

- [VX_lsu_unit.sv](../../../../hw/rtl/core/VX_lsu_unit.sv) - 상위 모듈
- [VX_mem_scheduler.sv](../../../../hw/rtl/libs/VX_mem_scheduler.sv) - 메모리 스케줄러
- [VX_lsu_mem_if.sv](../../../../hw/rtl/interfaces/VX_lsu_mem_if.sv) - 메모리 인터페이스
- [VX_execute_if.sv](../../../../hw/rtl/interfaces/VX_execute_if.sv) - 실행 입력 인터페이스
- [VX_result_if.sv](../../../../hw/rtl/interfaces/VX_result_if.sv) - 결과 출력 인터페이스

---

## 성능 특성

- **레이턴시**: 가변 (메모리 응답 시간에 의존)
- **스루풋**: 사이클당 최대 1 명령어 (메모리 병목 시 감소)
- **병렬도**: NUM_LANES개 스레드 동시 메모리 액세스
- **Fence 오버헤드**: 모든 이전 요청 완료까지 블로킹

## 디버그 지원

`DBG_TRACE_MEM` 정의 시 상세 트레이스 출력:

```systemverilog
`ifdef DBG_TRACE_MEM
    always @(posedge clk) begin
        if (mem_req_fire) begin
            if (mem_req_rw) begin
                `TRACE(2, ("%t: %s Wr Req: wid=%0d, PC=0x%0h, tmask=%b, addr=...", ...))
            end else begin
                `TRACE(2, ("%t: %s Rd Req: wid=%0d, PC=0x%0h, tmask=%b, addr=...", ...))
            end
        end
        if (mem_rsp_fire) begin
            `TRACE(2, ("%t: %s Rsp: wid=%0d, PC=0x%0h, tmask=%b, rd=%0d, data=...", ...))
        end
    end
`endif
```
