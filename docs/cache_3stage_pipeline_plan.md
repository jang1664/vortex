# Cache Bank 3-Stage Pipeline Plan

## Goal

2-stage의 기능/순서를 최대한 유지하면서, `tag_matches -> data line_write` critical path를 끊기 위해 data array access를 st1로 이동하고, 기존 st1 side-effect 중 응답/mreq 발행을 st2로 이동한다.

핵심 원칙:
- 외부 인터페이스 불변
- 2-stage 대비 latency만 +1 cycle
- st1/st2 혼합 mreq 발행 금지 (충돌 구조 제거)

## Scope

변경 파일:
1. `hw/rtl/cache/VX_cache_bank.sv`
2. `docs/cache_3stage_pipeline_plan.md`

비변경:
- `hw/rtl/cache/VX_cache_data.sv` 모듈 포트/내부 로직 (bank 연결 stage만 변경)

## Stage Contract

1. st0: 입력 arbitration + tag lookup 입력 준비
2. st1: tag hit/way 확정 + data array read/write 실행
3. st2: core response 생성 + mreq push
4. st1: mshr finalize/release 유지 (MSHR dequeue 체인 결합 보존)

## RTL Design

### 1) Pipeline depth
- `PIPELINE_STAGES = 3`

### 2) Stage signals
- st2 신호 추가:
  - `valid_st2`, `is_creq_st2`, `is_fill_st2`, `is_flush_st2`, `is_replay_st2`
  - `is_hit_st2`, `is_dirty_st2`, `rw_st2`, `flags_st2`
  - `way_idx_st2`, `line_idx_st2`, `line_tag_st2`, `evict_tag_st2`
  - `word_idx_st2`, `byteen_st2`, `tag_st2`, `req_idx_st2`
  - `mshr_id_st2`, `mshr_previd_st2`, `mshr_pending_st2`, `data_st2`
  - `req_uuid_st2`, `addr_st2`, `write_word_st2`

### 3) pipe_reg1 확장 (st0 -> st1)
- 추가 전달:
  - `is_init_st0 -> is_init_st1`
  - `tag_matches_st0 -> tag_matches_st1`
- 목적:
  - st1에서 data write enable/mask/data/way를 같은 stage로 정렬

### 4) pipe_reg2 신설 (st1 -> st2)
- old st1 side-effect용 필드를 그대로 전달:
  - `valid, is_fill, is_flush, is_creq, is_replay, is_dirty, is_hit, rw, flags`
  - `way_idx, evict_tag, line_tag, line_idx`
  - `data, byteen, word_idx, req_idx, tag`
  - `mshr_id, mshr_previd, mshr_pending`

### 5) cache_data 연결 stage 이동
- 입력: st1 기준으로 통일
  - `init/fill/flush/read/write/evict_way/tag_matches/line_idx/fill_data/write_word/word_idx/write_byteen`
- `way_idx_r = way_idx_st2`
- 출력명:
  - `read_data_st2`, `evict_byteen_st2`

### 6) Core response st2 이동
- `crsp_queue_valid = do_read_st2 && is_hit_st2`
- `crsp_queue_data  = read_data_st2[word_idx_st2]`
- `crsp_queue_idx/tag = req_idx_st2/tag_st2`

### 7) MREQ 발행 st2 단일화 (모든 모드)
- WRITEBACK:
  - `miss push = do_lookup_st2 && ~is_hit_st2 && ~mshr_pending_st2`
  - `wb push   = do_fill_or_flush_st2 && is_dirty_st2`
  - `addr/rw/data/byteen` 모두 st2 기준 (`read_data_st2`, `evict_byteen_st2`)
- WRITETHROUGH:
  - `((do_read_st2 && miss && ~pending) || do_write_st2)`
  - `line_byteen` demux 입력: `word_idx_st2/byteen_st2`
- READONLY:
  - read miss push를 st2에서 발행
- 공통:
  - `mreq_queue_tag`는 st2 (`{req_uuid_st2, mshr_id_st2}` 또는 `mshr_id_st2`)
  - `mreq_queue_flags = flags_st2`

### 8) MSHR finalize/release st1 유지
- `mshr_finalize_st1 = valid_st1 && is_creq_st1 && ~is_replay_st1`
- `mshr_release_st1`는 기존 식 유지 (입력 st1)
- `cache_mshr.fin_req_uuid = req_uuid_st1`
- `cache_mshr.finalize_*` 입력은 st1 유지
- 이유: `VX_cache_mshr`의 `dequeue_fire`와 `finalize_is_pending` 동일-cycle 결합(연결 리스트 체인) 보존 필요

### 9) Flush/Drain/Backpressure 정합성
- `no_pending_req`에 `~valid_st2` 추가
- `bank_drain_pending`에 `valid_st2` 추가
- `pipe_stall = crsp_queue_stall` 유지
- writeback push를 stall 조건에 OR하지 않음 (조합루프 금지)

### 10) Assertion/Perf/Trace
- DIRTY_BYTES assertion을 st2 기반으로 이동
- `PERF_ENABLE` miss 카운터를 st2로 이동
- `DBG_TRACE_CACHE`:
  - `data-read`, `core-rd-rsp`, `writethrough`, `fill-req`, `writeback`은 st2 기준
  - `data-write`는 st1 유지

## 2-stage vs 3-stage Timeline

- read hit rsp: `st1 -> st2`
- miss fill req: `st1 -> st2`
- write-through req: `st1 -> st2`
- writeback req: `st1 -> st2`

## Validation Checklist

1. cache_top unit test (WRITEBACK on/off, DIRTY_BYTES on/off)
2. read-hit + core_rsp backpressure 반복 시 정합성
3. write-hit/read-hit 교차 최신값 보장
4. fill 직후 replay/read에서 stale read 부재
5. WRITEBACK dirty eviction 연속 시 mreq 단일 push 보장
6. flush 중 pending 존재 시 조기 flush_end 부재
7. `vecadd_multi_invoke` 반복 + 랜덤 입력 + DRAM `0xDEADBEAF` init
8. 200/300MHz 합성 후 tag->data 경로 완화 확인
9. WNS/TNS, failing endpoints 전후 비교
10. lint/compile 신규 warning 여부 확인

## Assumptions

1. 목표는 기능 동일성 + latency +1 cycle
2. throughput 저하는 허용하지 않음
3. 외부 인터페이스는 변경하지 않음
4. replacement policy 의미는 유지하고 stage alignment만 조정
