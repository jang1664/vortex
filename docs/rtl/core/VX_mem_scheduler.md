# `libs/VX_mem_scheduler.sv` — Memory Request Scheduler

## 개요

코어의 메모리 요청을 스케줄링하고, 메모리 응답을 재정렬하여 원래 요청 순서로 반환하는 모듈. 메모리 coalescing, 배치 처리, 태그 관리를 통해 효율적인 메모리 액세스를 지원한다.

## 아키텍처

```
                          ┌───────────────────────────────────────────────────────────────┐
                          │                      VX_mem_scheduler                         │
                          │                                                               │
core_req ────────────────┼──→ ┌──────────────────┐                                       │
                          │    │   req_queue      │                                       │
                          │    │ (VX_elastic_buf) │                                       │
                          │    └────────┬─────────┘                                       │
                          │             │                                                 │
                          │    ┌────────▼─────────┐     ┌──────────────────┐             │
                          │    │  VX_index_buffer │     │  req_ibuf        │             │
                          │    │  (태그 저장/복원) │     │  (TAG_ID 보관)   │             │
                          │    └────────┬─────────┘     └──────────────────┘             │
                          │             │                                                 │
                          │    ┌────────▼─────────┐  (COALESCE_ENABLE)                   │
                          │    │ VX_mem_coalescer │◄─── LINE_SIZE != WORD_SIZE           │
                          │    │ (메모리 병합)     │                                       │
                          │    └────────┬─────────┘                                       │
                          │             │                                                 │
                          │    ┌────────▼─────────┐  (MEM_BATCHES > 1)                   │
                          │    │  Batch Splitter  │◄─── MERGED_REQS > MEM_CHANNELS       │
                          │    │ (요청 분할)       │                                       │
                          │    └────────┬─────────┘                                       │
                          │             │                                                 │
                          │    ┌────────▼─────────┐                                       │
                          │    │   mem_req_buf    │                                       │
                          │    │ (VX_elastic_buf) │                                       │
                          │    └────────┬─────────┘                                       │
                          │             │                                                 │
                          └─────────────┼─────────────────────────────────────────────────┘
                                        │
                          ┌─────────────┴─────────────┐
                          ▼                           ▼
                    mem_req                       core_rsp
                 (→ Memory)                    (← Response)
```

## 모듈 파라미터

| 파라미터 | 기본값 | 설명 |
|----------|--------|------|
| `INSTANCE_ID` | "" | 디버깅용 인스턴스 이름 |
| `CORE_REQS` | 1 | 코어 요청 수 (레인 수) |
| `MEM_CHANNELS` | 1 | 메모리 채널 수 |
| `WORD_SIZE` | 4 | 워드 크기 (바이트) |
| `LINE_SIZE` | WORD_SIZE | 캐시 라인 크기 |
| `ADDR_WIDTH` | 32 - log2(WORD_SIZE) | 주소 폭 |
| `FLAGS_WIDTH` | 0 | 플래그 비트 수 |
| `TAG_WIDTH` | 8 | 태그 폭 |
| `UUID_WIDTH` | 0 | UUID 폭 (디버깅용) |
| `CORE_QUEUE_SIZE` | 8 | 코어 요청 큐 크기 |
| `MEM_QUEUE_SIZE` | CORE_QUEUE_SIZE | 메모리 큐 크기 |
| `RSP_PARTIAL` | 0 | 부분 응답 허용 여부 |
| `CORE_OUT_BUF` | 0 | 코어 출력 버퍼 설정 |
| `MEM_OUT_BUF` | 0 | 메모리 출력 버퍼 설정 |

## 파생 파라미터

| 파라미터 | 계산식 | 설명 |
|----------|--------|------|
| `WORD_WIDTH` | WORD_SIZE * 8 | 워드 비트 폭 |
| `LINE_WIDTH` | LINE_SIZE * 8 | 라인 비트 폭 |
| `COALESCE_ENABLE` | (CORE_REQS > 1) && (LINE_SIZE != WORD_SIZE) | Coalescing 활성화 |
| `PER_LINE_REQS` | LINE_SIZE / WORD_SIZE | 라인당 요청 수 |
| `MERGED_REQS` | CORE_REQS / PER_LINE_REQS | 병합 후 요청 수 |
| `MEM_BATCHES` | CDIV(MERGED_REQS, MEM_CHANNELS) | 배치 수 |
| `MEM_ADDR_WIDTH` | ADDR_WIDTH - log2(PER_LINE_REQS) | 메모리 주소 폭 |
| `MEM_TAG_WIDTH` | UUID_WIDTH + MEM_QUEUE_ADDRW + MEM_BATCH_BITS | 메모리 태그 폭 |

## 인터페이스

### Core Request Interface

| 신호 | 방향 | 폭 | 설명 |
|------|------|-----|------|
| `core_req_valid` | input | 1 | 요청 유효 |
| `core_req_rw` | input | 1 | Read/Write (1=Write) |
| `core_req_mask` | input | CORE_REQS | 레인 마스크 |
| `core_req_byteen` | input | CORE_REQS × WORD_SIZE | 바이트 인에이블 |
| `core_req_addr` | input | CORE_REQS × ADDR_WIDTH | 주소 |
| `core_req_flags` | input | CORE_REQS × FLAGS_WIDTH | 플래그 |
| `core_req_data` | input | CORE_REQS × WORD_WIDTH | 쓰기 데이터 |
| `core_req_tag` | input | TAG_WIDTH | 태그 |
| `core_req_ready` | output | 1 | 수신 준비 |

### Core Response Interface

| 신호 | 방향 | 폭 | 설명 |
|------|------|-----|------|
| `core_rsp_valid` | output | 1 | 응답 유효 |
| `core_rsp_mask` | output | CORE_REQS | 레인 마스크 |
| `core_rsp_data` | output | CORE_REQS × WORD_WIDTH | 읽기 데이터 |
| `core_rsp_tag` | output | TAG_WIDTH | 태그 |
| `core_rsp_sop` | output | 1 | Start of Packet |
| `core_rsp_eop` | output | 1 | End of Packet |
| `core_rsp_ready` | input | 1 | 수신 준비 |

### Memory Request Interface

| 신호 | 방향 | 폭 | 설명 |
|------|------|-----|------|
| `mem_req_valid` | output | 1 | 요청 유효 |
| `mem_req_rw` | output | 1 | Read/Write |
| `mem_req_mask` | output | MEM_CHANNELS | 채널 마스크 |
| `mem_req_byteen` | output | MEM_CHANNELS × LINE_SIZE | 바이트 인에이블 |
| `mem_req_addr` | output | MEM_CHANNELS × MEM_ADDR_WIDTH | 주소 |
| `mem_req_flags` | output | MEM_CHANNELS × FLAGS_WIDTH | 플래그 |
| `mem_req_data` | output | MEM_CHANNELS × LINE_WIDTH | 쓰기 데이터 |
| `mem_req_tag` | output | MEM_TAG_WIDTH | 태그 |
| `mem_req_ready` | input | 1 | 수신 준비 |

### Memory Response Interface

| 신호 | 방향 | 폭 | 설명 |
|------|------|-----|------|
| `mem_rsp_valid` | input | 1 | 응답 유효 |
| `mem_rsp_mask` | input | MEM_CHANNELS | 채널 마스크 |
| `mem_rsp_data` | input | MEM_CHANNELS × LINE_WIDTH | 읽기 데이터 |
| `mem_rsp_tag` | input | MEM_TAG_WIDTH | 태그 |
| `mem_rsp_ready` | output | 1 | 수신 준비 |

### Queue Status

| 신호 | 방향 | 설명 |
|------|------|------|
| `req_queue_empty` | output | 요청 큐가 비어있음 |
| `req_queue_rw_notify` | output | Write 요청 완료 알림 |

---

## 핵심 동작 로직

### 1. 요청 큐 (Request Queue)

코어 요청을 버퍼링하고 순서대로 처리:

```systemverilog
VX_elastic_buffer #(
    .DATAW   (1 + CORE_REQS * (1 + WORD_SIZE + ADDR_WIDTH + FLAGS_WIDTH + WORD_WIDTH) + REQQ_TAG_WIDTH),
    .SIZE    (CORE_QUEUE_SIZE),
    .OUT_REG (1)
) req_queue (
    .clk      (clk),
    .reset    (reset),
    .valid_in (reqq_valid_in),
    .data_in  ({core_req_rw, core_req_mask, core_req_byteen, core_req_addr, core_req_flags, core_req_data, reqq_tag_u}),
    .data_out ({reqq_rw, reqq_mask, reqq_byteen, reqq_addr, reqq_flags, reqq_data, reqq_tag}),
    ...
);

// Write 요청은 ibuf 불필요 (응답 없음)
wire ibuf_ready = (core_req_rw || ~ibuf_full);
wire reqq_valid_in = core_req_valid && ibuf_ready;
assign core_req_ready = reqq_ready_in && ibuf_ready;
```

### 2. 인덱스 버퍼 (Index Buffer)

Load 요청의 원본 태그를 저장하고, 응답 시 복원:

```systemverilog
VX_index_buffer #(
    .DATAW (TAG_ID_WIDTH),
    .SIZE  (CORE_QUEUE_SIZE)
) req_ibuf (
    .clk          (clk),
    .reset        (reset),
    .acquire_en   (ibuf_push),      // Load 요청 시 태그 저장
    .write_addr   (ibuf_waddr),     // 저장 위치 (자동 할당)
    .write_data   (ibuf_din),       // 원본 TAG_ID
    .read_data    (ibuf_dout),      // 복원된 TAG_ID
    .read_addr    (ibuf_raddr),     // 응답의 큐 주소
    .release_en   (ibuf_pop),       // 응답 완료 시 해제
    .full         (ibuf_full),
    .empty        (ibuf_empty)
);

// Load 요청 시에만 ibuf 사용
assign ibuf_push = core_req_fire && ~core_req_rw;
assign ibuf_pop  = crsp_fire && crsp_eop;
assign ibuf_din  = core_req_tag[TAG_ID_WIDTH-1:0];
```

### 3. 메모리 Coalescing (선택적)

`COALESCE_ENABLE = (CORE_REQS > 1) && (LINE_SIZE != WORD_SIZE)` 일 때 활성화.
인접 메모리 액세스를 하나의 라인 요청으로 병합:

```systemverilog
if (COALESCE_ENABLE) begin : g_coalescer
    VX_mem_coalescer #(
        .NUM_REQS       (CORE_REQS),
        .DATA_IN_SIZE   (WORD_SIZE),      // 입력: 워드 단위
        .DATA_OUT_SIZE  (LINE_SIZE),      // 출력: 라인 단위
        .ADDR_WIDTH     (ADDR_WIDTH),
        .TAG_WIDTH      (REQQ_TAG_WIDTH),
        .QUEUE_SIZE     (MEM_QUEUE_SIZE)
    ) coalescer (
        // CORE_REQS개의 워드 요청 → MERGED_REQS개의 라인 요청
        .in_req_valid   (reqq_valid),
        .in_req_mask    (reqq_mask),
        ...
        .out_req_valid  (reqq_valid_s),
        .out_req_mask   (reqq_mask_s),
        ...
    );
end else begin : g_no_coalescer
    // Coalescing 비활성화 시 패스스루
    assign reqq_valid_s = reqq_valid;
    assign reqq_mask_s  = reqq_mask;
    ...
end
```

**Coalescing 예시** (CORE_REQS=4, WORD_SIZE=4, LINE_SIZE=16):
```
Lane 0: addr=0x100 → ┐
Lane 1: addr=0x104 → ├── Line Request: addr=0x100 (16 bytes)
Lane 2: addr=0x108 → │
Lane 3: addr=0x10C → ┘

MERGED_REQS = 4 / (16/4) = 1
```

### 4. 배치 처리 (Batch Processing)

`MERGED_REQS > MEM_CHANNELS`일 때 요청을 여러 배치로 분할:

```systemverilog
// 배치별 데이터 준비
for (genvar i = 0; i < MEM_BATCHES; ++i) begin : g_mem_req_data_b
    for (genvar j = 0; j < MEM_CHANNELS; ++j) begin : g_j
        localparam r = i * MEM_CHANNELS + j;
        if (r < MERGED_REQS) begin : g_valid
            assign mem_req_mask_b[i][j]   = reqq_mask_s[r];
            assign mem_req_addr_b[i][j]   = reqq_addr_s[r];
            ...
        end else begin : g_padding
            assign mem_req_mask_b[i][j] = 0;  // 패딩
        end
    end
end

// 배치 인덱스 순회
if (MEM_BATCHES != 1) begin : g_batch
    reg [MEM_BATCH_BITS-1:0] req_batch_idx_r;

    always @(posedge clk) begin
        if (reset) begin
            req_batch_idx_r <= '0;
        end else begin
            if (reqq_valid_s && mem_req_ready_b) begin
                if (req_sent_all) begin
                    req_batch_idx_r <= '0;  // 모든 배치 완료
                end else begin
                    req_batch_idx_r <= req_batch_idx_r + 1;  // 다음 배치
                end
            end
        end
    end

    // 마지막 유효 배치 찾기
    VX_find_first #(
        .N       (MEM_BATCHES),
        .REVERSE (1)
    ) find_last (
        .valid_in  (req_batch_valids),
        .data_out  (req_batch_idx_last),
        ...
    );

    assign req_sent_all = mem_req_ready_b && (req_batch_idx_r == req_batch_idx_last);
end
```

**배치 예시** (MERGED_REQS=8, MEM_CHANNELS=2):
```
Batch 0: req[0], req[1] → MEM_CHANNELS
Batch 1: req[2], req[3]
Batch 2: req[4], req[5]
Batch 3: req[6], req[7]

MEM_BATCHES = ceil(8/2) = 4
```

### 5. 응답 재조립 (Response Reassembly)

응답이 순서대로 오지 않을 수 있으므로 마스크를 사용해 추적:

```systemverilog
reg [CORE_QUEUE_SIZE-1:0][CORE_REQS-1:0] rsp_rem_mask;  // 남은 응답 마스크
wire [CORE_REQS-1:0] curr_mask;  // 현재 응답의 레인 마스크

// 현재 응답이 어떤 레인에 해당하는지 계산
for (genvar r = 0; r < CORE_REQS; ++r) begin : g_curr_mask
    localparam i = r / CORE_CHANNELS;
    localparam j = r % CORE_CHANNELS;
    assign curr_mask[r] = (BATCH_SEL_WIDTH'(i) == rsp_batch_idx) && mem_rsp_mask_s[j];
end

// 남은 마스크 업데이트
assign rsp_rem_mask_n = rsp_rem_mask[ibuf_raddr] & ~curr_mask;

always @(posedge clk) begin
    if (ibuf_push) begin
        rsp_rem_mask[ibuf_waddr] <= core_req_mask;  // 초기 마스크 저장
    end
    if (mem_rsp_fire_s) begin
        rsp_rem_mask[ibuf_raddr] <= rsp_rem_mask_n;  // 응답된 부분 제거
    end
end

// 모든 레인 응답 완료 확인
wire rsp_complete = ~(| rsp_rem_mask_n);
```

### 6. 부분 응답 모드 (RSP_PARTIAL)

`RSP_PARTIAL = 1`: 응답이 올 때마다 즉시 코어로 전달 (SOP/EOP로 구분)
`RSP_PARTIAL = 0`: 모든 레인 응답이 모일 때까지 저장 후 한번에 전달

```systemverilog
if (RSP_PARTIAL != 0) begin : g_rsp_partial
    // 부분 응답 즉시 전달
    assign crsp_valid = mem_rsp_valid_s;
    assign crsp_mask  = curr_mask;
    assign crsp_sop   = rsp_sop_r[ibuf_raddr];  // 첫 응답
    assign crsp_eop   = rsp_complete;            // 마지막 응답
    assign mem_rsp_ready_s = crsp_ready;

end else begin : g_rsp_full
    // 전체 응답 조립 후 전달
    // 각 레인의 응답 데이터를 저장
    for (genvar i = 0; i < CORE_CHANNELS; ++i) begin : g_rsp_store
        for (genvar j = 0; j < CORE_BATCHES; ++j) begin : g_j
            reg [WORD_WIDTH-1:0] rsp_store [0:CORE_QUEUE_SIZE-1];
            always @(posedge clk) begin
                if (rsp_wren) begin
                    rsp_store[ibuf_raddr] <= mem_rsp_data_s[i];
                end
            end
        end
    end

    assign crsp_valid = mem_rsp_valid_s && rsp_complete;  // 완료 시에만 유효
    assign crsp_mask  = rsp_orig_mask[ibuf_raddr];        // 원래 마스크 복원
    assign crsp_sop   = 1'b1;
    assign crsp_eop   = 1'b1;
    assign mem_rsp_ready_s = crsp_ready || ~rsp_complete;  // 저장 중에도 수신
end
```

---

## 태그 관리

### 요청 태그 구조

```
core_req_tag:
┌─────────────┬─────────────────────┐
│  UUID       │     TAG_ID          │
│ (디버깅)    │ (wid, PC, rd, ...)  │
└─────────────┴─────────────────────┘
       ↓
       ▼
mem_req_tag:
┌─────────────┬─────────────────┬─────────────────┐
│  UUID       │  QUEUE_ADDR     │   BATCH_IDX     │
│             │  (ibuf 주소)    │   (배치 번호)   │
└─────────────┴─────────────────┴─────────────────┘
```

### 태그 변환 흐름

```
1. 요청 시:
   - TAG_ID (원본 태그) → ibuf에 저장
   - ibuf_waddr (큐 주소) → mem_req_tag에 포함

2. 응답 시:
   - mem_rsp_tag에서 ibuf_raddr 추출
   - ibuf_dout에서 원본 TAG_ID 복원
   - core_rsp_tag = {UUID, TAG_ID}
```

---

## 사용 서브모듈

| 모듈 | 용도 |
|------|------|
| `VX_elastic_buffer` | 요청/응답 큐 버퍼링 |
| `VX_index_buffer` | 태그 저장/복원 |
| `VX_mem_coalescer` | 메모리 요청 병합 (선택적) |
| `VX_find_first` | 마지막 유효 배치 탐색 |

---

## 데이터 흐름

```
core_req                                           core_rsp
    │                                                  ▲
    ▼                                                  │
┌─────────┐   ┌─────────┐   ┌───────────┐   ┌─────────┐
│req_queue│──►│coalescer│──►│batch_split│──►│mem_req_ │──► mem_req
│         │   │(optional)│   │           │   │buf      │
└─────────┘   └─────────┘   └───────────┘   └─────────┘
    │                                              │
    │         ┌─────────┐                          │
    └────────►│req_ibuf │◄─────────────────────────┘
              │TAG 저장 │              (ibuf_raddr 추출)
              └─────────┘
                   │
                   ▼
              ┌─────────┐   ┌───────────┐   ┌─────────┐
mem_rsp ────►│coalescer│──►│rsp_assem  │──►│rsp_buf  │──► core_rsp
              │(optional)│   │(재조립)   │   │         │
              └─────────┘   └───────────┘   └─────────┘
```

---

## 설정 조합 예시

### Case 1: 단순 설정 (No Coalescing, No Batching)

```
CORE_REQS = 4, MEM_CHANNELS = 4, WORD_SIZE = 4, LINE_SIZE = 4

COALESCE_ENABLE = (4 > 1) && (4 != 4) = false
MERGED_REQS = 4
MEM_BATCHES = ceil(4/4) = 1

→ 코어 요청이 그대로 메모리로 전달
```

### Case 2: Coalescing 활성화

```
CORE_REQS = 4, MEM_CHANNELS = 1, WORD_SIZE = 4, LINE_SIZE = 16

COALESCE_ENABLE = (4 > 1) && (16 != 4) = true
PER_LINE_REQS = 16/4 = 4
MERGED_REQS = 4/4 = 1

→ 4개 워드 요청이 1개 라인 요청으로 병합
```

### Case 3: Coalescing + Batching

```
CORE_REQS = 8, MEM_CHANNELS = 2, WORD_SIZE = 4, LINE_SIZE = 8

COALESCE_ENABLE = true
PER_LINE_REQS = 8/4 = 2
MERGED_REQS = 8/2 = 4
MEM_BATCHES = ceil(4/2) = 2

→ 8개 워드 요청 → 4개 라인 요청 → 2개 배치로 분할
```

---

## 타임아웃 검증 (시뮬레이션)

응답이 일정 시간 내에 오지 않으면 에러:

```systemverilog
`ifdef SIMULATION
    localparam STALL_TIMEOUT = 10000000;

    reg [64-1:0] pending_reqs_time [CORE_QUEUE_SIZE-1:0];
    reg [CORE_QUEUE_SIZE-1:0] pending_reqs_valid;

    always @(posedge clk) begin
        for (integer i = 0; i < CORE_QUEUE_SIZE; ++i) begin
            if (pending_reqs_valid[i]) begin
                `ASSERT(($time - pending_reqs_time[i]) < STALL_TIMEOUT,
                    ("%t: *** %s response timeout: tag=0x%0h",
                        $time, INSTANCE_ID, ...));
            end
        end
    end
`endif
```

---

## 관련 파일

- [VX_lsu_slice.sv](VX_lsu_slice.md) - LSU 슬라이스 (사용처)
- [VX_mem_coalescer.sv](../../../../hw/rtl/libs/VX_mem_coalescer.sv) - 메모리 Coalescer
- [VX_index_buffer.sv](../../../../hw/rtl/libs/VX_index_buffer.sv) - 인덱스 버퍼
- [VX_elastic_buffer.sv](../../../../hw/rtl/libs/VX_elastic_buffer.sv) - Elastic 버퍼

---

## 성능 특성

- **레이턴시**: 가변 (메모리 응답 시간 + 재조립 시간)
- **스루풋**: 사이클당 MEM_CHANNELS개 메모리 요청
- **큐 깊이**: CORE_QUEUE_SIZE개 동시 진행 요청
- **Coalescing 효율**: LINE_SIZE/WORD_SIZE배 대역폭 절감 가능

## 디버그 지원

`DBG_TRACE_MEM` 정의 시 상세 트레이스 출력:

```systemverilog
`ifdef DBG_TRACE_MEM
    always @(posedge clk) begin
        if (core_req_fire) begin
            `TRACE(2, ("%t: %s core-req-%s: valid=%b, addr=...",
                $time, INSTANCE_ID, core_req_rw ? "wr" : "rd", core_req_mask))
        end
        if (mem_req_fire_s) begin
            `TRACE(2, ("%t: %s mem-req-%s: valid=%b, addr=..., ibuf_idx=%0d, batch_idx=%0d",
                $time, INSTANCE_ID, mem_req_rw_s ? "wr" : "rd", mem_req_mask_s, ibuf_waddr_s, req_batch_idx))
        end
        if (core_rsp_valid && core_rsp_ready) begin
            `TRACE(2, ("%t: %s core-rsp: valid=%b, sop=%b, eop=%b, data=...",
                $time, INSTANCE_ID, core_rsp_mask, core_rsp_sop, core_rsp_eop))
        end
    end
`endif
```
