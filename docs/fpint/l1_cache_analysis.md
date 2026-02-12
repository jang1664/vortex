# Vortex L1 Cache 시스템 분석

## 1. 전체 계층 구조

```
VX_cluster
 └── VX_socket (per socket)
      ├── ICache (VX_cache_cluster → VX_cache_wrap → VX_cache → VX_cache_bank)
      ├── DCache (VX_cache_cluster → VX_cache_wrap → VX_cache → VX_cache_bank)
      ├── L1 mem_arb (icache + dcache → L2로 향하는 단일 포트)
      └── VX_core (per core)
           ├── icache_bus_if → ICache로 연결
           ├── dcache_bus_if → DCache로 연결 (VX_mem_unit 경유)
           └── VX_mem_unit
                ├── VX_lmem_switch: LMEM/Global/DMA/GEMM 주소 분기
                ├── VX_mem_coalescer: LSU lane → dcache word 크기 변환
                ├── VX_lsu_adapter: multi-lane → 개별 mem_bus_if 변환
                └── DMA arbiter: DMA global traffic을 dcache channel 0에 합류
```

### 모듈별 역할 요약

| 모듈 | 파일 | 역할 |
|---|---|---|
| `VX_cluster` | `hw/rtl/VX_cluster.sv` | 여러 소켓을 묶고 L2 캐시 인스턴스 포함 |
| `VX_socket` | `hw/rtl/VX_socket.sv` | **L1 ICache/DCache 인스턴스**를 포함, 여러 코어 묶음 |
| `VX_core` | `hw/rtl/core/VX_core.sv` | 파이프라인 코어, 캐시 포트만 외부로 노출 |
| `VX_mem_unit` | `hw/rtl/core/VX_mem_unit.sv` | LSU 요청 → DCache 포트 변환, LMEM 분기, DMA 합류 |
| `VX_cache_cluster` | `hw/rtl/cache/VX_cache_cluster.sv` | 여러 코어의 요청을 여러 캐시 유닛에 분배 |
| `VX_cache_wrap` | `hw/rtl/cache/VX_cache_wrap.sv` | NC 바이패스 + 실제 캐시 감싸기 |
| `VX_cache` | `hw/rtl/cache/VX_cache.sv` | multi-bank 캐시: request xbar + bank + response gather |
| `VX_cache_bank` | `hw/rtl/cache/VX_cache_bank.sv` | **캐시 뱅크 코어 로직** (2-stage pipeline) |

---

## 2. VX_core.sv에서 L1 캐시 연결

`VX_core.sv` 자체에는 **캐시 인스턴스가 없다**. 두 개의 인터페이스 포트를 외부(`VX_socket`)로 노출:

| 포트 | 방향 | 설명 |
|---|---|---|
| `icache_bus_if` | master (1개) | `VX_fetch` → ICache 명령어 페치 |
| `dcache_bus_if [DCACHE_NUM_REQS]` | master (N개) | `VX_mem_unit` → DCache 데이터 로드/스토어 |

### 데이터 경로

```
VX_execute → VX_lsu (Load/Store Unit)
  → lsu_mem_if [NUM_LSU_BLOCKS]
  → VX_mem_unit
    → dcache_bus_if [DCACHE_NUM_REQS]
    → (VX_socket의 DCache로 연결)
```

---

## 3. VX_socket.sv에서의 L1 캐시 인스턴스

### 3.1 ICache

```systemverilog
VX_cache_cluster #(
    .CACHE_SIZE     (`ICACHE_SIZE),       // 캐시 전체 크기 (bytes)
    .LINE_SIZE      (ICACHE_LINE_SIZE),   // 캐시라인 크기 (bytes)
    .NUM_BANKS      (1),                  // 뱅크 1개 (단순)
    .NUM_WAYS       (`ICACHE_NUM_WAYS),   // N-way set associative
    .WORD_SIZE      (ICACHE_WORD_SIZE),   // 워드 크기
    .NUM_REQS       (1),                  // 코어당 요청 포트 1개
    .WRITE_ENABLE   (0),                  // ★ 읽기 전용
    .NC_ENABLE      (0),                  // non-cacheable 미지원
    .REPL_POLICY    (`ICACHE_REPL_POLICY)
) icache (
    .core_bus_if    (per_core_icache_bus_if),   // 각 코어의 fetch 요청
    .mem_bus_if     (icache_mem_bus_if)          // miss → L2/메모리
);
```

### 3.2 DCache

```systemverilog
VX_cache_cluster #(
    .CACHE_SIZE     (`DCACHE_SIZE),
    .LINE_SIZE      (DCACHE_LINE_SIZE),
    .NUM_BANKS      (`DCACHE_NUM_BANKS),   // ★ multi-bank
    .NUM_WAYS       (`DCACHE_NUM_WAYS),
    .WORD_SIZE      (DCACHE_WORD_SIZE),
    .NUM_REQS       (DCACHE_NUM_REQS),     // 코어당 여러 요청 포트
    .WRITE_ENABLE   (1),                    // ★ 읽기/쓰기
    .WRITEBACK      (`DCACHE_WRITEBACK),    // writeback 또는 writethrough
    .DIRTY_BYTES    (`DCACHE_DIRTYBYTES),
    .NC_ENABLE      (1),                    // ★ non-cacheable 바이패스 지원
    .REPL_POLICY    (`DCACHE_REPL_POLICY)
) dcache (
    .core_bus_if    (per_core_dcache_bus_if),   // 각 코어의 load/store
    .mem_bus_if     (dcache_mem_bus_if)          // miss → L2/메모리
);
```

### 3.3 L1 → L2 메모리 아비트레이션

ICache miss와 DCache miss는 `VX_mem_arb`로 합쳐져 L2로 전달:

```systemverilog
VX_mem_arb #(
    .NUM_INPUTS (2),        // [0]=icache, [1]=dcache
    .ARBITER    ("P"),      // ★ Priority: ICache 우선
) mem_arb (
    .bus_in_if  (l1_mem_bus_if),       // icache + dcache
    .bus_out_if (l1_mem_arb_bus_if)    // → L2 cache
);
```

---

## 4. VX_mem_unit: Core 내부 → DCache 경로

`VX_mem_unit`은 LSU의 메모리 요청을 DCache 포트 형식으로 변환하는 모듈.

### 4.1 주소 분기 (VX_lmem_switch)

```
lsu_mem_if (LSU에서 옴)
  ├─ [LMEM 주소 범위] → lsu_lmem_if → Local Memory (SRAM)
  ├─ [DMA 레지스터 주소] → dma_ctrl_if → DMA 설정 레지스터
  ├─ [GEMM 레지스터 주소] → gemm_ctrl_if → GEMM 설정 레지스터
  └─ [그 외 Global 주소] → lsu_dcache_if → DCache 경로
```

### 4.2 Coalescer (VX_mem_coalescer)

- LSU lane 수와 dcache word 크기가 다를 때 활성화
- 여러 lane의 요청을 더 큰 dcache word 단위로 합침 (coalescing)
- `NUM_LSU_LANES > 1 && LSU_WORD_SIZE != DCACHE_WORD_SIZE`일 때만 동작

### 4.3 LSU Adapter (VX_lsu_adapter)

- multi-lane 인터페이스 (`VX_lsu_mem_if`)를 개별 `VX_mem_bus_if`로 변환
- Priority arbiter로 lane 간 중재

### 4.4 DMA Arbiter

- DMA의 global memory 트래픽을 DCache channel 0에 합류:

```systemverilog
VX_mem_arb #(
    .NUM_INPUTS  (2),       // [0]=일반 dcache 트래픽, [1]=DMA global
    .ARBITER     ("P")      // Priority
) dcache_dma_arbiter (
    .bus_in_if  ({dcache_bus_tmp_if[0], dma_global_data_if}),
    .bus_out_if (dcache_bus_if[channel_0])
);
```

---

## 5. 캐시 내부 구조

### 5.1 VX_cache.sv: Multi-Bank 캐시 Top

```
core_bus_if [NUM_REQS]
  → VX_cache_init (flush 처리)
  → Request Crossbar (요청을 bank_sel로 분배)
  → VX_cache_bank [NUM_BANKS] (각 뱅크 독립 처리)
  → Memory Request Gather (뱅크→메모리 포트 합류)
  → Memory Response Scatter (메모리→뱅크 분배)
  → Core Response Gather (뱅크 응답→코어 포트 합류)
  → mem_bus_if [MEM_PORTS]
```

### 5.2 주소 분해 (VX_cache_define.vh)

```
Word Address [CS_WORD_ADDR_WIDTH-1 : 0]

┌─────────────┬──────────────┬──────────────┬──────────────┐
│   TAG        │  LINE_SEL    │  BANK_SEL    │  WORD_SEL    │
│ (tag 비교)   │ (set index)  │ (뱅크 선택)   │ (라인 내 워드)│
└─────────────┴──────────────┴──────────────┴──────────────┘
```

| 필드 | 비트 수 | 설명 |
|---|---|---|
| `WORD_SEL` | `log2(LINE_SIZE / WORD_SIZE)` | 캐시라인 내 워드 오프셋 |
| `BANK_SEL` | `log2(NUM_BANKS)` | 뱅크 인터리빙 선택 |
| `LINE_SEL` | `log2(LINES_PER_BANK)` | 뱅크 내 set 인덱스 |
| `TAG` | 나머지 | tag 비교 |

---

## 6. VX_cache_bank.sv: 캐시 뱅크 핵심 로직

### 6.1 2-Stage Pipeline

```
          ┌──────────────────┐     ┌──────────────────────────┐
  Input → │   Stage 0        │ → │   Stage 1                  │ → Output
  Select   │   Tag Lookup     │     │   Data Access + Response  │
          └──────────────────┘     └──────────────────────────┘
```

### 6.2 입력 우선순위 (높음 → 낮음)

| 순위 | 소스 | 설명 |
|---|---|---|
| 1 | **Init** | 캐시 초기화 (tag 무효화) |
| 2 | **MSHR Replay** | miss 후 fill 완료 → 재실행 (항상 hit) |
| 3 | **Memory Fill** | 메모리에서 들어온 fill 응답 |
| 4 | **Flush** | 캐시라인 무효화/writeback |
| 5 | **Core Request** | 일반 코어 load/store 요청 |

> **Replay**가 fill보다 높은 이유: MSHR replay는 이미 fill된 데이터를 읽으므로 항상 hit. utilization 극대화.
>
> **Fill**이 flush보다 높은 이유: 메모리 응답을 빨리 처리하지 않으면 deadlock 위험 (fill 미처리 중 miss 발생 시 메모리 요청 불가).

### 6.3 Stage 0: Tag Lookup

```systemverilog
VX_cache_tags    // tag 비교 → hit/miss 판단
  ├─ input:  line_idx, line_tag, evict_way
  ├─ output: tag_matches[NUM_WAYS] (어느 way가 hit인지)
  ├─ output: evict_dirty, evict_tag (evict 대상 정보)
  └─ 동작:
       - fill: tag 갱신 (새 태그 + valid 설정)
       - init/flush: tag 무효화
       - write (writeback): dirty bit 설정
```

```systemverilog
VX_cache_repl    // Replacement Policy
  ├─ 지원 정책: RANDOM, FIFO, PLRU (Pseudo-LRU)
  ├─ repl_valid: fill 시 victim way 선택
  └─ lookup_valid: hit 시 접근 기록 갱신 (LRU 갱신 등)
```

```systemverilog
VX_cache_mshr    // allocate: 새 core 요청에 MSHR 슬롯 할당
  ├─ allocate_pending: 같은 라인에 이미 pending 요청 있는지
  └─ allocate_previd: linked list 연결용 이전 ID
```

### 6.4 Stage 1: Data Access + Response 생성

```systemverilog
VX_cache_data    // 데이터 SRAM 접근
  ├─ fill: 메모리에서 온 전체 라인 데이터 기록
  ├─ read: way_idx로 해당 라인 읽기 → read_data
  ├─ write: byteen masking으로 워드 단위 기록
  └─ evict_byteen: dirty bytes (writeback용)
```

#### Hit 처리

| 요청 종류 | Hit 시 동작 |
|---|---|
| **Read Hit** | `read_data[word_idx]` → `core_rsp_queue` → 코어에 응답 |
| **Write Hit (Writethrough)** | 캐시 갱신 + `mem_req_queue`로 메모리에도 write 전달 |
| **Write Hit (Writeback)** | 캐시만 갱신, dirty bit 설정 |

#### Miss 처리

| 요청 종류 | Miss 시 동작 |
|---|---|
| **Read Miss** | MSHR에 요청 저장 → `mem_req_queue`로 fill 요청 전송 |
| **Write Miss (Writethrough)** | MSHR 저장 (pending 없으면 해제) + 메모리에 write 전달 |
| **Write Miss (Writeback)** | MSHR에 요청 저장 → fill 요청 전송 |

#### Eviction (Writeback 모드)

- fill 또는 flush 시 evict 대상이 dirty면 → `mem_req_queue`로 writeback 전송
- `DIRTY_BYTES` 활성화 시 라인 전체가 아닌 dirty byte만 writeback

### 6.5 MSHR 상세 동작 (VX_cache_mshr.sv)

```
┌─────────────────────────────────────────────────────────┐
│ MSHR: Miss Status Holding Register                       │
│                                                          │
│  [0] addr=0x1000 (r) → [2]                              │
│  [1] (free)                                              │
│  [2] addr=0x1000 (w)                                     │
│  [3] addr=0x2000 (r)                                     │
│  ...                                                     │
│                                                          │
│  같은 주소의 요청은 linked list로 연결                       │
│  fill 시 head부터 순서대로 replay                          │
└─────────────────────────────────────────────────────────┘
```

| 동작 | 시점 | 설명 |
|---|---|---|
| **allocate** | Stage 0 (새 core 요청) | free 슬롯 할당, 같은 주소 pending 확인 |
| **finalize** | Stage 1 | hit이면 release (슬롯 해제), miss면 persist (유지) |
| **fill** | 메모리 응답 도착 | fill_id의 엔트리부터 replay 시작 |
| **dequeue (replay)** | fill 이후 | linked list 순서로 pending 엔트리 하나씩 replay |

> **핵심**: 같은 캐시라인에 대한 miss가 여러 개 발생하면, 첫 번째만 메모리 fill 요청을 보내고 나머지는 MSHR에서 대기. fill 응답이 오면 모든 pending 요청을 순서대로 replay하여 캐시에서 hit 처리.

---

## 7. 핵심 큐 구조

| 큐 | 파라미터 | 위치 | 용도 |
|---|---|---|---|
| **CRSQ** | `CRSQ_SIZE` | `VX_cache_bank` 내부 | 코어로 보내는 read 응답 버퍼 |
| **MRSQ** | `MRSQ_SIZE` | `VX_cache` 레벨 | 메모리에서 들어온 fill 응답 버퍼 |
| **MREQ** | `MREQ_SIZE` | `VX_cache_bank` 내부 | 메모리로 나가는 fill/writeback 요청 버퍼 |
| **MSHR** | `MSHR_SIZE` | `VX_cache_bank` 내부 | miss 대기열 (재실행 대기) |

### Backpressure (역압) 관계

```
core_req_ready = creq_grant
              && ~mreq_queue_alm_full    // 메모리 요청 큐 여유
              && ~mshr_alm_full          // MSHR 여유
              && ~pipe_stall             // 파이프라인 스톨 없음

pipe_stall = crsp_queue_stall            // 코어 응답 큐 full
```

---

## 8. Writeback vs Writethrough 비교

| 항목 | Writethrough | Writeback |
|---|---|---|
| Write Hit | 캐시 + 메모리 동시 기록 | 캐시만 기록 (dirty bit) |
| Write Miss | 메모리에 바로 write | fill 후 캐시에 기록 |
| Eviction | dirty 데이터 없음 | dirty line → writeback |
| 트래픽 | write마다 메모리 접근 | eviction 시에만 메모리 접근 |
| 구현 복잡도 | 단순 | dirty bit/bytes 관리 필요 |

---

## 9. Non-Cacheable (NC) 바이패스

`VX_cache_wrap`에서 `NC_ENABLE=1`일 때:

- 요청의 `flags[MEM_REQ_FLAG_IO]`가 1이면 캐시를 우회하여 직접 메모리 접근
- `VX_cache_bypass` 모듈이 처리
- DCache는 NC 지원 (`NC_ENABLE=1`), ICache는 미지원 (`NC_ENABLE=0`)
- `PASSTHRU=1`이면 모든 요청이 캐시를 우회 (캐시 비활성화)

### 9.1 NC 주소 판별 흐름

NC bypass 여부는 **주소를 직접 비교하지 않고**, LSU가 설정한 **flag**로 결정된다.

#### Step 1: LSU에서 IO flag 설정 (`VX_lsu_slice.sv`)

```systemverilog
wire [MEM_ADDRW-1:0] block_addr    = full_addr[i][MEM_ASHIFT +: MEM_ADDRW];
wire [MEM_ADDRW-1:0] io_addr_start = MEM_ADDRW'(`XLEN'(`IO_BASE_ADDR) >> MEM_ASHIFT);
wire [MEM_ADDRW-1:0] io_addr_end   = MEM_ADDRW'(`XLEN'(`IO_END_ADDR) >> MEM_ASHIFT);

assign mem_req_flags[i][MEM_REQ_FLAG_IO] = (block_addr >= io_addr_start)
                                        && (block_addr < io_addr_end);
```

- `full_addr = rs1 + offset` (LSU가 계산한 물리 주소)
- 이 주소가 IO 범위에 속하면 `MEM_REQ_FLAG_IO = 1` 설정
- 이 flag가 `req_data.flags`에 실려 캐시까지 전달됨

#### Step 2: IO 주소 범위 정의 (`VX_config.vh`)

| 정의 | XLEN=64 | XLEN=32 |
|---|---|---|
| `IO_BASE_ADDR` | `0x0000_0040` | `0x0000_0040` |
| `IO_END_ADDR` (= `USER_BASE_ADDR`) | `0x0001_0000` | `0x0001_0000` |

즉, **`0x40` ~ `0x10000` (64B ~ 64KB)** 범위의 주소가 IO (non-cacheable) 영역.

이 영역에는 다음이 포함됨:
- `IO_COUT_ADDR` (`0x40`): 콘솔 출력
- `IO_MPM_ADDR`: 성능 카운터
- 기타 MMIO 디바이스 레지스터

#### Step 3: `VX_cache_bypass`에서 분기

```systemverilog
// VX_cache_bypass.sv
assign core_req_nc_sel[i] = ~core_bus_in_if[i].req_data.flags[MEM_REQ_FLAG_IO];
```

| `MEM_REQ_FLAG_IO` | `core_req_nc_sel` | 경로 |
|---|---|---|
| 1 (IO 주소) | 0 | **NC bypass** — 캐시 우회, 직접 메모리 접근 |
| 0 (일반 주소) | 1 | **Cache** — 정상 캐시 경로 |

### 9.2 `VX_cache_bypass` 내부 구조

```
core_bus_in_if [NUM_REQS]
  │
  ▼
VX_mem_switch (core_req_nc_sel로 분기)
  ├─ sel=0: NC 경로 (core_bus_in_nc_if)
  │   ▼
  │  VX_mem_arb (NUM_REQS → MEM_PORTS로 중재)
  │   ▼
  │  Word→Line 변환 (WORD_SIZE → LINE_SIZE 패딩/추출)
  │   ▼
  │  mem_bus_out_nc_if
  │   ▼
  │  VX_mem_arb (NC + Cache 메모리 요청 합류)
  │   ▼
  │  mem_bus_out_if [MEM_PORTS] → 메모리
  │
  └─ sel=1: Cache 경로 (core_bus_out_if)
      ▼
     VX_cache (정상 캐시 처리)
      ▼
     mem_bus_in_if → 같은 VX_mem_arb로 합류
```

### 9.3 NC 경로의 데이터 변환

NC 요청은 코어의 **word 단위** (WORD_SIZE) 요청이지만, 메모리 인터페이스는 **line 단위** (LINE_SIZE). 이를 맞추기 위해:

- **Request**: word 데이터/byteen을 line 크기로 패딩 (해당 word 위치만 유효)
- **Response**: line 데이터에서 해당 word 위치만 추출
- **Tag**: word 선택 비트(`WSEL`)를 tag에 삽입하여 응답 시 올바른 word를 추출

```systemverilog
// 요청 시: word → line 패딩
core_req_nc_arb_byteen_w = '0;
core_req_nc_arb_byteen_w[req_wsel] = core_req_nc_arb_byteen;  // 해당 word만 유효

// 응답 시: line → word 추출
core_rsp_nc_arb_data_w = mem_bus_out_nc_if[i].rsp_data.data[rsp_wsel * CORE_DATA_WIDTH +: CORE_DATA_WIDTH];
```

### 9.4 PASSTHRU 모드

`VX_cache_wrap`에서 `PASSTHRU` 파라미터가 활성화되면:
- `CACHE_ENABLE = 0`으로 설정됨
- `VX_cache_bypass`에서 **모든 요청**이 NC 경로로 전달
- 캐시 인스턴스가 생성되지 않음 (면적/전력 절약)

---

## 10. DMA와의 관계

현재 DMA 트래픽은 두 경로로 캐시에 접근:

### Local Memory 경로
```
DMA Node → dma_local_data_if → LMEM arbiter → VX_local_mem (SRAM)
```
- DCache를 거치지 않고 직접 Local Memory에 접근

### Global Memory 경로
```
DMA Node → dma_global_data_if → DMA arbiter → dcache_bus_if[0] → DCache → L2 → Memory
```
- DCache의 channel 0 포트를 일반 LSU 트래픽과 공유
- Priority arbiter로 중재 (LSU가 우선)

### DMA 설정 레지스터 접근
```
LSU (store to DMA addr) → VX_lmem_switch → dma_ctrl_if → VX_config_registers → DMA Node
```
- 소프트웨어에서 LSU store 명령으로 DMA 제어 레지스터에 기록
- `VX_lmem_switch`가 주소 범위로 분기

---

## 11. Replacement Policy (VX_cache_repl.sv)

| 정책 | 매크로 | 설명 |
|---|---|---|
| Random | `CS_REPL_RANDOM` (0) | LFSR 기반 랜덤 선택 |
| FIFO | `CS_REPL_FIFO` (1) | 가장 먼저 들어온 way 교체 |
| Pseudo-LRU | `CS_REPL_PLRU` (2) | 트리 기반 근사 LRU |

---

## 12. 성능 카운터 (`PERF_ENABLE`)

| 카운터 | 설명 |
|---|---|
| `reads` | 총 read 요청 수 |
| `writes` | 총 write 요청 수 |
| `read_misses` | read miss 수 |
| `write_misses` | write miss 수 |
| `bank_stalls` | 뱅크 충돌로 인한 stall |
| `mshr_stalls` | MSHR full로 인한 stall |
| `mem_stalls` | 메모리 큐 full로 인한 stall |
| `crsp_stalls` | 코어 응답 큐 full로 인한 stall |
