# VX_mem_scheduler - 메모리 스케줄러

## 개요
`VX_mem_scheduler`는 다수의 코어 요청을 메모리 채널로 분배하고, 응답을 코어로 다시 전달하는 메모리 스케줄링 모듈이다. 요청 큐잉, 메모리 병합(coalescing), 배치 처리, 응답 재구성 기능을 제공한다.

**위치**: `hw/rtl/libs/VX_mem_scheduler.sv`

## 주요 파라미터
- `CORE_REQS`: 코어에서 들어오는 요청 개수 (예: NUM_LANES)
- `MEM_CHANNELS`: 메모리 채널 개수
- `WORD_SIZE`: 코어 요청의 워드 크기 (바이트 단위)
- `LINE_SIZE`: 메모리 라인 크기 (바이트 단위)
- `CORE_QUEUE_SIZE`: 코어 요청 큐 크기 (기본 8)
- `MEM_QUEUE_SIZE`: 메모리 요청 큐 크기
- `RSP_PARTIAL`: 부분 응답 허용 여부 (0=전체 응답 대기, 1=부분 응답 즉시 전달)

## 파생 파라미터
```systemverilog
COALESCE_ENABLE = (CORE_REQS > 1) && (LINE_SIZE != WORD_SIZE)
PER_LINE_REQS   = LINE_SIZE / WORD_SIZE         // 라인당 워드 수
MERGED_REQS     = CORE_REQS / PER_LINE_REQS     // 병합 후 요청 수
MEM_BATCHES     = CDIV(MERGED_REQS, MEM_CHANNELS) // 배치 개수
```

## 핵심 구조

### 1. Request Queue (요청 큐)
```
core_req → VX_elastic_buffer → reqq
          (CORE_QUEUE_SIZE)
```
- 코어 요청을 버퍼링
- 읽기 요청만 Index Buffer에 태그 저장
- `reqq_tag = {UUID, ibuf_waddr}`: 응답 매칭용 태그 생성

### 2. Index Buffer (인덱스 버퍼)
```
VX_index_buffer
- 크기: CORE_QUEUE_SIZE
- 저장: TAG_ID_WIDTH 비트 (원본 태그)
- Push: 읽기 요청 시 (ibuf_push = core_req_fire && ~core_req_rw)
- Pop: 응답 완료 시 (ibuf_pop = crsp_fire && crsp_eop)
```
**역할**: 읽기 요청의 원본 태그를 저장하여 응답 재구성 시 복원

### 3. Memory Coalescer (메모리 병합기)
`COALESCE_ENABLE` 조건일 때 활성화:
```
VX_mem_coalescer 
- 입력: CORE_REQS × WORD_SIZE
- 출력: MERGED_REQS × LINE_SIZE
```

**병합 로직**:
1. 같은 캐시 라인 주소를 가진 요청들을 그룹화
2. 바이트 단위로 병합 (각 레인의 byteen 고려)
3. 여러 배치로 분할될 수 있음 (is_last_batch로 완료 확인)

**미병합 감지**: `misses` 카운터로 부분 전송 추적 (성능 분석용)

### 4. Batch Processing (배치 처리)
`MEM_BATCHES > 1`일 때:
```
req_batch_idx_r : 현재 배치 인덱스
req_batch_idx_last : 마지막 유효 배치 인덱스

mem_req_tag = {reqq_tag_s, req_batch_idx}
```
- 병합된 요청을 메모리 채널 수에 맞춰 배치로 분할
- 각 배치를 순차적으로 메모리에 전송
- 마지막 배치 전송 시 `req_sent_all` 신호 발생

### 5. Response Reconstruction (응답 재구성)

#### CORE_REQS == 1 (단일 요청)
```
crsp_valid = mem_rsp_valid_s
crsp_mask  = mem_rsp_mask_s
crsp_sop   = 1 (항상)
crsp_eop   = 1 (항상)
```

#### CORE_REQS > 1 (다중 요청)
**RSP_PARTIAL == 0 (전체 응답 대기)**:
```
rsp_store[CORE_QUEUE_SIZE][CORE_CHANNELS][CORE_BATCHES]: 응답 데이터 저장
rsp_orig_mask[CORE_QUEUE_SIZE]: 원본 마스크 저장

crsp_valid = mem_rsp_valid_s && rsp_complete
crsp_mask  = rsp_orig_mask[ibuf_raddr]
crsp_eop   = rsp_complete (모든 배치 수신 완료)
```
- 모든 배치 응답을 `rsp_store`에 저장
- `rsp_rem_mask`로 미수신 배치 추적
- 모든 배치 수신 후 한번에 코어로 전달

**RSP_PARTIAL == 1 (부분 응답 허용)**:
```
rsp_sop_r[CORE_QUEUE_SIZE]: 첫 응답 여부 추적

crsp_valid = mem_rsp_valid_s (즉시)
crsp_mask  = curr_mask (현재 배치만)
crsp_sop   = rsp_sop_r[ibuf_raddr]
crsp_eop   = rsp_complete
```
- 배치 응답이 도착할 때마다 즉시 전달
- SOP(Start of Packet), EOP(End of Packet)로 경계 표시

#### 태그 복원
```systemverilog
crsp_tag = {UUID, ibuf_dout}
// ibuf_dout = 원본 TAG_ID (Index Buffer에서 읽음)
```

### 6. 신호 흐름
```
[Core Request] 
    → Request Queue 
    → Index Buffer (read 시) 
    → Coalescer (optional) 
    → Batch Scheduler 
    → [Memory Request]

[Memory Response] 
    → Batch Reconstructor 
    → Data Store (full mode) 
    → Index Buffer Lookup 
    → Tag Restoration 
    → [Core Response]
```

## Coalescing 상세 (VX_mem_coalescer)

### 주소 병합 로직
```systemverilog
in_addr_offset[i] = in_req_addr[i][DATA_RATIO_W-1:0]  // 라인 내 오프셋
seed_addr[i] = in_req_addr[i][ADDR_WIDTH-1:DATA_RATIO_W]  // 라인 기준 주소

addr_matches[j] = (addr_base[j] == seed_addr)  // 같은 라인 검사
current_pmask = in_req_mask & addr_matches_r   // 병합 대상 마스크
```

### 바이트 병합
```systemverilog
for (j = 0; j < DATA_RATIO; ++j) begin
    for (k = 0; k < DATA_IN_SIZE; ++k) begin
        if (current_pmask[i*DATA_RATIO+j] && in_req_byteen[...][k]) begin
            byteen_merged[in_addr_offset[...]][k] = 1'b1;
            data_merged[in_addr_offset[...]][k*8 +: 8] = in_req_data[...][k*8 +: 8];
        end
    end
end
```
- 각 레인의 오프셋에 맞춰 라인 내 위치 결정
- 바이트 단위로 병합 (각 레인이 다른 바이트 활성화 가능)

### 상태 머신
```
STATE_WAIT: 이전 요청 전송 대기, ibuf 여유 확인
STATE_SEND: 병합 데이터 전송, is_last_batch 확인
```

### 응답 언머지
```systemverilog
ibuf_dout_offset: 각 요청의 라인 내 오프셋 복원
in_rsp_data_n[i*DATA_RATIO+j] = out_rsp_data[i][ibuf_dout_offset[...] * DATA_IN_WIDTH +: DATA_IN_WIDTH]
```

## LSU Adapter (Stream Unpack/Pack)

### VX_lsu_adapter
**위치**: `hw/rtl/mem/VX_lsu_adapter.sv`

**기능**: LSU 메모리 인터페이스를 개별 레인의 메모리 버스로 변환

#### Request Unpacking
```
VX_stream_unpack
- 입력: lsu_mem_if (mask 기반 다중 요청)
- 출력: mem_bus_if[NUM_LANES] (레인별 개별 요청)

mask_in → valid_out[i] (마스크 비트별 활성화)
data_in[i] → data_out[i] (요청 데이터)
tag_in → tag_out[i] (동일 태그 전파)
```

#### Response Packing
```
VX_stream_pack
- 입력: mem_bus_if[NUM_LANES] (레인별 응답)
- 출력: lsu_mem_if (mask 기반 응답)

valid_in[i] → mask_out (유효 레인 마스크)
data_in[i] → data_out[i] (응답 데이터)
tag_in[i] → tag_out (태그 매칭, TAG_SEL_BITS로 그룹화)
```

## Misaligned Access 처리

Vortex는 **메모리 misaligned access를 지원하지 않는다**.

### 검증 위치
**VX_lsu_slice.sv (lines 186-192)**:
```systemverilog
// memory misalignment not supported!
for (genvar i = 0; i < NUM_LANES; ++i) begin : g_missalign
    wire lsu_req_fire = execute_if.valid && execute_if.ready;
    `RUNTIME_ASSERT((~lsu_req_fire || ~execute_if.data.tmask[i] || req_is_fence || 
        (full_addr[i] % (1 << inst_lsu_wsize(execute_if.data.op_type))) == 0),
        ("%t: misaligned memory access, wid=%0d, PC=0x%0h, addr=0x%0h, wsize=%0d! (#%0d)",
            $time, execute_if.data.wid, to_fullPC(execute_if.data.PC), 
            full_addr[i], inst_lsu_wsize(execute_if.data.op_type), execute_if.data.uuid))
end
```

### 정렬 요구사항
```
wsize=0 (byte):  주소 % 1 == 0 (항상 정렬)
wsize=1 (half):  주소 % 2 == 0
wsize=2 (word):  주소 % 4 == 0
wsize=3 (dword): 주소 % 8 == 0
```

### 소프트웨어 책임
- 컴파일러: 정렬된 메모리 액세스 생성
- 런타임: 정렬되지 않은 액세스 시 에러 발생 (assertion)
- 하드웨어: 정렬 가정 하에 최적화된 설계

### Memory Hierarchy에서의 처리
1. **VX_lsu_slice** (LSU 진입점):
   - 실행 시점에 주소 정렬 검증
   - 위반 시 assertion failure (시뮬레이션)

2. **VX_mem_scheduler**:
   - 정렬된 주소만 가정
   - Coalescing 시 라인 경계 기준으로 병합
   - `in_addr_offset` 계산 시 정렬 가정

3. **Cache/Memory**:
   - 정렬된 액세스만 처리
   - 라인 단위 전송 최적화

### 설계 이유
- **성능**: 정렬 가정으로 crossbar, coalescing 로직 단순화
- **면적**: Misaligned 처리 하드웨어 불필요
- **복잡도**: 캐시 라인 경계 처리 복잡도 회피
- **RISC-V 호환**: RISC-V는 misaligned access를 선택적 기능으로 정의

## 주요 신호

### Request Interface
```systemverilog
// Core → Scheduler
core_req_valid, core_req_ready
core_req_rw        // 1=write, 0=read
core_req_mask      // CORE_REQS 비트
core_req_byteen    // [CORE_REQS][WORD_SIZE]
core_req_addr      // [CORE_REQS][ADDR_WIDTH]
core_req_flags     // [CORE_REQS][FLAGS_WIDTH]
core_req_data      // [CORE_REQS][WORD_WIDTH]
core_req_tag       // [TAG_WIDTH]

// Scheduler → Memory
mem_req_valid, mem_req_ready
mem_req_rw
mem_req_mask       // MEM_CHANNELS 비트
mem_req_byteen     // [MEM_CHANNELS][LINE_SIZE]
mem_req_addr       // [MEM_CHANNELS][MEM_ADDR_WIDTH]
mem_req_flags      // [MEM_CHANNELS][FLAGS_WIDTH]
mem_req_data       // [MEM_CHANNELS][LINE_WIDTH]
mem_req_tag        // [MEM_TAG_WIDTH] = {UUID, QUEUE_ADDR, BATCH_IDX}
```

### Response Interface
```systemverilog
// Memory → Scheduler
mem_rsp_valid, mem_rsp_ready
mem_rsp_mask       // MEM_CHANNELS 비트
mem_rsp_data       // [MEM_CHANNELS][LINE_WIDTH]
mem_rsp_tag        // [MEM_TAG_WIDTH]

// Scheduler → Core
core_rsp_valid, core_rsp_ready
core_rsp_mask      // CORE_REQS 비트
core_rsp_data      // [CORE_REQS][WORD_WIDTH]
core_rsp_tag       // [TAG_WIDTH]
core_rsp_sop       // Start of packet
core_rsp_eop       // End of packet
```

### 상태 신호
```systemverilog
req_queue_empty       // 요청 큐 비어있음
req_queue_rw_notify   // Write 요청 전송됨
```

## 타이밍

### Request Path
```
core_req → elastic_buffer(1 cycle) → coalescer(variable) → batch_scheduler(1 cycle) → elastic_buffer(OUT_BUF) → mem_req
```

### Response Path
```
mem_rsp → reconstructor(0~1 cycle) → elastic_buffer(OUT_BUF) → core_rsp
```

### Coalescer FSM Timing
```
STATE_WAIT: ibuf 여유 대기, out_req 전송 대기
STATE_SEND: 1 cycle (병합 데이터 전송, 다음 STATE_WAIT)
```

## 성능 고려사항

### Coalescing 효율
- 같은 캐시 라인 접근 시 병합 가능
- 순차 메모리 접근 패턴에서 효율 최대화
- `misses` 카운터로 병합 실패율 추적

### 큐 깊이 선택
- `CORE_QUEUE_SIZE`: 코어-메모리 레이턴시 숨김
- `MEM_QUEUE_SIZE`: 병합 기회 증가 (크면 더 많이 병합)

### RSP_PARTIAL 선택
- 0 (Full): 레이턴시 증가, 대역폭 효율적 (한번에 전송)
- 1 (Partial): 레이턴시 감소, 트래픽 증가 (여러번 전송)

### 배치 처리 오버헤드
- `MEM_BATCHES` 클수록 순차 전송 사이클 증가
- 작은 메모리 채널 수에서는 배치 오버헤드 증가

## 디버깅

### Simulation Trace
```systemverilog
DBG_TRACE_MEM 정의 시:
- core-req-wr/rd: 코어 요청 (주소, 데이터, 태그)
- core-rsp: 코어 응답 (데이터, sop/eop, 태그)
- mem-req-wr/rd: 메모리 요청 (ibuf_idx, batch_idx)
- mem-rsp: 메모리 응답 (ibuf_idx, batch_idx)
```

### Timeout Detection
```systemverilog
STALL_TIMEOUT = 10000000 cycles
pending_reqs_time[i] = {uuid, tag, $time}
// 응답 대기 시간 초과 시 assertion
```

### Assertion 검사
- `in_req_mask != 0`: 유효 요청은 마스크 필요
- Response timeout: 응답 지연 감지
- Index buffer consistency: Push/Pop 균형
