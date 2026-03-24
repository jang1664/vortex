# Vortex Cache System Overview

## 1. 모듈 계층 구조

```
VX_cache_cluster          (최상위: 여러 캐시 유닛을 묶어 클러스터링)
  └─ VX_cache_wrap  [x NUM_CACHES]   (캐시 래퍼: bypass/passthru + 실제 캐시)
       ├─ VX_cache_bypass             (non-cacheable 주소 우회 처리)
       └─ VX_cache                    (코어 캐시: request dispatch + bank 관리 + response gather)
            ├─ VX_cache_init          (초기화 및 flush 요청 감지/제어)
            ├─ VX_stream_xbar         (core request → bank 분배 crossbar)
            ├─ VX_cache_bank  [x NUM_BANKS]  (뱅크: 3-stage 파이프라인)
            │    ├─ VX_cache_flush    (flush 상태 머신)
            │    ├─ VX_cache_tags     (태그 저장 및 비교)
            │    ├─ VX_cache_data     (데이터 저장)
            │    ├─ VX_cache_repl     (교체 정책: PLRU / FIFO / Random)
            │    └─ VX_cache_mshr     (Miss Status Holding Register)
            ├─ VX_stream_xbar         (bank → core response 수집 crossbar)
            └─ VX_stream_arb          (bank → memory request 중재)

VX_cache_top              (Verilog wrapper: 포트 레벨 인터페이스 → VX_cache_wrap)
```

## 2. 핵심 모듈 목록 및 역할 요약

| 모듈 | 파일 | 역할 |
|------|------|------|
| `VX_cache_cluster` | `VX_cache_cluster.sv` | 여러 캐시 유닛을 묶고, 코어 입력을 각 유닛에 분배/중재 |
| `VX_cache_wrap` | `VX_cache_wrap.sv` | bypass/passthru 옵션을 관리하고 실제 캐시를 인스턴스화 |
| `VX_cache_bypass` | `VX_cache_bypass.sv` | non-cacheable 주소(IO 영역)를 캐시를 거치지 않고 메모리로 직접 전달 |
| `VX_cache` | `VX_cache.sv` | 캐시 본체: request dispatch crossbar, bank 인스턴스화, response gather, 성능 카운터 |
| `VX_cache_bank` | `VX_cache_bank.sv` | 3-stage 파이프라인 뱅크: tag lookup → data access → response/miss 처리 |
| `VX_cache_tags` | `VX_cache_tags.sv` | per-way 태그 저장소: valid/dirty/tag 비교 |
| `VX_cache_data` | `VX_cache_data.sv` | per-way 데이터 SRAM: fill/read/write 처리 |
| `VX_cache_mshr` | `VX_cache_mshr.sv` | Miss Status Holding Register: miss 시 요청 저장, fill 후 replay |
| `VX_cache_repl` | `VX_cache_repl.sv` | 교체 정책 (Pseudo-LRU, FIFO, Random) |
| `VX_cache_flush` | `VX_cache_flush.sv` | flush 상태 머신: 모든 라인을 순회하며 invalidate (writeback 시 dirty 라인 기록) |
| `VX_cache_init` | `VX_cache_init.sv` | flush 요청 감지, in-flight 요청 대기, flush 시퀀스 관리 |
| `VX_cache_top` | `VX_cache_top.sv` | 포트 레벨 Verilog wrapper (VX_mem_bus_if 인터페이스 ↔ 개별 wire) |
| `VX_cache_define.vh` | `VX_cache_define.vh` | 캐시 시스템 공통 매크로 정의 |

## 3. 주소 구조 (Address Decomposition)

캐시 시스템은 워드 주소(`CS_WORD_ADDR_WIDTH`)를 다음과 같이 분해합니다:

```
  [CS_WORD_ADDR_WIDTH-1 : 0]
  ┌──────────────┬───────────────┬──────────────┬──────────────┐
  │   TAG        │  LINE_SEL     │  BANK_SEL    │  WORD_SEL    │
  │  (상위 비트) │  (라인 인덱스)│  (뱅크 선택) │  (워드 선택) │
  └──────────────┴───────────────┴──────────────┴──────────────┘
```

- **WORD_SEL**: `CLOG2(LINE_SIZE / WORD_SIZE)` 비트 — 캐시 라인 내 워드 선택
- **BANK_SEL**: `CLOG2(NUM_BANKS)` 비트 — 어떤 뱅크에 매핑되는지
- **LINE_SEL**: `CLOG2(LINES_PER_BANK)` 비트 — 뱅크 내 라인 인덱스 (set index)
- **TAG**: 나머지 상위 비트 — 태그 비교에 사용

## 4. 데이터 흐름 개요

### 4.1 Read Hit 경로
```
Core Request → VX_cache_init (flush 여부 확인)
  → core_req_xbar (NUM_REQS → NUM_BANKS 분배)
  → VX_cache_bank (Stage 0: tag lookup → hit 판정)
    → VX_cache_tags: tag 비교, tag_matches 출력
    → VX_cache_repl: replacement 정보 업데이트
  → VX_cache_bank (Stage 1: data read)
    → VX_cache_data: SRAM 읽기
  → VX_cache_bank (Stage 2: response 생성)
    → core_rsp_queue에 enqueue
  → core_rsp_xbar (NUM_BANKS → NUM_REQS 수집)
  → Core Response
```

### 4.2 Read Miss 경로
```
Core Request → ... → VX_cache_bank (Stage 0: tag miss)
  → VX_cache_mshr: MSHR에 요청 할당 (allocate)
  → VX_cache_bank (Stage 2: miss 확인)
    → mem_req_queue에 fill request enqueue
  → mem_req_arb (NUM_BANKS → MEM_PORTS 중재)
  → Memory Request 전송

Memory Response 도착:
  → mem_rsp_queue (MRSQ)
  → mem_rsp_xbar (MEM_PORTS → NUM_BANKS 분배)
  → VX_cache_bank: fill 처리
    → VX_cache_tags: tag 갱신 (valid 설정, 새 tag 기록)
    → VX_cache_data: fill data 기록
    → VX_cache_mshr: dequeue → replay 시작
      → MSHR에 저장된 요청을 다시 파이프라인에 투입 (replay)
      → 이번엔 반드시 hit → Core Response 전송
```

### 4.3 Write 경로 (Write-Through)
```
Core Write Request → ... → VX_cache_bank (Stage 0: tag lookup)
  - Hit: data write + memory write (write-through이므로 항상 메모리에도 기록)
  - Miss: MSHR에 저장하지 않고(pending이 없으면) 바로 memory write 전송
```

### 4.4 Write 경로 (Write-Back)
```
Core Write Request → ... → VX_cache_bank (Stage 0: tag lookup)
  - Hit: data write, dirty bit 설정 (메모리에 즉시 기록하지 않음)
  - Miss: MSHR 할당 → fill request → fill 완료 후 replay → data write + dirty 설정
  - Eviction 시: dirty 라인은 writeback (mem_req_queue를 통해 메모리에 기록)
```

### 4.5 Flush 경로
```
Flush 요청 (MEM_REQ_FLAG_FLUSH) 감지:
  → VX_cache_init: in-flight 요청 대기 → flush_begin 신호 발생
  → VX_cache_flush (각 bank):
    STATE_INIT → STATE_WAIT1 (MSHR empty 대기) → STATE_FLUSH (모든 라인 순회)
    → Writeback 모드: dirty 라인 writeback 후 invalidate
    → Write-through 모드: 단순 invalidate
    → STATE_DONE → flush_end 신호
  → VX_cache_init: 모든 bank flush_end 수신 → flush 요청을 core로 release
```

## 5. 핵심 설계 패턴

### 5.1 Banked 구조
캐시는 `NUM_BANKS`개의 독립적인 뱅크로 분할됩니다. 주소의 BANK_SEL 비트로 요청이 어떤 뱅크에 가는지 결정됩니다. 서로 다른 뱅크에 대한 요청은 동시에 처리 가능하여 throughput을 높입니다.

### 5.2 3-Stage Pipeline (Bank 내부)
각 뱅크는 3단계 파이프라인으로 동작합니다:
- **Stage 0 (pipe_reg0)**: 입력 선택 + Tag Lookup + MSHR 할당
- **Stage 1 (pipe_reg1)**: Data SRAM 접근 + MSHR finalize
- **Stage 2 (pipe_reg2)**: Response 생성 + Memory Request 생성

### 5.3 입력 우선순위 (Bank Input Arbitration)
뱅크 입력은 다음 우선순위로 처리됩니다 (높은 것이 우선):
1. **Init**: 리셋 후 태그/데이터 초기화
2. **Replay**: MSHR에서 dequeue된 replay 요청 (fill 후 반드시 hit하므로 최우선)
3. **Fill**: 메모리 응답 (fill) — deadlock 방지를 위해 core request보다 우선
4. **Flush**: flush 순회 — 캐시 일관성 보장을 위해 core request보다 우선
5. **Core Request**: 실제 코어 요청

### 5.4 MSHR (Miss Status Holding Register)
- Miss 발생 시 요청 정보를 MSHR에 저장
- 같은 캐시 라인에 대한 여러 miss는 linked list로 연결 (next_index)
- Memory fill 완료 시 linked list를 따라 모든 pending 요청을 순서대로 replay
- Replay 요청은 반드시 hit해야 함 (RUNTIME_ASSERT로 검증)

### 5.5 Backpressure 제어
- `crsp_queue_stall`: Core Response Queue가 가득 차면 파이프라인 전체 stall
- `mreq_queue_alm_full`: Memory Request Queue가 거의 차면 새로운 core request/fill 차단
- `mshr_alm_full`: MSHR이 거의 차면 새로운 core request 차단

## 6. 파라미터 조합에 따른 동작 변화

| 파라미터 조합 | 동작 |
|---------------|------|
| `PASSTHRU=1` | 캐시 없이 모든 요청을 bypass로 메모리 직접 접근 |
| `NC_ENABLE=1` | IO 영역 주소는 bypass, 나머지는 캐시 |
| `WRITEBACK=1` | dirty 라인은 eviction 시에만 메모리 기록 |
| `WRITEBACK=0` | 모든 write는 즉시 메모리에도 기록 (write-through) |
| `DIRTY_BYTES=1` | dirty byte 단위 추적 (partial writeback 지원) |
| `WRITE_ENABLE=0` | read-only 캐시 (instruction cache 등) |
| `NUM_BANKS=1` | 단일 뱅크 (crossbar 불필요) |
| `NUM_WAYS=1` | direct-mapped 캐시 |

---
다음 문서: 각 모듈의 상세 분석 → `VX_cache_bank.md`, `VX_cache_mshr.md`, `VX_cache_data.md`, `VX_cache_repl.md`, `VX_cache_flush.md`, `VX_cache_init.md`, `VX_cache_bypass.md`, `VX_cache_cluster.md`
