# `VX_cache.sv` — 캐시 본체 상세 분석

파일: `hw/rtl/cache/VX_cache.sv`

## 1. 역할

`VX_cache`는 캐시 시스템의 본체로, 다음을 담당합니다:
- **Core Request Dispatch**: NUM_REQS개의 코어 요청을 NUM_BANKS개의 뱅크로 분배
- **Bank 인스턴스화**: NUM_BANKS개의 `VX_cache_bank` 생성 및 관리
- **Core Response Gather**: 뱅크에서 나온 응답을 원래 요청 포트로 라우팅
- **Memory Request Arbitration**: 뱅크에서 나온 메모리 요청을 MEM_PORTS개 포트로 중재
- **Memory Response Distribution**: 메모리 응답을 해당 뱅크로 분배
- **성능 카운터 집계**

## 2. 주요 파라미터

| 파라미터 | 기본값 | 설명 |
|----------|--------|------|
| `NUM_REQS` | 4 | 사이클당 코어 요청 수 |
| `MEM_PORTS` | 1 | 외부 메모리 포트 수 |
| `CACHE_SIZE` | 32768 | 캐시 총 크기 (바이트) |
| `LINE_SIZE` | 64 | 캐시 라인 크기 (바이트) |
| `NUM_BANKS` | 4 | 뱅크 수 (2의 거듭제곱) |
| `NUM_WAYS` | 4 | set-associativity |
| `WORD_SIZE` | 16 | 워드 크기 (바이트) |
| `CRSQ_SIZE` | 4 | Core Response Queue 크기 |
| `MSHR_SIZE` | 16 | MSHR 엔트리 수 |
| `MRSQ_SIZE` | 4 | Memory Response Queue 크기 |
| `MREQ_SIZE` | 4 | Memory Request Queue 크기 |
| `WRITE_ENABLE` | 1 | 쓰기 가능 여부 |
| `WRITEBACK` | 0 | writeback (1) vs write-through (0) |
| `DIRTY_BYTES` | 0 | dirty byte 단위 추적 |
| `REPL_POLICY` | FIFO | 교체 정책 |

## 3. 인터페이스

### 3.1 코어 측
```
core_bus_if [NUM_REQS]  (VX_mem_bus_if, slave)
  - req: valid, rw, byteen, addr, flags, data, tag
  - rsp: valid, data, tag
```

### 3.2 메모리 측
```
mem_bus_if [MEM_PORTS]  (VX_mem_bus_if, master)
  - req: valid, rw, byteen, addr, data, tag
  - rsp: valid, data, tag
```

### 3.3 기타
- `cache_perf` (output): 성능 카운터 구조체 (PERF_ENABLE 시)
- `cache_drain` (output): 캐시에 pending 요청이 없을 때 asserted

## 4. 내부 구조 상세

### 4.1 VX_cache_init (flush 관리)
```systemverilog
VX_cache_init cache_init (
    .core_bus_in_if  (core_bus_if),      // 원본 코어 요청
    .core_bus_out_if (core_bus2_if),      // flush가 아닌 요청만 통과
    .bank_req_fire   (per_bank_core_req_fire),
    .flush_begin     (per_bank_flush_begin),
    .flush_uuid      (flush_uuid),
    .flush_end       (per_bank_flush_end)
);
```
- `MEM_REQ_FLAG_FLUSH` 플래그가 있는 요청을 감지
- flush 중에는 일반 요청을 차단
- 모든 뱅크의 flush 완료를 대기

### 4.2 Core Request Dispatch (core_req_xbar)

주소에서 bank ID를 추출하여 요청을 해당 뱅크로 라우팅합니다:

```systemverilog
// 주소에서 bank ID 추출
core_req_bid[i] = core_req_addr[i][WORD_SEL_BITS +: BANK_SEL_BITS];

// 주소에서 line address 추출 (bank 내 주소)
core_req_line_addr[i] = core_req_addr[i][(BANK_SEL_BITS + WORD_SEL_BITS) +: LINE_ADDR_WIDTH];

// crossbar: NUM_REQS inputs → NUM_BANKS outputs
VX_stream_xbar #(
    .NUM_INPUTS  (NUM_REQS),
    .NUM_OUTPUTS (NUM_BANKS),
    .ARBITER     ("R")        // Round-robin
) core_req_xbar (
    .sel_in    (core_req_bid),          // bank ID로 라우팅
    .sel_out   (per_bank_core_req_idx), // 어느 코어 포트에서 왔는지 기록
    ...
);
```

**핵심**: `core_req_data_in`에 패킹되는 데이터:
```
{line_addr, rw, wsel, byteen, data, tag, flags}
```
crossbar 출력에서 이를 다시 언패킹하여 각 뱅크에 전달합니다.

### 4.3 Bank 인스턴스화 (g_banks)

```systemverilog
for (genvar bank_id = 0; bank_id < NUM_BANKS; ++bank_id) begin : g_banks
    VX_cache_bank #(...) bank (
        // Core request/response
        .core_req_valid, .core_req_addr, .core_req_rw, ...
        .core_rsp_valid, .core_rsp_data, .core_rsp_tag, .core_rsp_idx,
        // Memory request/response
        .mem_req_valid, .mem_req_addr, ...
        .mem_rsp_valid, .mem_rsp_data, .mem_rsp_tag,
        // Flush
        .flush_begin, .flush_uuid, .flush_end, .drain
    );
end
```

### 4.4 Memory Response Distribution (mem_rsp_xbar)

메모리 응답은 tag에 인코딩된 bank ID를 기반으로 해당 뱅크로 라우팅됩니다:

```systemverilog
// Memory Response Queue (MRSQ) - 각 메모리 포트마다 하나
VX_elastic_buffer #(.SIZE(MRSQ_SIZE)) mem_rsp_queue (...);

// tag에서 bank selector 추출
// tag 구조: [UUID | MSHR_ADDR | ARB_SEL(bank)]
mem_rsp_queue_sel[i] = {mem_rsp_queue_data[i][MEM_ARB_SEL_BITS-1:0], i};

// omega crossbar: MEM_PORTS → NUM_BANKS
VX_stream_omega #(
    .NUM_INPUTS  (MEM_PORTS),
    .NUM_OUTPUTS (NUM_BANKS)
) mem_rsp_xbar (...);
```

### 4.5 Core Response Gather (core_rsp_xbar)

각 뱅크의 응답을 원래 코어 포트로 라우팅합니다:

```systemverilog
// per_bank_core_rsp_idx: 뱅크가 기억하고 있는 원래 코어 포트 인덱스
VX_stream_xbar #(
    .NUM_INPUTS  (NUM_BANKS),
    .NUM_OUTPUTS (NUM_REQS)
) core_rsp_xbar (
    .sel_in    (per_bank_core_rsp_idx),  // 어느 코어 포트로 보낼지
    ...
);

// 출력 버퍼
VX_elastic_buffer core_rsp_buf (...);  // 각 NUM_REQS 포트마다
```

### 4.6 Memory Request Arbitration (mem_req_arb)

뱅크에서 나온 메모리 요청을 MEM_PORTS개 포트로 중재합니다:

```systemverilog
VX_stream_arb #(
    .NUM_INPUTS (NUM_BANKS),
    .NUM_OUTPUTS(MEM_PORTS),
    .ARBITER    ("R")
) mem_req_arb (...);
```

bank ID를 메모리 주소와 tag에 인코딩:
```systemverilog
// 다중 뱅크: bank_id를 주소 하위에 붙여 전체 메모리 주소 복원
mem_req_addr_w = {mem_req_addr, mem_req_bank_id};
// tag에 arb_sel 추가 (응답 시 뱅크 식별용)
mem_req_tag_w = {mem_req_tag, mem_req_sel_out[i]};
```

## 5. 성능 카운터 (PERF_ENABLE)

| 카운터 | 측정 대상 |
|--------|-----------|
| `reads` | 성공적으로 수락된 read 요청 수 |
| `writes` | 성공적으로 수락된 write 요청 수 |
| `read_misses` | read miss 횟수 (각 뱅크에서 합산) |
| `write_misses` | write miss 횟수 |
| `bank_stalls` | bank crossbar 충돌 횟수 (같은 뱅크에 동시 접근) |
| `mshr_stalls` | MSHR full로 인한 stall 횟수 |
| `mem_stalls` | 메모리 포트 backpressure로 인한 stall 횟수 |
| `crsp_stalls` | core response 포트 backpressure로 인한 stall 횟수 |

## 6. cache_drain 신호

```systemverilog
assign cache_drain = (& per_bank_drain) && ~cache_pending;
```
모든 뱅크가 drain 상태이고, crossbar/큐에 pending 데이터가 없을 때 asserted. shutdown이나 flush 완료 판단에 사용됩니다.

## 7. 설계 핵심 포인트

1. **Bank Interleaving**: WORD_SEL 바로 위에 BANK_SEL이 위치하여, 연속 워드 접근이 서로 다른 뱅크에 분산됩니다.
2. **Tag in Memory Request**: 메모리 요청의 tag에 `{UUID, MSHR_ADDR, BANK_SEL}`을 인코딩하여, 응답이 돌아왔을 때 어느 뱅크의 어느 MSHR 엔트리에 해당하는지 식별합니다.
3. **Elastic Buffers**: 입출력에 `VX_elastic_buffer`를 사용하여 backpressure를 처리하고 타이밍을 완화합니다.
4. **Static Assertions**: `NUM_BANKS`가 2의 거듭제곱인지, `WRITEBACK` 없이 `DIRTY_BYTES`를 쓰지 않는지 등을 컴파일 타임에 검증합니다.
