# SCOPE 디버깅 인프라

## 개요

Vortex의 SCOPE 시스템은 하드웨어 디버깅을 위한 런타임 신호 캡처 인프라이다.
시뮬레이션 및 FPGA 환경에서 내부 신호를 기록하고 외부로 전송할 수 있게 해준다.

## 동작 원리

### 개념적 구조

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Top Level (AFU)                            │
│                                                                     │
│   scope_reset ──────────────────────────────────────────────────┐   │
│   scope_bus_in ─────────────────────────────────────────────────┤   │
│   scope_bus_out ←───────────────────────────────────────────────┤   │
│                                                                 │   │
│   ┌──────────────────────────────────────────────────────────┐  │   │
│   │                    VX_core                               │  │   │
│   │                                                          │  │   │
│   │   `SCOPE_IO_SWITCH(3) ─────────────────────────────────┐ │  │   │
│   │                                                         │ │  │   │
│   │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │ │  │   │
│   │   │  VX_fetch   │  │  VX_issue   │  │ VX_execute  │    │ │  │   │
│   │   │ BIND(0)     │  │ BIND(1)     │  │ BIND(2)     │    │ │  │   │
│   │   │             │  │             │  │             │    │ │  │   │
│   │   │ SCOPE_TAP   │  │ SCOPE_TAP   │  │ SCOPE_IO_   │    │ │  │   │
│   │   │ (ID=1)      │  │ (ID=2)      │  │ SWITCH(1)   │    │ │  │   │
│   │   │             │  │             │  │     ↓       │    │ │  │   │
│   │   │             │  │             │  │ VX_lsu_unit │    │ │  │   │
│   │   │             │  │             │  │ SCOPE_TAP   │    │ │  │   │
│   │   │             │  │             │  │ (ID=3)      │    │ │  │   │
│   │   └─────────────┘  └─────────────┘  └─────────────┘    │ │  │   │
│   │                                                         │ │  │   │
│   └─────────────────────────────────────────────────────────┘ │  │   │
│                                                               │  │   │
└───────────────────────────────────────────────────────────────┘──┘   │
                                                                       │
                                                                       ↓
                                                              외부 디버거/호스트
```

### 신호 흐름

1. **Request Path (scope_bus_in)**:
   - 호스트 → AFU → SCOPE_SWITCH → 각 TAP 모듈
   - 직렬 버스로 명령어 전송 (ID, 명령 타입, 데이터)

2. **Response Path (scope_bus_out)**:
   - TAP 모듈 → SCOPE_SWITCH → AFU → 호스트
   - 캡처된 데이터 직렬 전송

## 매크로 정의

### `SCOPE_IO_DECL`

모듈의 포트 선언에 SCOPE I/O 추가.

```systemverilog
// SCOPE 활성화 시
`define SCOPE_IO_DECL \
    input wire scope_reset, \
    input wire scope_bus_in, \
    output wire scope_bus_out,

// SCOPE 비활성화 시 (빈 매크로)
`define SCOPE_IO_DECL
```

**사용 예:**
```systemverilog
module VX_fetch #(...) (
    `SCOPE_IO_DECL          // scope_reset, scope_bus_in, scope_bus_out 포트 추가

    input wire clk,
    input wire reset,
    ...
);
```

### `SCOPE_IO_SWITCH(count)`

여러 하위 모듈로 SCOPE 버스 분배.

```systemverilog
`define SCOPE_IO_SWITCH(__count) \
    wire [__count-1:0] scope_bus_in_w; \
    wire [__count-1:0] scope_bus_out_w; \
    wire [__count-1:0] scope_reset_w = {__count{scope_reset}}; \
    VX_scope_switch #( \
        .N (__count) \
    ) scope_switch ( \
        .clk     (clk), \
        .reset   (scope_reset), \
        .req_in  (scope_bus_in), \
        .rsp_out (scope_bus_out), \
        .req_out (scope_bus_in_w), \
        .rsp_in  (scope_bus_out_w) \
    )
```

**동작:**
- 입력 `scope_bus_in`을 `__count`개의 `scope_bus_in_w[i]`로 복제 (broadcast)
- 출력 `scope_bus_out_w[i]`를 OR 병합하여 `scope_bus_out` 생성
- `scope_reset`도 모든 하위 모듈에 복제

**사용 예:**
```systemverilog
// VX_core에서 3개의 하위 모듈에 분배
`SCOPE_IO_SWITCH (3);   // scope_bus_in_w[0:2], scope_bus_out_w[0:2] 생성

VX_fetch fetch (
    `SCOPE_IO_BIND(0)   // scope_reset_w[0], scope_bus_in_w[0], scope_bus_out_w[0]
    ...
);

VX_issue issue (
    `SCOPE_IO_BIND(1)   // scope_reset_w[1], scope_bus_in_w[1], scope_bus_out_w[1]
    ...
);

VX_execute execute (
    `SCOPE_IO_BIND(2)   // scope_reset_w[2], scope_bus_in_w[2], scope_bus_out_w[2]
    ...
);
```

### `SCOPE_IO_BIND(index)`

하위 모듈 인스턴스에 SCOPE 신호 연결.

```systemverilog
`define SCOPE_IO_BIND(__i) \
    .scope_reset (scope_reset_w[__i]), \
    .scope_bus_in (scope_bus_in_w[__i]), \
    .scope_bus_out (scope_bus_out_w[__i]),
```

### `SCOPE_IO_UNUSED(index)`

사용하지 않는 SCOPE 슬롯 처리.

```systemverilog
`define SCOPE_IO_UNUSED(__i) \
    `UNUSED_VAR (scope_reset_w[__i]); \
    `UNUSED_VAR (scope_bus_in_w[__i]); \
    assign scope_bus_out_w[__i] = 0;
```

### `SCOPE_TAP` / `SCOPE_TAP_EX`

실제 신호 캡처 지점 정의.

```systemverilog
`define SCOPE_TAP(__idx, __id, __xtriggers, __htriggers, __probes, __start, __stop, __depth) \
    `SCOPE_TAP_EX(__idx, __id, $bits(__xtriggers), $bits(__htriggers), $bits(__probes), \
                  __xtriggers, __htriggers, __probes, __start, __stop, __depth)
```

**파라미터:**
| 파라미터 | 설명 |
|----------|------|
| `__idx` | SCOPE_SWITCH 슬롯 인덱스 |
| `__id` | 고유 TAP ID (호스트에서 식별) |
| `__xtriggers` | 변화 감지 트리거 신호 (edge trigger) |
| `__htriggers` | 하이 레벨 트리거 신호 (level trigger) |
| `__probes` | 캡처할 데이터 신호 |
| `__start` | 캡처 시작 조건 |
| `__stop` | 캡처 중지 조건 |
| `__depth` | 버퍼 깊이 (샘플 수) |

## 핵심 모듈

### VX_scope_switch

SCOPE 버스를 N개의 하위 모듈로 분배.

```systemverilog
module VX_scope_switch #(
    parameter N = 0
) (
    input wire  clk,
    input wire  reset,
    input wire  req_in,          // 상위로부터의 요청
    output wire [N-1:0] req_out, // 하위로 분배된 요청
    input wire  [N-1:0] rsp_in,  // 하위로부터의 응답
    output wire rsp_out          // 상위로의 응답
);
```

**동작:**
- `req_in` → 모든 `req_out[i]`로 1 사이클 지연 복제
- `rsp_in[*]` 중 하나라도 1이면 `rsp_out = 1`

### VX_scope_tap

실제 신호 캡처 및 전송 수행.

```systemverilog
module VX_scope_tap #(
    parameter SCOPE_ID  = 0,    // TAP 식별자
    parameter SCOPE_IDW = 8,    // ID 비트폭
    parameter XTRIGGERW = 0,    // 변화 트리거 폭
    parameter HTRIGGERW = 0,    // 레벨 트리거 폭
    parameter PROBEW    = 1,    // 프로브 폭
    parameter DEPTH     = 256,  // 버퍼 깊이
    parameter IDLE_CTRW = 32,   // idle 카운터 폭
    parameter TX_DATAW  = 64    // 전송 데이터 폭
) (
    input wire clk,
    input wire reset,
    input wire start,                       // 외부 시작 신호
    input wire stop,                        // 외부 정지 신호
    input wire [XTRIGGERW-1:0] xtriggers,   // 변화 감지 트리거
    input wire [HTRIGGERW-1:0] htriggers,   // 레벨 트리거
    input wire [PROBEW-1:0] probes,         // 캡처할 데이터
    input wire bus_in,                      // 직렬 버스 입력
    output wire bus_out                     // 직렬 버스 출력
);
```

**TAP 상태:**
- `TAP_STATE_IDLE`: 대기 (캡처 시작 대기)
- `TAP_STATE_RUN`: 캡처 중
- `TAP_STATE_DONE`: 캡처 완료

**컨트롤러 상태:**
- `CTRL_STATE_IDLE`: 명령 대기
- `CTRL_STATE_RECV`: 명령 수신 중
- `CTRL_STATE_CMD`: 명령 처리
- `CTRL_STATE_SEND`: 데이터 전송

**명령 타입:**
| 명령 | 코드 | 설명 |
|------|------|------|
| CMD_GET_WIDTH | 0 | 프로브 폭 조회 |
| CMD_GET_COUNT | 1 | 캡처된 샘플 수 조회 |
| CMD_GET_START | 2 | 시작 타임스탬프 조회 |
| CMD_GET_DATA | 3 | 데이터 읽기 |
| CMD_SET_START | 4 | 캡처 시작 |
| CMD_SET_STOP | 5 | 캡처 정지 |
| CMD_SET_DEPTH | 6 | 버퍼 깊이 설정 |

**트리거 동작:**
- `xtriggers`: 값이 변할 때 캡처 (edge-triggered)
- `htriggers`: 0이 아닐 때 캡처 (level-triggered)
- 트리거 없으면 매 사이클 캡처
- `delta` 카운터로 트리거 사이의 idle 시간 기록

## 사용 예시

### VX_fetch에서의 SCOPE_TAP 사용

```systemverilog
`ifdef SCOPE
`ifdef DBG_SCOPE_FETCH
    `SCOPE_IO_SWITCH (1);

    wire schedule_fire = schedule_if.valid && schedule_if.ready;
    wire icache_bus_req_fire = icache_bus_if.req_valid && icache_bus_if.req_ready;
    wire icache_bus_rsp_fire = icache_bus_if.rsp_valid && icache_bus_if.rsp_ready;

    wire reset_negedge;
    `NEG_EDGE (reset_negedge, reset);

    `SCOPE_TAP_EX (0, 1,    // 슬롯 0, TAP ID 1
        6,                   // xtriggers 폭 (6비트)
        3,                   // htriggers 폭 (3비트)
        (UUID_WIDTH + NW_WIDTH + ...),  // probes 폭

        // xtriggers: valid/ready 신호들 (변화 감지)
        {
            schedule_if.valid,
            schedule_if.ready,
            icache_bus_if.req_valid,
            icache_bus_if.req_ready,
            icache_bus_if.rsp_valid,
            icache_bus_if.rsp_ready
        },

        // htriggers: fire 신호들 (활성 시 캡처)
        {
            schedule_fire,
            icache_bus_req_fire,
            icache_bus_rsp_fire
        },

        // probes: 실제 캡처할 데이터
        {
            schedule_if.data.uuid, schedule_if.data.wid, schedule_if.data.tmask, schedule_if.data.PC,
            icache_bus_if.req_data.tag.uuid, icache_bus_if.req_data.byteen, icache_bus_if.req_data.addr,
            icache_bus_if.rsp_data.tag.uuid, icache_bus_if.rsp_data.data
        },

        reset_negedge,   // start: 리셋 해제 시 시작
        1'b0,            // stop: 외부 정지 없음
        4096             // depth: 4096 샘플
    );
`else
    `SCOPE_IO_UNUSED(0)
`endif
`endif
```

### 계층적 SCOPE 구조

```
VX_core (SCOPE_IO_SWITCH(3))
├─[0] VX_fetch (SCOPE_IO_SWITCH(1))
│     └─[0] SCOPE_TAP (ID=1)
│
├─[1] VX_issue (SCOPE_IO_SWITCH(1))
│     └─[0] SCOPE_TAP (ID=2)
│
└─[2] VX_execute (SCOPE_IO_SWITCH(1))
      └─[0] VX_lsu_unit
            └─[0] SCOPE_TAP (ID=3)
```

## 활성화 방법

### 컴파일 시 활성화

```bash
# SCOPE 활성화
make SCOPE=1

# 특정 디버그 스코프 활성화
make SCOPE=1 DBG_SCOPE_FETCH=1
```

### 관련 매크로

| 매크로 | 설명 |
|--------|------|
| `SCOPE` | SCOPE 인프라 활성화 |
| `DBG_SCOPE_FETCH` | Fetch stage 디버깅 |
| `DBG_SCOPE_ISSUE` | Issue stage 디버깅 |
| `DBG_SCOPE_LSU` | LSU 디버깅 |
| `DBG_TRACE_SCOPE` | SCOPE 트레이스 출력 |

## 관련 파일

- [VX_scope.vh](../../../hw/rtl/VX_scope.vh) - 매크로 정의
- [VX_scope_switch.sv](../../../hw/rtl/libs/VX_scope_switch.sv) - 버스 분배 모듈
- [VX_scope_tap.sv](../../../hw/rtl/libs/VX_scope_tap.sv) - 신호 캡처 모듈

## CHIPSCOPE와의 차이

| 특성 | SCOPE | CHIPSCOPE |
|------|-------|-----------|
| 타겟 | 시뮬레이션 + FPGA | FPGA (Xilinx) |
| 인터페이스 | 커스텀 직렬 버스 | Xilinx ILA |
| 유연성 | 높음 | 도구 종속 |
| 오버헤드 | 낮음 | 높음 |

CHIPSCOPE 사용 예:
```systemverilog
`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_FETCH
    ila_fetch ila_fetch_inst (
        .clk    (clk),
        .probe0 ({schedule_if.valid, schedule_if.data, schedule_if.ready}),
        .probe1 ({icache_bus_if.req_valid, icache_bus_if.req_data, icache_bus_if.req_ready}),
        .probe2 ({icache_bus_if.rsp_valid, icache_bus_if.rsp_data, icache_bus_if.rsp_ready})
    );
`endif
`endif
```

## 디버깅 팁

1. **TAP ID 확인**: 각 SCOPE_TAP은 고유한 ID를 가져야 함
2. **트리거 선택**:
   - 빈번한 이벤트 → xtriggers (edge)
   - 특정 조건 → htriggers (level)
3. **버퍼 깊이**: 필요한 샘플 수에 맞게 설정 (메모리 트레이드오프)
4. **시작/정지 조건**: 정확한 캡처 윈도우 설정
