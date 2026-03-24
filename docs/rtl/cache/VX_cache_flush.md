# `VX_cache_flush.sv` — Flush 상태 머신 상세 분석

파일: `hw/rtl/cache/VX_cache_flush.sv`

## 1. 역할

`VX_cache_flush`는 각 뱅크 내부의 **flush 상태 머신**입니다. 리셋 시 태그 초기화와, 명시적 flush 요청 시 모든 캐시 라인을 순회하며 invalidate(+ writeback)하는 작업을 관리합니다.

## 2. 파라미터

| 파라미터 | 설명 |
|----------|------|
| `BANK_ID` | 뱅크 ID (bank0이 마지막으로 완료해야 함) |
| `CACHE_SIZE`, `LINE_SIZE`, `NUM_BANKS`, `NUM_WAYS` | 캐시 기하 |
| `WRITEBACK` | writeback 모드 여부 (way 순회 필요 여부 결정) |

## 3. 인터페이스

```
flush_begin (input)  — flush 시작 신호 (VX_cache_init에서)
flush_end   (output) — flush 완료 신호
flush_init  (output) — 초기화 모드 (리셋 직후)
flush_valid (output) — flush 순회 중 (유효한 flush 라인 출력)
flush_line  (output) — 현재 순회 중인 라인 인덱스
flush_way   (output) — 현재 순회 중인 way (writeback 모드)
flush_ready (input)  — 뱅크가 flush를 수락할 수 있는지
mshr_empty  (input)  — MSHR이 비었는지
bank_empty  (input)  — 뱅크에 pending 요청이 없는지
```

## 4. 상태 머신

```
┌──────────┐   reset    ┌──────────┐
│          │ ─────────→ │ STATE_   │
│  STATE_  │            │  INIT    │───→ 카운터로 모든 라인 순회
│  IDLE    │            │          │     (태그 invalidate)
│          │ ←───────── │          │
│          │  완료 시   └──────────┘
│          │
│          │  flush_begin
│          │ ─────────→ ┌──────────┐
│          │            │ STATE_   │
│          │            │  WAIT1   │───→ MSHR이 비워질 때까지 대기
│          │            │          │
│          │            └────┬─────┘
│          │                 │ mshr_empty
│          │            ┌────▼─────┐
│          │            │ STATE_   │
│          │            │  FLUSH   │───→ 카운터로 모든 라인(+way) 순회
│          │            │          │     WB: dirty 라인 writeback + invalidate
│          │            │          │     WT: invalidate만
│          │            └────┬─────┘
│          │                 │ 카운터 완료
│          │            ┌────▼─────┐
│          │            │ STATE_   │
│          │  BANK_ID=0 │  WAIT2   │───→ bank_empty 대기
│          │  직접 DONE │          │     (bank0 제외)
│          │            └────┬─────┘
│          │                 │ bank_empty
│          │            ┌────▼─────┐
│          │            │ STATE_   │
│          │ ←───────── │  DONE    │───→ flush_end 펄스 생성
│          │  1 cycle   │          │
└──────────┘            └──────────┘
```

## 5. 카운터 구조

```systemverilog
localparam CTR_WIDTH = CS_LINE_SEL_BITS + (WRITEBACK ? CS_WAY_SEL_BITS : 0);
reg [CTR_WIDTH-1:0] counter;
```

- **Write-Through 모드**: `CTR_WIDTH = CS_LINE_SEL_BITS`
  - 라인만 순회 (모든 way를 한번에 invalidate)
  - `flush_line = counter`

- **Writeback 모드**: `CTR_WIDTH = CS_LINE_SEL_BITS + CS_WAY_SEL_BITS`
  - 라인 × way를 모두 순회 (각 way의 dirty 확인 필요)
  - `flush_line = counter[CS_LINE_SEL_BITS-1:0]`
  - `flush_way = counter[CS_LINE_SEL_BITS +: CS_WAY_SEL_BITS]`

카운터 증가 조건:
```systemverilog
if ((state == STATE_INIT)
 || ((state == STATE_FLUSH) && flush_ready)) begin
    counter <= counter + 1;
end
```
- STATE_INIT: 매 사이클 증가 (backpressure 없음)
- STATE_FLUSH: `flush_ready`가 1일 때만 증가 (뱅크가 처리 가능할 때)

## 6. BANK_ID별 동작 차이

```systemverilog
STATE_FLUSH 완료 후:
  if (BANK_ID == 0):
    state_n = STATE_DONE;   // 바로 완료
  else:
    state_n = STATE_WAIT2;  // bank_empty 대기
```

**이유**: flush 완료 후 하위 캐시로의 flush 요청은 **bank 0을 통해서만** 전송됩니다. 따라서:
- Bank 0: 마지막으로 flush를 완료하여 하위 캐시로의 flush 요청이 가장 마지막에 나가도록 보장
- Bank 1~N: flush 순회 후, 뱅크 내 모든 요청(writeback 등)이 처리될 때까지 대기 후 완료 보고

이를 통해 bank 0의 flush 요청이 다른 뱅크의 writeback이 모두 완료된 후에 전송됩니다.

## 7. Init 모드 (리셋)

```systemverilog
always @(posedge clk) begin
    if (reset) begin
        state   <= STATE_INIT;  // 리셋 시 바로 INIT 상태
        counter <= '0;
    end
end
```

리셋 후 STATE_INIT에서 모든 라인을 순회하며 태그를 invalidate합니다. 이는 시뮬레이션에서 X-값을 방지하고, FPGA에서 정의된 초기 상태를 보장합니다.

## 8. 뱅크 파이프라인과의 상호작용

뱅크의 입력 선택에서:
```systemverilog
// VX_cache_bank.sv
flush_ready = flush_grant
           && ~(WRITEBACK && mreq_queue_alm_full)  // WB: writeback 큐 여유 필요
           && ~pipe_stall;

// flush는 core request보다 높은 우선순위
flush_grant = ~init_valid && ~replay_enable && ~fill_enable;
```

flush 중에는:
- `init_valid`: 태그에 init 명령 전달 → 라인 invalidate
- `flush_valid`: 태그에 flush 명령 전달 → dirty 확인 + invalidate
  - Writeback: dirty 라인의 데이터를 mem_req_queue에 enqueue (writeback)

## 9. 설계 핵심 포인트

1. **2-Phase Flush**: WAIT1(MSHR 비움) → FLUSH(순회). MSHR이 먼저 비워져야 pending replay가 flush와 충돌하지 않습니다.

2. **Bank 0 Last**: 멀티뱅크 환경에서 bank 0이 마지막으로 완료되어, 하위 캐시로의 flush 전파가 모든 writeback 이후에 발생하도록 보장합니다.

3. **Backpressure 지원**: `flush_ready`를 통해 뱅크가 바쁠 때(파이프라인 stall, writeback 큐 full) flush 카운터 증가를 중단합니다.

4. **Init vs Flush**: Init은 리셋 시 1회만 발생하며 backpressure 없이 빠르게 진행합니다. Flush는 런타임에 발생하며 dirty 라인 writeback을 위해 backpressure를 받습니다.
