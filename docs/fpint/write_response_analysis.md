# Vortex 메모리 시스템 Write Response 분석

## 결론: Write Response는 생성되지 않는다

Vortex는 **fire-and-forget write** 방식을 채택한다. 모든 레벨에서 일관되게 write에 대한 response를 drop한다.

---

## 1. VX_cache_bank (L1/L2/L3 Cache)

**파일**: `hw/rtl/cache/VX_cache_bank.sv`

```systemverilog
// core response는 read hit일 때만 생성
assign crsp_queue_valid = do_read_st1 && is_hit_st1;
```

- `do_read_st1 = valid_st1 && is_creq_st1 && ~rw_st1` → write면 항상 false
- **Write hit/miss 모두 core response 없음**

### Write Request 생성 경로

| 모드 | 조건 | 동작 |
|---|---|---|
| **Writethrough** | Write hit 또는 Write miss | `mreq_queue`에 write 요청 push → 메모리로 전달 |
| **Writeback** | Eviction 시 dirty line | `mreq_queue`에 writeback push → 메모리로 전달 |

```systemverilog
// Writethrough: read miss 또는 write 시 메모리 요청 생성
assign mreq_queue_push = ((do_read_st1 && ~is_hit_st1 && ~mshr_pending_st1)
                       || do_write_st1)
                       && ~pipe_stall;

// Writeback: read/write miss 또는 dirty eviction 시 메모리 요청 생성
assign mreq_queue_push = ((do_lookup_st1 && ~is_hit_st1 && ~mshr_pending_st1)
                       || do_writeback_st1)
                       && ~pipe_stall;
```

---

## 2. VX_local_mem (Local Memory / SRAM)

**파일**: `hw/rtl/mem/VX_local_mem.sv`

```systemverilog
// write response를 명시적으로 drop
assign bank_rsp_valid = per_bank_req_valid[i] && ~per_bank_req_rw[i] && ~is_rdw_hazard;
assign per_bank_req_ready[i] = (bank_rsp_ready || per_bank_req_rw[i]) && ~is_rdw_hazard;
```

- `~per_bank_req_rw[i]` → **read일 때만** response 생성
- write 시 `per_bank_req_rw[i] = 1` → `req_ready`는 `rsp_ready`와 무관하게 즉시 accept

---

## 3. VX_mem_scheduler (LSU ↔ Memory 중간 계층)

**파일**: `hw/rtl/libs/VX_mem_scheduler.sv`

```systemverilog
// write 요청은 index buffer에 저장하지 않음 (response 추적 불필요)
assign ibuf_push  = core_req_fire && ~core_req_rw;
assign ibuf_ready = (core_req_rw || ~ibuf_full);  // write는 ibuf 공간 불필요
```

- write 요청은 `ibuf` (index buffer)에 등록하지 않음
- response를 기다릴 필요가 없으므로 추적하지 않음
- `ibuf_ready`는 write일 때 항상 true → ibuf full에 의한 backpressure 없음

---

## 4. VX_lsu_slice (LSU → Pipeline 결과 반환)

**파일**: `hw/rtl/core/VX_lsu_slice.sv`

```systemverilog
// write && ~wb (레지스터 writeback 없음)이면 no_rsp_buf 경로로 즉시 완료 처리
wire no_rsp_buf_enable = (mem_req_rw && ~execute_if.data.wb) || req_skip;
```

### 두 가지 결과 경로

| 경로 | 조건 | 동작 |
|---|---|---|
| `result_rsp_if` | Read 요청 (wb=1) | 메모리 응답을 기다려 데이터를 레지스터에 writeback |
| `result_no_rsp_if` | Store 요청 (rw=1, wb=0) | **메모리 응답 불필요**, 요청 발행 즉시 pipeline에 완료 통보 |

```systemverilog
// no_rsp_buf: 메모리 응답 없이 즉시 완료 처리
VX_elastic_buffer #(...) no_rsp_buf (
    .valid_in  (no_rsp_buf_valid),  // store 요청 발행 시 즉시 valid
    .data_in   ({uuid, wid, tmask, PC, pid, sop, eop}),
    ...
);

// wb=0, data는 don't care (arbiter MUX 최적화로 rsp_if의 data를 공유)
assign result_no_rsp_if.data.rd   = '0;
assign result_no_rsp_if.data.wb   = 1'b0;
assign result_no_rsp_if.data.data = result_rsp_if.data.data;
```

두 경로는 Priority arbiter로 합류 (`result_rsp_if` 우선):

```systemverilog
VX_stream_arb #(
    .NUM_INPUTS (2),
    .ARBITER    ("P")   // result_rsp_if 우선
) rsp_arb (
    .valid_in  ({result_no_rsp_if.valid, result_rsp_if.valid}),
    ...
);
```

---

## 5. VX_cache_bypass (NC 바이패스 경로)

**파일**: `hw/rtl/cache/VX_cache_bypass.sv`

- NC 경로로 write 요청이 외부 메모리에 직접 전달됨
- 외부 메모리가 write에 대해 response를 보내면 전달은 되지만, **외부 메모리 자체가 write response를 보내지 않음**
- NC 경로의 response는 read 응답에 대해서만 의미가 있음

---

## 6. Vortex Top Level (외부 메모리 인터페이스)

**파일**: `hw/rtl/Vortex.sv`

```systemverilog
// 디버그 트레이스에서도 response는 "Rd Rsp"만 존재
`TRACE(2, ("%t: MEM Rd Rsp[%0d]: data=0x%h, tag=0x%0h (#%0d)\n", ...))
```

- 외부 메모리에서 들어오는 `mem_rsp_valid`은 **read 응답만** 기대
- 성능 카운터에서도 `perf_mem_pending_reads`로 read 요청만 추적:

```systemverilog
perf_mem_pending_reads <= $signed(perf_mem_pending_reads) +
    PERF_CTR_BITS'($signed(perf_mem_reads - perf_mem_rsps));
```

---

## 요약 테이블

| 모듈 | Write Request 생성 | Write Response |
|---|---|---|
| **VX_cache_bank** | Writethrough: hit/miss 모두 `mreq_queue`에 push | **없음** (read hit만 `crsp_queue`로 전달) |
| **VX_local_mem** | SRAM에 직접 write | **없음** (`~rw`일 때만 `rsp_valid`) |
| **VX_mem_scheduler** | `mem_req_rw=1`로 하위 전달 | **추적 안함** (`ibuf`에 미등록) |
| **VX_lsu_slice** | `lsu_mem_if`에 store 요청 | **즉시 완료** (`no_rsp_buf` 경로) |
| **VX_cache_bypass** | word→line 변환 후 메모리에 전달 | 외부도 write response 미전송 |
| **Vortex.sv** | `mem_req_rw`로 외부 전달 | read 응답만 수신 |

---

## 데이터 경로 다이어그램

```
[Store 명령어]
    │
    ▼
VX_lsu_slice
    ├─ mem_req_rw=1 → VX_mem_scheduler → lsu_mem_if → DCache/LMEM
    │                  (ibuf에 미등록, response 추적 안함)
    │
    └─ no_rsp_buf → result_no_rsp_if ──┐
                                        ├─ rsp_arb → pipeline 완료 (wb=0)
              result_rsp_if (read) ─────┘

[Cache 내부]
    │
    ▼
VX_cache_bank
    ├─ Write Hit (WT): 캐시 갱신 + mreq_queue → 메모리 write (response 없음)
    ├─ Write Hit (WB): 캐시 갱신 + dirty bit (메모리 접근 없음)
    ├─ Write Miss (WT): MSHR 할당 + 메모리 write (response 없음)
    └─ Write Miss (WB): MSHR 할당 + fill 요청 → fill 후 replay → 캐시 기록 (response 없음)
```

---

## 설계 의의

1. **Pipeline 효율**: Store는 `no_rsp_buf`로 즉시 retire하여 pipeline stall 최소화
2. **메모리 대역폭**: Write에 대한 ACK를 기다리지 않아 요청 throughput 극대화
3. **하드웨어 절약**: Write response 처리 로직/큐 불필요
4. **일관성 보장**: Writethrough 모드에서는 write가 메모리에 도달하면 자동으로 일관성 유지. Writeback 모드에서는 dirty bit + eviction으로 보장
