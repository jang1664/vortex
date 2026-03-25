# `VX_cache_init.sv` — 초기화 및 Flush 요청 관리 상세 분석

파일: `hw/rtl/cache/VX_cache_init.sv`

## 1. 역할

`VX_cache_init`은 `VX_cache` 최상위에서 다음을 관리합니다:
- **Flush 요청 감지**: 코어 요청 중 `MEM_REQ_FLAG_FLUSH` 플래그를 감지
- **In-flight 요청 대기**: flush 시작 전 crossbar에 아직 전달되지 않은 요청이 처리될 때까지 대기
- **Flush 시퀀스 제어**: 모든 뱅크에 flush_begin을 보내고, 모든 뱅크의 flush_end를 수집
- **요청 차단/해제**: flush 중 일반 코어 요청을 차단하고, flush 완료 후 해제

## 2. 파라미터

| 파라미터 | 설명 |
|----------|------|
| `NUM_REQS` | 코어 요청 포트 수 |
| `NUM_BANKS` | 뱅크 수 |
| `TAG_WIDTH` | 코어 요청 태그 폭 |
| `BANK_SEL_LATENCY` | request crossbar의 레이턴시 (in-flight 추적에 사용) |

## 3. 인터페이스

```
core_bus_in_if  [NUM_REQS]  (slave)  — 원본 코어 요청 (VX_cache 외부)
core_bus_out_if [NUM_REQS]  (master) — 필터링된 코어 요청 (crossbar로)

bank_req_fire [NUM_BANKS]   (input)  — 각 뱅크가 요청을 수락했는지
flush_begin   [NUM_BANKS]   (output) — 각 뱅크에 flush 시작 신호
flush_uuid                  (output) — flush 요청의 UUID
flush_end     [NUM_BANKS]   (input)  — 각 뱅크의 flush 완료 신호
```

## 4. 상태 머신

```
┌──────────┐
│ STATE_   │  flush_req 감지
│  IDLE    │ ──────────────→ ┌──────────┐
│          │                 │ STATE_   │
│          │  BANK_SEL_      │  WAIT1   │──→ in-flight 요청 대기
│          │  LATENCY=0      │          │    (crossbar latency만큼)
│          │  이면 FLUSH     └────┬─────┘
│          │  으로 직행           │ no_inflight_reqs
│          │                 ┌────▼─────┐
│          │                 │ STATE_   │
│          │                 │  FLUSH   │──→ flush_begin 펄스 생성
│          │                 │          │    (1 cycle만)
│          │                 └────┬─────┘
│          │                 ┌────▼─────┐
│          │                 │ STATE_   │
│          │                 │  WAIT2   │──→ 모든 뱅크 flush_end 대기
│          │                 │          │
│          │                 └────┬─────┘
│          │                      │ 모든 뱅크 완료
│          │                 ┌────▼─────┐
│          │                 │ STATE_   │
│          │ ←────────────── │  DONE    │──→ flush 요청을 release
│          │  모든 flush     │          │    (core로 전달)
└──────────┘  요청 전달 완료 └──────────┘
```

## 5. 동작 상세

### 5.1 Flush 요청 감지

```systemverilog
wire [NUM_REQS-1:0] flush_req_mask;
for (genvar i = 0; i < NUM_REQS; ++i) begin
    assign flush_req_mask[i] = core_bus_in_if[i].req_valid
                            && core_bus_in_if[i].req_data.flags[MEM_REQ_FLAG_FLUSH];
end
wire flush_req_enable = (| flush_req_mask);
```

### 5.2 요청 차단 메커니즘

```systemverilog
for (genvar i = 0; i < NUM_REQS; ++i) begin
    wire input_enable = ~flush_req_enable || lock_released[i];
    assign core_bus_out_if[i].req_valid = core_bus_in_if[i].req_valid && input_enable;
    assign core_bus_in_if[i].req_ready  = core_bus_out_if[i].req_ready && input_enable;
end
```

**동작**:
- `flush_req_enable=1` (flush 요청 감지됨): 모든 요청 차단 (`input_enable=0`)
- IDLE 상태: `flush_req_enable`에 의해 차단
- WAIT1/FLUSH/WAIT2 상태: 상태 머신이 IDLE이 아니므로 flush_req_enable은 유지됨
- DONE 상태: `lock_released`로 flush 요청만 선택적 해제

### 5.3 In-flight 추적 (BANK_SEL_LATENCY > 0)

crossbar에 이미 들어간 요청이 아직 뱅크에 도달하지 않았을 수 있습니다:

```systemverilog
if (BANK_SEL_LATENCY != 0) begin
    VX_pending_size #(
        .SIZE (BANK_SEL_LATENCY * NUM_BANKS)
    ) pending_size (
        .incr  (core_bus_out_fire 수),   // crossbar에 진입한 요청 수
        .decr  (bank_req_fire 수),       // 뱅크가 수락한 요청 수
        .empty (no_inflight_reqs)        // 차이가 0이면 in-flight 없음
    );
end
```

### 5.4 Flush 완료 및 Release

```systemverilog
STATE_WAIT2:
    flush_done_n = flush_done | flush_end;
    if (flush_done_n == {NUM_BANKS{1'b1}}) begin  // 모든 뱅크 완료
        state_n = STATE_DONE;
        lock_released_n = flush_req_mask;  // flush 요청만 release
    end

STATE_DONE:
    lock_released_n = lock_released & ~core_bus_out_ready;
    if (lock_released_n == 0) begin  // 모든 flush 요청 전달 완료
        state_n = STATE_IDLE;         // 일반 요청 unlock
    end
```

**왜 flush 요청을 release하는가?**
- Flush 요청 자체도 코어에서 온 요청입니다
- Flush가 완료되면 이 요청을 캐시 파이프라인에 통과시켜 코어에 응답합니다
- 이때 `flush_req_mask`에 해당하는 포트만 release하고, 일반 요청은 계속 차단
- 모든 flush 요청이 전달되면(ready로 수락되면) IDLE로 돌아가 일반 요청도 unlock

### 5.5 Flush UUID 추출

```systemverilog
// 여러 flush 요청 중 마지막(최상위 인덱스)의 UUID를 사용
for (integer i = NUM_REQS-1; i >= 0; --i) begin
    if (flush_req_mask[i]) begin
        flush_uuid_n = core_bus_out_uuid[i];
    end
end
```

## 6. Response 경로 (직통)

```systemverilog
// Response는 flush 영향 없이 직접 전달
for (genvar i = 0; i < NUM_REQS; ++i) begin
    assign core_bus_in_if[i].rsp_valid  = core_bus_out_if[i].rsp_valid;
    assign core_bus_in_if[i].rsp_data   = core_bus_out_if[i].rsp_data;
    assign core_bus_out_if[i].rsp_ready = core_bus_in_if[i].rsp_ready;
end
```

## 7. 설계 핵심 포인트

1. **In-flight Drain**: flush 전에 crossbar에 이미 진입한 요청을 뱅크까지 도달시킵니다. 이는 crossbar 내부의 버퍼에 요청이 남아있으면 flush와 충돌할 수 있기 때문입니다.

2. **선택적 Release**: flush 완료 후 flush 요청만 먼저 release하고, 일반 요청은 flush 요청 전달 완료 후 release합니다. 이는 flush 요청의 응답이 올바르게 생성되도록 보장합니다.

3. **글로벌 Flush 조율**: 모든 뱅크에 동시에 `flush_begin`을 보내고, 모든 뱅크의 `flush_end`를 수집합니다. 각 뱅크 내부의 `VX_cache_flush`가 독립적으로 flush 순회를 수행합니다.
