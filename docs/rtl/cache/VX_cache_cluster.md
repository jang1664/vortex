# `VX_cache_cluster.sv` — 캐시 클러스터 상세 분석

파일: `hw/rtl/cache/VX_cache_cluster.sv`

## 1. 역할

`VX_cache_cluster`는 **여러 캐시 유닛**을 묶어 하나의 논리적 캐시로 제공하는 최상위 모듈입니다. 여러 코어(또는 입력)에서 오는 요청을 분배하고, 하위 메모리 포트를 공유합니다.

핵심 기능:
- `NUM_INPUTS`개의 코어 입력을 `NUM_CACHES`개의 캐시 유닛에 분배 (core request arbiter)
- 각 캐시 유닛의 메모리 요청을 `MEM_PORTS`개 메모리 포트로 중재 (memory arbiter)
- `PASSTHRU` 모드 지원 (`NUM_UNITS=0`)
- 성능 카운터 집계 (모든 캐시 유닛의 합산)

## 2. 주요 파라미터

| 파라미터 | 설명 |
|----------|------|
| `NUM_UNITS` | 캐시 유닛 수 (0이면 passthru) |
| `NUM_INPUTS` | 코어 입력 수 (≥ NUM_CACHES) |
| `TAG_SEL_IDX` | 태그 내 selector 위치 |
| `NUM_REQS` | 캐시 유닛당 코어 요청 포트 수 |
| `MEM_PORTS` | 외부 메모리 포트 수 |
| 나머지 | VX_cache_wrap과 동일한 캐시 파라미터 |

## 3. 인터페이스

```
core_bus_if [NUM_INPUTS * NUM_REQS] (slave)  — 모든 코어 요청
mem_bus_if  [MEM_PORTS]             (master) — 외부 메모리 포트
cache_perf                          (output) — 집계된 성능 카운터
cache_drain                         (output) — 전체 클러스터 drain 상태
```

## 4. 내부 구조

```
 core_bus_if[0:NUM_INPUTS*NUM_REQS-1]
           │
           ▼
 ┌─────────────────────────────────────────────┐
 │         Core Request Arbitration             │
 │  NUM_REQS개의 독립 arbiter (per request slot) │
 │  각 arbiter: NUM_INPUTS → NUM_CACHES         │
 │  VX_mem_arb (Round-Robin)                    │
 └──────────┬────────────────────┬──────────────┘
            │                    │
            ▼                    ▼
 ┌──────────────────┐  ┌──────────────────┐
 │  VX_cache_wrap   │  │  VX_cache_wrap   │
 │  (cache unit 0)  │  │  (cache unit 1)  │
 │                  │  │                  │
 └────────┬─────────┘  └────────┬─────────┘
          │                     │
          ▼                     ▼
 ┌─────────────────────────────────────────────┐
 │         Memory Request Arbitration           │
 │  MEM_PORTS개의 독립 arbiter                   │
 │  각 arbiter: NUM_CACHES → 1                  │
 │  VX_mem_arb (Round-Robin)                    │
 └──────────────────────┬──────────────────────┘
                        │
                        ▼
                  mem_bus_if[0:MEM_PORTS-1]
```

## 5. 동작 상세

### 5.1 Core Request Arbitration (g_core_arb)

**핵심 설계**: request slot별로 독립적인 arbiter를 사용합니다.

```systemverilog
for (genvar i = 0; i < NUM_REQS; ++i) begin : g_core_arb
    // 각 입력의 i번째 요청 슬롯을 수집
    for (genvar j = 0; j < NUM_INPUTS; ++j) begin
        ASSIGN_VX_MEM_BUS_IF(core_bus_tmp_if[j], core_bus_if[j * NUM_REQS + i]);
    end

    // NUM_INPUTS → NUM_CACHES 중재
    VX_mem_arb #(
        .NUM_INPUTS  (NUM_INPUTS),
        .NUM_OUTPUTS (NUM_CACHES),
        .ARBITER     ("R"),         // Round-Robin
        .REQ_OUT_BUF ((NUM_INPUTS != NUM_CACHES) ? 2 : 0),
        .RSP_OUT_BUF ((NUM_INPUTS != NUM_CACHES) ? CORE_OUT_BUF : 0)
    ) core_arb (...);

    // 각 캐시의 i번째 요청 슬롯에 연결
    for (genvar k = 0; k < NUM_CACHES; ++k) begin
        ASSIGN_VX_MEM_BUS_IF(arb_core_bus_if[k * NUM_REQS + i], arb_core_bus_tmp_if[k]);
    end
end
```

**왜 request slot별 arbiter인가?**
- `core_bus_if`는 `[NUM_INPUTS * NUM_REQS]`의 flat 배열
- 각 입력의 i번째 request slot은 동일한 역할 (예: load port 0, load port 1, ...)
- 같은 slot 번호끼리만 중재하면, 다른 slot과의 간섭 없이 독립적으로 동작

**Tag 확장**: arbiter가 input selector를 태그에 추가:
```
ARB_TAG_WIDTH = TAG_WIDTH + ARB_SEL_BITS(NUM_INPUTS, NUM_CACHES)
```

### 5.2 Cache Unit 인스턴스화 (g_cache_wrap)

```systemverilog
for (genvar i = 0; i < NUM_CACHES; ++i) begin : g_cache_wrap
    VX_cache_wrap #(
        .TAG_WIDTH   (ARB_TAG_WIDTH),     // 확장된 태그
        .CORE_OUT_BUF((NUM_INPUTS != NUM_CACHES) ? 2 : CORE_OUT_BUF),
        .MEM_OUT_BUF ((NUM_CACHES > 1) ? 2 : MEM_OUT_BUF),
        .PASSTHRU    (PASSTHRU),          // NUM_UNITS=0이면 passthru
        ...
    ) cache_wrap (
        .core_bus_if (arb_core_bus_if[i * NUM_REQS +: NUM_REQS]),
        .mem_bus_if  (cache_mem_bus_if[i * MEM_PORTS +: MEM_PORTS]),
        .cache_drain (per_cache_drain[i])
    );
end
```

### 5.3 Memory Request Arbitration (g_mem_bus_if)

```systemverilog
for (genvar i = 0; i < MEM_PORTS; ++i) begin : g_mem_bus_if
    // 각 캐시의 i번째 메모리 포트를 수집
    for (genvar j = 0; j < NUM_CACHES; ++j) begin
        ASSIGN_VX_MEM_BUS_IF(arb_core_bus_tmp_if[j], cache_mem_bus_if[j * MEM_PORTS + i]);
    end

    // NUM_CACHES → 1 중재
    VX_mem_arb #(
        .NUM_INPUTS  (NUM_CACHES),
        .NUM_OUTPUTS (1),
        .ARBITER     ("R"),
        .REQ_OUT_BUF ((NUM_CACHES > 1) ? MEM_OUT_BUF : 0),
        .RSP_OUT_BUF ((NUM_CACHES > 1) ? 2 : 0)
    ) mem_arb (...);

    // Write 가능 여부에 따른 포트 매핑
    if (WRITE_ENABLE):
        ASSIGN_VX_MEM_BUS_IF(mem_bus_if[i], mem_bus_tmp_if[0]);
    else:
        ASSIGN_VX_MEM_BUS_RO_IF(mem_bus_if[i], mem_bus_tmp_if[0]);
end
```

### 5.4 Drain 판정

```systemverilog
wire cluster_pending = (| core_req_pending)       // 코어 요청
                    || (| core_rsp_pending)        // 코어 응답
                    || (| arb_req_pending)         // arbiter 입력
                    || (| arb_rsp_pending)         // arbiter 출력
                    || (| cache_mem_req_pending)   // 캐시 메모리 요청
                    || (| cache_mem_rsp_pending)   // 캐시 메모리 응답
                    || (| mem_req_pending)          // 외부 메모리 요청
                    || (| mem_rsp_pending);         // 외부 메모리 응답

assign cache_drain = (& per_cache_drain) && ~cluster_pending;
```

모든 캐시 유닛이 drain 상태이고, 모든 arbiter/버퍼에 pending 데이터가 없을 때만 전체 클러스터가 drain됩니다.

## 6. 성능 카운터 집계

```systemverilog
cache_perf_t perf_cache_unit[NUM_CACHES];
PERF_CACHE_ADD(cache_perf, perf_cache_unit, NUM_CACHES);
```

`PERF_CACHE_ADD` 매크로가 모든 캐시 유닛의 성능 카운터(reads, writes, misses, stalls)를 합산합니다.

## 7. PASSTHRU 모드

```systemverilog
localparam PASSTHRU = (NUM_UNITS == 0);
```

`NUM_UNITS=0`이면:
- `NUM_CACHES = UP(0) = 1` (최소 1개 유닛)
- `VX_cache_wrap`에 `PASSTHRU=1`이 전달됨
- 캐시 인스턴스가 생성되지 않고, bypass만 동작

## 8. 버퍼 크기 조정

```systemverilog
// Core arbiter: 입출력 수가 다를 때만 버퍼 추가
REQ_OUT_BUF = (NUM_INPUTS != NUM_CACHES) ? 2 : 0;
RSP_OUT_BUF = (NUM_INPUTS != NUM_CACHES) ? CORE_OUT_BUF : 0;

// Cache wrap: 다중 캐시일 때 내부 버퍼 추가
CORE_OUT_BUF = (NUM_INPUTS != NUM_CACHES) ? 2 : CORE_OUT_BUF;
MEM_OUT_BUF  = (NUM_CACHES > 1) ? 2 : MEM_OUT_BUF;

// Memory arbiter: 다중 캐시일 때만 버퍼 추가
REQ_OUT_BUF = (NUM_CACHES > 1) ? MEM_OUT_BUF : 0;
RSP_OUT_BUF = (NUM_CACHES > 1) ? 2 : 0;
```

N:1 중재가 필요할 때만 버퍼를 추가하여, 1:1 직결 시 불필요한 레이턴시를 방지합니다.

## 9. 사용 예시

| 구성 | NUM_INPUTS | NUM_UNITS | NUM_CACHES | 동작 |
|------|------------|-----------|------------|------|
| 단일 코어, 단일 캐시 | 1 | 1 | 1 | 직결 (arbiter 불필요) |
| 4 코어, 1 캐시 | 4 | 1 | 1 | 4:1 core arbiter |
| 4 코어, 2 캐시 | 4 | 2 | 2 | 4:2 core arbiter + 2:1 mem arbiter |
| Passthru | N | 0 | 1 | 캐시 없이 bypass |

## 10. 설계 핵심 포인트

1. **독립적 Request Slot Arbiter**: request slot별로 별도 arbiter를 사용하여, 다른 slot의 트래픽이 현재 slot의 latency에 영향을 미치지 않습니다.

2. **Static Assert**: `NUM_INPUTS >= NUM_CACHES`를 보장합니다. 캐시 유닛 수보다 입력이 적으면 의미가 없습니다.

3. **Tag 기반 라우팅**: arbiter가 입력 selector를 태그에 추가하여, 응답이 돌아올 때 올바른 입력으로 라우팅합니다. 이는 `VX_mem_arb`의 표준 패턴입니다.
