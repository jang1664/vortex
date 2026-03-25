# Fetch Stage - 명령어 가져오기

## 개요
Fetch stage는 Vortex GPU의 파이프라인 첫 단계로, instruction cache(icache)에서 명령어를 가져오는 역할을 한다.

**파일**: `hw/rtl/core/VX_fetch.sv`

## 파이프라인 위치
```
Schedule → [FETCH] → Decode → Issue → Execute → Commit
```

## 주요 인터페이스

### 입력
```systemverilog
VX_schedule_if.slave schedule_if
- valid, ready: Handshake
- data.wid: Warp ID (NW_WIDTH 비트)
- data.PC: Program Counter (PC_BITS)
- data.tmask: Thread mask (NUM_THREADS 비트)
- data.uuid: Debug UUID (UUID_WIDTH)
```
Scheduler로부터 실행할 warp 정보를 받는다.

### 출력
```systemverilog
VX_fetch_if.master fetch_if
- valid, ready: Handshake
- data.wid: Warp ID
- data.PC: Program Counter
- data.tmask: Thread mask
- data.instr: Fetched instruction (32비트)
- data.uuid: Debug UUID

wire [NUM_WARPS-1:0] ibuf_pop (L1_ENABLE 없을 때만)
```
Decode stage로 가져온 명령어를 전달한다.

### 메모리 인터페이스
```systemverilog
VX_mem_bus_if.master icache_bus_if
- req_valid, req_ready
- req_data.addr: ICACHE_ADDR_WIDTH
- req_data.tag: ICACHE_TAG_WIDTH = UUID_WIDTH + NW_WIDTH
- rsp_valid, rsp_ready
- rsp_data.data: Instruction word (ICACHE_WORD_SIZE * 8 비트)
- rsp_data.tag: {uuid, wid}
```

## 핵심 구조

### 1. Tag Store (요청 메타데이터 저장)
```systemverilog
VX_dp_ram #(
    .DATAW (PC_BITS + NUM_THREADS),
    .SIZE  (NUM_WARPS),
    .RDW_MODE ("R"),
    .LUTRAM (1)
) tag_store
```
- **용도**: 각 warp의 PC와 tmask를 저장
- **Write**: icache 요청 시 (wid를 주소로 사용)
- **Read**: icache 응답 시 (응답 태그의 wid로 읽음)
- **이유**: Icache는 out-of-order로 응답할 수 있으므로 요청 시점의 PC/tmask를 복원해야 함

### 2. IBuffer Full Prevention (L1_ENABLE 없을 때만)
```systemverilog
VX_pending_size #(.SIZE(IBUF_SIZE)) pending_reads
- incr: icache_req_fire && schedule_if.data.wid == i
- decr: fetch_if.ibuf_pop[i]
- full: pending_ibuf_full[i]

wire ibuf_ready = ~pending_ibuf_full[schedule_if.data.wid];
```
- **문제**: L1 cache가 없으면 icache와 dcache가 같은 버스 공유
- **데드락 시나리오**: 
  1. IBuffer가 가득 참
  2. LSU가 dcache 요청으로 execute stage를 stall
  3. Icache 요청도 같은 버스에서 대기
  4. IBuffer가 비워지지 않아 데드락
- **해결**: 각 warp별로 pending icache 요청 수를 추적하여 IBUF_SIZE 도달 시 요청 중단

### 3. Request Elastic Buffer
```systemverilog
VX_elastic_buffer #(
    .DATAW (ICACHE_ADDR_WIDTH + ICACHE_TAG_WIDTH),
    .SIZE  (2),
    .OUT_REG (1)
) req_buf
```
- **크기**: 2 엔트리 (최소한의 파이프라인 깊이)
- **OUT_REG**: 외부 버스는 레지스터로 출력 (타이밍 개선)

## 동작 흐름

### Request Path
```
1. Schedule → valid & ready check
   - schedule_if.valid: 실행할 warp 있음
   - ibuf_ready: IBuffer에 여유 있음 (L1_ENABLE 없을 때만)

2. Icache Request 생성
   - addr = PC[2 +: ICACHE_ADDR_WIDTH] (4-byte 정렬 주소)
   - tag = {uuid, wid}
   
3. Tag Store에 메타데이터 저장
   - waddr = wid
   - wdata = {PC, tmask}
   
4. Elastic Buffer를 통해 icache_bus_if로 전송
```

### Response Path
```
1. Icache Response 수신
   - icache_bus_if.rsp_valid
   - rsp_data.tag = {rsp_uuid, rsp_tag(=wid)}
   - rsp_data.data = instruction

2. Tag Store에서 메타데이터 복원
   - raddr = rsp_tag (wid)
   - rdata = {rsp_PC, rsp_tmask}

3. Fetch Interface로 전달
   - fetch_if.data.wid = rsp_tag
   - fetch_if.data.PC = rsp_PC (복원)
   - fetch_if.data.tmask = rsp_tmask (복원)
   - fetch_if.data.instr = rsp_data.data
   - fetch_if.data.uuid = rsp_uuid
```

## 주소 처리
```systemverilog
icache_req_addr = schedule_if.data.PC[2-(`XLEN-PC_BITS) +: ICACHE_ADDR_WIDTH]
```
- `XLEN`: 32 또는 64비트
- `PC_BITS`: 실제 PC 비트 수
- `[2-(...)]`: 하위 2비트 제거 (4-byte 정렬)
- RISC-V는 4-byte 정렬된 명령어 사용

## IBuffer Pop 신호 (L1_ENABLE 없을 때)
```systemverilog
fetch_if.ibuf_pop[NUM_WARPS-1:0]
```
- **용도**: Decode stage에서 IBuffer 엔트리 소비 시 신호
- **연결**: Decode → Issue → ibuffer → ibuf_pop
- **목적**: Pending size 추적으로 backpressure 관리

## Assertion
```systemverilog
`RUNTIME_ASSERT((!schedule_if.valid || schedule_if.data.PC != 0),
    ("invalid PC=0x%0h, wid=%0d, tmask=%b (#%0d)", 
     to_fullPC(schedule_if.data.PC), schedule_if.data.wid, 
     schedule_if.data.tmask, schedule_if.data.uuid))
```
- **검사**: PC=0 방지 (일반적으로 유효하지 않은 주소)

## Trace 및 디버깅

### DBG_TRACE_MEM
```systemverilog
schedule_if.valid && schedule_if.ready:
  "req: wid=%0d, PC=0x%0h, tmask=%b (#%0d)"

fetch_if.valid && fetch_if.ready:
  "rsp: wid=%0d, PC=0x%0h, tmask=%b, instr=0x%0h (#%0d)"
```

### Scope/Chipscope
- Schedule interface 신호 추적
- Icache request/response 추적
- Fire 신호 (valid && ready) 추적

## 성능 고려사항

### Latency
- Tag store: 1 cycle read latency
- Elastic buffer: 2 엔트리 (OUT_REG=1로 1 cycle 추가)
- Total: schedule → fetch_if = icache latency + 1~2 cycles

### Throughput
- 매 사이클마다 새로운 warp 요청 가능 (파이프라인)
- IBuffer full로 인한 stall 가능 (L1_ENABLE 없을 때)

### Out-of-Order Response
- Tag store 덕분에 out-of-order 응답 처리 가능
- Wid를 주소로 사용하므로 최대 NUM_WARPS개 동시 pending 가능

## 설계 특징

### 1. 단순성
- Fetch는 복잡한 로직 없음 (분기 예측 없음)
- Schedule이 결정한 warp의 PC를 그대로 fetch

### 2. In-Order Issue, Out-of-Order Completion
- Fetch 요청은 in-order (schedule 순서대로)
- Icache 응답은 out-of-order 가능 (tag store로 복원)

### 3. Backpressure Management
- L1 없을 때: IBuffer 크기로 pending 요청 제한
- L1 있을 때: Icache 자체 큐로 관리

### 4. SIMT 모델
- 각 warp가 독립적으로 fetch
- Tmask로 활성 스레드 추적
- 같은 warp 내 모든 스레드는 같은 명령어 실행
