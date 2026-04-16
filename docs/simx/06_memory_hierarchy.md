# Memory Hierarchy

SimX는 3단계 캐시 계층과 DRAM, 로컬 메모리(스크래치패드)를 모델링한다.

## 전체 구조

```
Core[0]   Core[1]          (소켓당 SOCKET_SIZE개)
  │ │       │ │
  │ └─┐     │ └─┐
  ▼   ▼     ▼   ▼
I-$  D-$   I-$  D-$        ◄ L1 Cache (소켓 내 공유)
  │   │      │   │
  └───┴──────┴───┘
         │
      L1 Arbiter             (I/D → L2 round-robin 중재)
         │
    ┌────┴────┐
    │ L2 Cache │              ◄ L2 Cache (클러스터 내 공유)
    └────┬────┘
         │
    ┌────┴────┐
    │ L3 Cache │              ◄ L3 Cache (프로세서 전체 공유)
    └────┬────┘
         │
    ┌────┴────┐
    │  MemSim  │              ◄ DRAM 시뮬레이터
    │  (DRAM)  │
    └─────────┘

별도 경로:
  Core → LocalMemSwitch ──┬── D-Cache (Global 주소)
                           └── LocalMem (Shared 주소)
```

## 1. CacheSim — 범용 캐시 시뮬레이터

> 소스: `sim/simx/cache_sim.h`, `cache_sim.cpp`

L1, L2, L3 캐시 모두 동일한 `CacheSim` 클래스로 구현된다.
생성 시 설정(Config)으로 동작을 결정한다.

### 설정 파라미터

```cpp
struct Config {
  bool     bypass;         // 캐시 바이패스 (활성화 시 모든 요청 통과)
  uint32_t C;              // log2(캐시 크기)
  uint32_t L;              // log2(캐시 라인 크기)
  uint32_t W;              // log2(워드 크기)
  uint32_t A;              // log2(연관도, ways)
  uint32_t B;              // log2(뱅크 수)
  uint32_t addr_width;     // 주소 비트 폭 (XLEN)
  uint32_t num_inputs;     // 요청 입력 포트 수
  uint32_t mem_ports;      // 메모리 출력 포트 수
  bool     write_back;     // write-back 정책 (vs write-through)
  bool     write_reponse;  // 쓰기 응답 발행 여부
  uint32_t mshr_size;      // MSHR 엔트리 수
  uint32_t latency;        // 파이프라인 레이턴시
};
```

### 주소 분해

```
주소 비트:
  [addr_width-1 .................. 0]
  [    tag    |  set  | bank | word | byte_offset]
               ◄─ A ─►◄─ B ─►◄─ W ─►
```

- **byte_offset**: 캐시 라인 내 바이트 위치
- **word**: 워드 선택 비트
- **bank**: 뱅크 선택 비트
- **set**: 세트 선택 비트
- **tag**: 태그 비트 (나머지 상위 비트)

### 요청 처리 흐름

```
요청 도착 (CoreReqPorts[i])
       │
       ▼
  ┌──────────┐
  │ 크로스바  │ ← bank_id로 라우팅
  └─────┬────┘
        ▼
  ┌──────────┐
  │ 뱅크 처리 │
  │          │
  │  태그 룩업 (LRU)
  │    │
  │    ├─ HIT:
  │    │   ├─ Read: 즉시 응답 생성
  │    │   ├─ Write (write-back): dirty 비트 설정
  │    │   └─ Write (write-through): 메모리로 전달
  │    │
  │    └─ MISS:
  │        ├─ MSHR에 동일 주소 요청 있는지 확인
  │        │   ├─ 있음: MSHR에 합류 (요청 코얼레싱)
  │        │   └─ 없음: MSHR 할당 + fill 요청 전송
  │        │
  │        └─ 교체 대상이 dirty이면: eviction (write-back)
  │
  └──────────┘
       │
       ▼ (fill 응답 수신 시)
  MSHR 리플레이: 대기 중이던 모든 요청에 응답 발행
```

### MSHR (Miss Status Holding Register)

캐시 미스 시 진행 중인 fill 요청을 추적하고,
동일 주소에 대한 중복 요청을 합병(coalesce)한다.

```
요청 A: addr=0x1000 → MISS → MSHR 할당, fill 요청 전송
요청 B: addr=0x1000 → MISS → MSHR에 기존 엔트리 발견, 합류만 (fill 중복 없음)
요청 C: addr=0x1000 → MISS → MSHR에 합류

fill 응답 도착:
  → 캐시 라인 설치
  → 요청 A, B, C 모두에 응답 발행 (리플레이)
  → MSHR 엔트리 해제
```

**MSHR 풀**: `mshr_size`개를 초과하면 새 미스 요청이 스톨된다.

### 쓰기 정책

| 정책 | Hit 동작 | Miss 동작 |
|------|----------|-----------|
| Write-back | dirty 비트 설정 (메모리 전송 없음) | MSHR 할당 + fill, dirty 교체 시 eviction |
| Write-through | 메모리로 즉시 전달 | 메모리로 즉시 전달 |

### 성능 카운터

```cpp
struct PerfStats {
  uint64_t reads;         // 읽기 요청 수
  uint64_t writes;        // 쓰기 요청 수
  uint64_t read_misses;   // 읽기 미스
  uint64_t write_misses;  // 쓰기 미스
  uint64_t evictions;     // write-back eviction 수
  uint64_t bank_stalls;   // 뱅크 충돌 스톨
  uint64_t mshr_stalls;   // MSHR 풀 스톨
  uint64_t mem_latency;   // 누적 fill 대기 시간
};
```

## 2. 캐시 레벨별 설정

### L1 Instruction Cache

```
위치: 소켓 내 공유
크기: ICACHE_SIZE
연관도: ICACHE_NUM_WAYS
뱅크: ICACHE_NUM_BANKS
MSHR: ICACHE_MSHR_SIZE
정책: Read-only (write-back 없음)
입력: 코어당 1 포트
```

### L1 Data Cache

```
위치: 소켓 내 공유
크기: DCACHE_SIZE
연관도: DCACHE_NUM_WAYS
워드 크기: DCACHE_WORD_SIZE (= LSU_LINE_SIZE)
뱅크: DCACHE_NUM_BANKS
MSHR: DCACHE_MSHR_SIZE
정책: DCACHE_WRITEBACK (설정 가능)
입력: NUM_LSU_BLOCKS * DCACHE_CHANNELS 포트 (코얼레싱됨)
```

### L2 Cache

```
위치: 클러스터 내 공유
크기: L2_CACHE_SIZE
연관도: L2_NUM_WAYS
뱅크: L2_NUM_BANKS
MSHR: L2_MSHR_SIZE
정책: L2_WRITEBACK (설정 가능)
입력: L1_MEM_PORTS * NUM_SOCKETS (클러스터 내 모든 소켓)
출력: L2_MEM_PORTS (→ L3)
```

### L3 Cache

```
위치: 프로세서 전체 공유
크기: L3_CACHE_SIZE
연관도: L3_NUM_WAYS
뱅크: L3_NUM_BANKS
MSHR: L3_MSHR_SIZE
정책: L3_WRITEBACK
바이패스: !L3_ENABLED이면 바이패스
입력: L2_MEM_PORTS * NUM_CLUSTERS
출력: L3_MEM_PORTS (→ DRAM)
레이턴시: 2 cycles
```

## 3. CacheCluster — 캐시 클러스터

> 소스: `sim/simx/cache_cluster.h`

다수의 캐시 인스턴스를 묶어 하나의 논리적 캐시로 제공한다.
입력 요청을 캐시 인스턴스들에 분배하고, 메모리 응답을 집계한다.

```
입력 포트 0 ──┐
입력 포트 1 ──┼── 입력 중재기 (round-robin) ──> CacheSim[0]
입력 포트 2 ──┘                                 CacheSim[1]
                                                   │
                                       출력 중재기 ──> 메모리 포트
```

## 4. MemSim — DRAM 시뮬레이터

> 소스: `sim/simx/mem_sim.h`, `mem_sim.cpp`

DRAM 접근을 시뮬레이션한다.

### 설정

```cpp
struct Config {
  uint32_t num_banks;      // DRAM 뱅크 수 (PLATFORM_MEMORY_NUM_BANKS)
  uint32_t num_ports;      // 메모리 요청 포트 수 (L3_MEM_PORTS)
  uint32_t block_size;     // 캐시 라인 크기 (MEM_BLOCK_SIZE)
  uint32_t clock_ratio;    // DRAM/코어 클럭 비율 (MEM_CLOCK_RATIO)
};
```

### 뱅크 인터리빙

```
bank_id = (addr >> log2(block_size)) & (num_banks - 1)
```

연속 캐시 라인이 서로 다른 뱅크에 분산되어 병렬 접근이 가능하다.

### 요청 흐름

```
MemReqPorts[i] 에 요청 도착
       │
       ▼
  mem_xbar_ (뱅크 라우팅 크로스바)
       │
       ▼
  DramSim (뱅크별 타이밍 시뮬레이션)
       │ (콜백)
       ▼
  MemRspPorts[i] 로 응답 반환 (읽기만)
```

- 쓰기는 응답 없음 (fire-and-forget)
- 읽기는 DRAM 레이턴시 후 콜백으로 응답

### 클럭 비율

`MEM_CLOCK_RATIO > 1`이면 DRAM이 코어보다 느린 클럭에서 동작한다.
예: `MEM_CLOCK_RATIO=2` → DRAM은 코어 2사이클당 1사이클 동작

## 5. LocalMem — 로컬 메모리 (스크래치패드)

> 소스: `sim/simx/local_mem.h`, `local_mem.cpp`

캐시가 아닌 직접 접근 가능한 로컬 메모리이다.
코어별로 존재하며, 공유 데이터 교환에 사용된다.

### 특성

```
위치: 코어별 (소켓 공유 아님)
크기: 2^LMEM_LOG_SIZE
뱅크: LMEM_NUM_BANKS
워드 크기: LSU_WORD_SIZE
레이턴시: 1 cycle (즉시 응답)
```

### 뱅크 인터리빙

```
bank_id = (addr >> log2(line_size)) & (num_banks - 1)
```

뱅크 충돌 시 우선순위(priority) 중재를 사용한다 (round-robin 아님).

### 로컬 메모리 vs 캐시 차이

| | LocalMem | D-Cache |
|---|---|---|
| 지연 | 1 cycle (결정적) | 가변 (hit/miss) |
| 용량 | 작음 (수 KB) | 설정에 따라 |
| 정책 | 직접 접근 | 캐시 라인 기반 |
| 미스 | 없음 (전체 메모리가 온칩) | MSHR + fill |

## 6. LocalMemSwitch — 주소 기반 라우팅

> 소스: `sim/simx/types.h/cpp`

LSU의 메모리 요청을 주소에 따라 D-cache 또는 LocalMem으로 분기한다.

```cpp
AddrType get_addr_type(uint64_t addr) {
  if (addr >= IO_BASE_ADDR && addr < IO_END_ADDR)
    return AddrType::IO;       // I/O 메모리
  if (LMEM_ENABLED && addr >= LMEM_BASE_ADDR && ...)
    return AddrType::Shared;   // 로컬 메모리
  return AddrType::Global;     // 전역 메모리 (캐시)
}
```

```
LSU 요청
    │
    ▼
LocalMemSwitch
    │
    ├─ Global → D-Cache → L2 → L3 → DRAM
    ├─ Shared → LocalMem (1 cycle)
    └─ IO     → IO 처리 (DCR 등)
```

## 7. MemCoalescer — 메모리 요청 합병기

> 소스: `sim/simx/mem_coalescer.h`, `mem_coalescer.cpp`

LSU에서 발생하는 다수의 스레드별 요청을 캐시 라인 단위로 합병한다.

### 동작

```
스레드 0: load addr=0x1000
스레드 1: load addr=0x1004
스레드 2: load addr=0x1008    → 같은 캐시 라인! → 1개 캐시 요청으로 합병
스레드 3: load addr=0x2000    → 다른 캐시 라인  → 별도 요청
```

### 합병 흐름

```
입력: LsuReq (mask 포함, 다중 스레드 요청)
  │
  ▼
캐시 라인별 그룹핑
  │
  ▼
합병된 MemReq 생성 (캐시 라인당 1개)
  │
  ▼
출력 → CacheSim

응답 경로: 부분 응답 → 전체 응답으로 재조립 → LsuRsp
```

## 8. 메모리 요청/응답 타입

```cpp
struct MemReq {
  uint64_t addr;       // 물리 주소
  bool     write;      // 읽기(false) / 쓰기(true)
  AddrType type;       // Global / Shared / IO
  uint32_t tag;        // 요청 식별자 (MSHR, pending 추적용)
  uint32_t cid;        // 코어 ID
  uint64_t uuid;       // 디버깅용 고유 ID
};

struct MemRsp {
  uint64_t tag;        // 원본 요청의 tag와 매칭
  uint32_t cid;        // 코어 ID
  uint64_t uuid;       // 디버깅용 고유 ID
};
```

## 9. 전체 메모리 접근 타이밍 예시

Load 명령어가 L1 D-cache miss, L2 hit인 경우:

```
Cycle  0: LSU → MemCoalescer → D-Cache 요청
Cycle  1: D-Cache 태그 룩업 → MISS → MSHR 할당
Cycle  2: D-Cache → L2 fill 요청
Cycle  3: L2 태그 룩업 → HIT
Cycle  5: L2 → D-Cache 응답 (latency=2)
Cycle  6: D-Cache MSHR 리플레이 → 코어 응답
Cycle  7: LSU 응답 수신 → commit으로 전달
```

## 소스 파일 요약

| 파일 | 내용 |
|------|------|
| `sim/simx/cache_sim.h/cpp` | CacheSim (범용 캐시 시뮬레이터) |
| `sim/simx/cache_cluster.h` | CacheCluster (다중 캐시 인스턴스) |
| `sim/simx/mem_sim.h/cpp` | MemSim (DRAM 시뮬레이터) |
| `sim/simx/local_mem.h/cpp` | LocalMem (스크래치패드) |
| `sim/simx/mem_coalescer.h/cpp` | MemCoalescer (요청 합병) |
| `sim/simx/types.h/cpp` | MemReq/Rsp, LocalMemSwitch, LsuMemAdapter |
