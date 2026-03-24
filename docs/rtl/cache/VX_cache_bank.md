# `VX_cache_bank.sv` — 캐시 뱅크 상세 분석

파일: `hw/rtl/cache/VX_cache_bank.sv`

## 1. 역할

`VX_cache_bank`는 캐시의 핵심 데이터경로로, **3-stage 파이프라인**을 통해 tag lookup, data access, response/miss 처리를 수행합니다. 각 뱅크는 독립적으로 동작하며, 뱅크 내부에 태그 저장소, 데이터 저장소, MSHR, 교체 정책, flush 상태 머신을 모두 포함합니다.

## 2. 주요 파라미터

| 파라미터 | 설명 |
|----------|------|
| `BANK_ID` | 이 뱅크의 고유 ID (주소 복원에 사용) |
| `CACHE_SIZE`, `LINE_SIZE`, `NUM_BANKS`, `NUM_WAYS`, `WORD_SIZE` | 캐시 기하 |
| `CRSQ_SIZE` | Core Response Queue 크기 |
| `MSHR_SIZE` | MSHR 엔트리 수 |
| `MREQ_SIZE` | Memory Request Queue 크기 |
| `WRITE_ENABLE`, `WRITEBACK`, `DIRTY_BYTES` | 쓰기 정책 |
| `REPL_POLICY` | 교체 정책 |

## 3. 인터페이스

### Core Request (입력)
- `core_req_valid`: 요청 유효
- `core_req_addr`: 라인 주소 (`CS_LINE_ADDR_WIDTH`)
- `core_req_rw`: read(0) / write(1)
- `core_req_wsel`: 라인 내 워드 선택
- `core_req_byteen`: 바이트 enable
- `core_req_data`: 쓰기 데이터
- `core_req_tag`, `core_req_idx`: 요청 식별자
- `core_req_ready`: backpressure

### Core Response (출력)
- `core_rsp_valid`, `core_rsp_data`, `core_rsp_tag`, `core_rsp_idx`

### Memory Request (출력)
- `mem_req_valid`, `mem_req_addr`, `mem_req_rw`, `mem_req_byteen`, `mem_req_data`, `mem_req_tag`

### Memory Response (입력)
- `mem_rsp_valid`, `mem_rsp_data`, `mem_rsp_tag`

### Flush
- `flush_begin` (input), `flush_end` (output), `flush_uuid`

### Status
- `drain`: 뱅크에 pending 작업이 없음

## 4. 3-Stage 파이프라인 상세

### 4.0 입력 선택 (Input Arbitration)

5종류의 입력 소스가 있으며, **우선순위가 정해져 있습니다**:

```
Priority (높 → 낮):
  1. init_valid    — 리셋 후 태그/데이터 초기화
  2. replay_valid  — MSHR replay (fill 후 재실행, 반드시 hit)
  3. mem_rsp_valid — 메모리 fill 응답
  4. flush_valid   — flush 순회
  5. core_req_valid — 일반 코어 요청
```

각 소스의 grant 조건:
```systemverilog
replay_grant = ~init_valid;
fill_grant   = ~init_valid && ~replay_enable;
flush_grant  = ~init_valid && ~replay_enable && ~fill_enable;
creq_grant   = ~init_valid && ~replay_enable && ~fill_enable && ~flush_enable;
```

추가 차단 조건:
- **replay**: write-through 모드에서 write replay 시 `mreq_queue_alm_full`이면 차단
- **fill (mem_rsp)**: writeback 모드에서 `mreq_queue_alm_full`이면 차단 (eviction writeback 필요), replay가 진행중이면 차단
- **flush**: writeback 모드에서 `mreq_queue_alm_full`이면 차단
- **core_req**: `mreq_queue_alm_full` 또는 `mshr_alm_full`이면 차단
- **공통**: `crsp_queue_stall` (Core Response Queue full)이면 전체 stall

선택된 입력의 데이터가 mux를 통해 `*_sel` 신호로 결합됩니다:
```systemverilog
addr_sel = init/flush ? flush_sel : replay ? replay_addr : mem_rsp ? mem_rsp_addr : core_req_addr;
rw_sel   = replay ? replay_rw : core_req_rw;
data_sel = replay ? replay_data : mem_rsp ? mem_rsp_data : core_req_data;
// 등...
```

### 4.1 Stage 0: Tag Lookup + MSHR Allocate

`pipe_reg0`을 통해 선택된 입력이 Stage 0 레지스터에 저장됩니다.

**Tag Lookup** (`VX_cache_tags`):
```systemverilog
VX_cache_tags cache_tags (
    .init       (do_init_st0),
    .flush      (do_flush_st0),
    .fill       (do_fill_st0),
    .read       (do_read_st0),
    .write      (do_write_st0),
    .line_idx   (line_idx_st0),       // 현재 요청의 라인 인덱스
    .line_idx_n (line_idx_sel),       // 다음 사이클 요청의 라인 인덱스 (read-first RAM용)
    .line_tag   (line_tag_st0),       // 비교할 태그
    .evict_way  (evict_way_st0),      // eviction 대상 way
    .tag_matches(tag_matches_st0),    // [NUM_WAYS-1:0] 각 way 매칭 결과
    .evict_dirty(is_dirty_st0),       // evict 대상이 dirty인지
    .evict_tag  (evict_tag_st0)       // evict 대상의 태그
);
```

**Hit 판정**:
```systemverilog
is_hit_st0 = (| tag_matches_st0);                  // any way matches
hit_idx_st0 = VX_onehot_encoder(tag_matches_st0);  // matching way index
way_idx_st0 = is_creq_st0 ? hit_idx_st0 : evict_way_st0;
```

**Replacement Policy** (`VX_cache_repl`):
```systemverilog
VX_cache_repl cache_repl (
    .lookup_valid (do_lookup_st1 && ~pipe_stall),  // hit 시 LRU 업데이트 (Stage 1에서)
    .lookup_hit   (is_hit_st1),
    .lookup_line  (line_idx_st1),
    .lookup_way   (way_idx_st1),
    .repl_valid   (do_fill_st0 && ~pipe_stall),    // fill 시 victim way 선택 (Stage 0에서)
    .repl_line    (line_idx_st0),
    .repl_way     (victim_way_st0)                  // 선택된 victim way
);
```

**MSHR Allocate**:
- 새로운 코어 요청(replay가 아닌)에 대해 MSHR 슬롯을 미리 할당
- `mshr_pending_st0`: 같은 라인에 이미 pending 중인 요청이 있는지
- `mshr_previd_st0`: pending chain의 이전 엔트리 ID

### 4.2 Stage 1: Data Access + MSHR Finalize

`pipe_reg1`을 통해 Stage 0의 결과가 Stage 1 레지스터에 전달됩니다.

**Data Access** (`VX_cache_data`):
```systemverilog
VX_cache_data cache_data (
    .fill       (do_fill_st1),            // fill 데이터 쓰기
    .read       (do_read_st1),            // 데이터 읽기
    .write      (do_write_st1),           // 워드 쓰기
    .evict_way  (way_idx_st1),            // fill 시 evict 대상 way
    .tag_matches(tag_matches_st1),        // write 시 hit한 way에만 쓰기
    .fill_data  (data_st1),               // fill 데이터 (전체 라인)
    .write_word (write_word_st1),         // write 데이터 (한 워드)
    .word_idx   (word_idx_st1),           // 워드 선택
    .write_byteen(byteen_st1),            // 바이트 enable
    .way_idx_r  (way_idx_st2),            // 읽기 way 선택 (Stage 2에서 사용)
    .read_data  (read_data_st2),          // 읽기 결과 (Stage 2에서 사용)
    .evict_byteen(evict_byteen_st2)       // evict 시 dirty bytes
);
```

**MSHR Finalize**:
```systemverilog
// 새로운 코어 요청(replay 아닌)에 대해:
mshr_finalize_st1 = valid_st1 && is_creq_st1 && ~is_replay_st1;

// Hit이면 MSHR 엔트리 release (더 이상 miss 처리 불필요)
// Write-through: hit이거나 (write이고 pending 없음)이면 release
mshr_release_st1 = WRITEBACK ? is_hit_st1 : (is_hit_st1 || (rw_st1 && ~mshr_pending_st1));
```

**Replay 검증**:
```systemverilog
// replay는 fill 후에 발생하므로 반드시 hit해야 함
`RUNTIME_ASSERT (~(valid_st1 && is_replay_st1 && ~is_hit_st1), ("missed mshr replay"))
```

### 4.3 Stage 2: Response + Memory Request 생성

`pipe_reg2`를 통해 Stage 1의 결과가 Stage 2 레지스터에 전달됩니다.

**Core Response 생성**:
```systemverilog
// Read hit이면 core response 생성
crsp_queue_valid = do_read_st2 && is_hit_st2;
crsp_queue_data  = read_data_st2[word_idx_st2];  // 해당 워드 선택
crsp_queue_tag   = tag_st2;

VX_elastic_buffer #(.SIZE(CRSQ_SIZE)) core_rsp_queue (...);
```

**Memory Request 생성** (Writeback 모드):
```systemverilog
// miss 시 fill request 또는 dirty eviction 시 writeback
mreq_queue_push = ((do_lookup_st2 && ~is_hit_st2 && ~mshr_pending_st2)  // miss (pending 아님)
                 || do_writeback_st2)                                    // dirty eviction
               && ~pipe_stall;

mreq_queue_addr = is_fill_or_flush_st2 ? evict_addr_st2 : addr_st2;  // writeback은 evict 주소
mreq_queue_rw   = is_fill_or_flush_st2;                               // writeback은 write
mreq_queue_data = read_data_st2;                                      // dirty 데이터
```

**Memory Request 생성** (Write-Through 모드):
```systemverilog
// read miss 시 fill request 또는 모든 write 시 memory write
mreq_queue_push = ((do_read_st2 && ~is_hit_st2 && ~mshr_pending_st2)  // read miss
                || do_write_st2)                                       // 모든 write
               && ~pipe_stall;

mreq_queue_rw   = rw_st2;                            // read miss → read, write → write
mreq_queue_data = {CS_WORDS_PER_LINE{write_word_st2}};  // write 데이터 복제
mreq_queue_byteen = rw_st2 ? line_byteen : '1;       // write는 해당 바이트만, read는 전체
```

**Memory Request Queue**:
```systemverilog
VX_fifo_queue #(
    .DEPTH    (MREQ_SIZE),
    .ALM_FULL (MREQ_SIZE - PIPELINE_STAGES)  // 파이프라인 깊이만큼 여유
) mem_req_queue (...);
```

## 5. MSHR 상호작용 상세

```
Core Request → Stage 0: MSHR allocate (mshr_allocate_st0)
                         - 슬롯 할당, pending 여부 확인
             → Stage 1: MSHR finalize (mshr_finalize_st1)
                         - Hit: release (슬롯 반환)
                         - Miss: persist (슬롯 유지, pending chain 연결)

Memory Fill → Stage 0: MSHR에 fill_valid + fill_id 전달
                       → MSHR가 dequeue 시작 (replay_valid)
                       → replay 요청이 파이프라인 입력으로 들어감
             → replay는 반드시 hit → Stage 2에서 core response 생성
             → MSHR에서 다음 pending 엔트리 dequeue (linked list 순회)
```

## 6. Flush 처리 흐름

```systemverilog
VX_cache_flush cache_flush (
    .flush_begin (flush_begin),     // VX_cache_init에서 trigger
    .flush_end   (flush_end),       // 완료 시 signal
    .flush_init  (init_valid),      // 리셋 시 초기화 모드
    .flush_valid (flush_valid),     // flush 순회 중
    .flush_line  (flush_sel),       // 현재 순회 중인 라인
    .flush_way   (flush_way),       // 현재 순회 중인 way (writeback 모드)
    .flush_ready (flush_ready),     // 뱅크가 flush를 수락할 수 있는지
    .mshr_empty  (mshr_empty),      // MSHR이 비었는지 (flush 시작 조건)
    .bank_empty  (no_pending_req)   // 뱅크에 pending 요청 없는지
);
```

## 7. Drain 판정

```systemverilog
wire no_pending_req = ~valid_st0 && ~valid_st1 && ~valid_st2 && mreq_queue_empty;

wire bank_drain_pending = init_valid || flush_valid || core_req_valid
                       || replay_valid || mem_rsp_valid
                       || valid_st0 || valid_st1 || valid_st2
                       || core_rsp_valid || ~mshr_empty || ~mreq_queue_empty;

assign drain = ~bank_drain_pending;
```

## 8. 파이프라인 타이밍 다이어그램

```
Cycle:    0          1          2          3
          ┌──────┐   ┌──────┐   ┌──────┐
Input  →  │ St 0 │ → │ St 1 │ → │ St 2 │ → Output
Select    │Tag   │   │Data  │   │Resp  │
          │Lookup│   │Access│   │Gen   │
          └──────┘   └──────┘   └──────┘

St 0: - tag_matches (VX_cache_tags)
      - is_hit, way_idx
      - MSHR allocate
      - replacement way (VX_cache_repl → victim_way)

St 1: - data read/write (VX_cache_data)
      - MSHR finalize (release on hit / persist on miss)
      - PLRU update (VX_cache_repl → lookup_valid)

St 2: - core_rsp_queue enqueue (read hit)
      - mem_req_queue enqueue (miss fill request / writeback / writethrough)
```

## 9. 주요 설계 결정

1. **MSHR Pre-allocation**: 코어 요청 진입 시(Stage 0) MSHR을 미리 할당하고, hit이면 Stage 1에서 반환. 이는 MSHR full 상태에서 파이프라인에 진입하는 것을 방지합니다.

2. **Fill 후 Replay 보장**: fill 응답이 도착하면 MSHR의 pending 요청들이 replay됩니다. replay는 fill로 태그가 이미 설정되었으므로 반드시 hit합니다.

3. **Backpressure 전파**: `crsp_queue_stall`이 발생하면 전체 파이프라인이 stall합니다. `mreq_queue_alm_full`은 파이프라인 깊이(3)만큼의 여유를 두어, in-flight 요청이 모두 완료되어도 큐가 넘치지 않도록 합니다.

4. **Write-Through vs Writeback 차이**:
   - Write-Through: 모든 write가 즉시 메모리에도 전송, miss 시 write는 MSHR에 저장하지 않을 수 있음
   - Writeback: write는 캐시에만 기록(dirty 설정), eviction 시에만 메모리에 기록
