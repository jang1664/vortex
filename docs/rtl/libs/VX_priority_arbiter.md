# `libs/VX_priority_arbiter.sv` — Priority Arbiter

## 개요

여러 요청자 중 고정 우선순위에 따라 하나를 선택하는 중재기.
낮은 인덱스가 높은 우선순위를 가지며, STICKY 모드로 grant 유지 가능.

## 모듈 파라미터

| 파라미터 | 기본값 | 설명 |
|----------|--------|------|
| `NUM_REQS` | 1 | 요청자 수 |
| `STICKY` | 0 | 1이면 요청 해제까지 grant 유지 |

## 인터페이스

| 신호 | 방향 | 폭 | 설명 |
|------|------|-----|------|
| `clk` | input | 1 | 클럭 |
| `reset` | input | 1 | 리셋 |
| `requests` | input | NUM_REQS | 요청 비트맵 |
| `grant_index` | output | log2(NUM_REQS) | 선택된 요청자 인덱스 |
| `grant_onehot` | output | NUM_REQS | 선택된 요청자 (one-hot) |
| `grant_valid` | output | 1 | 유효한 grant 존재 |
| `grant_ready` | input | 1 | 다운스트림 ready |

## 동작 원리

### 기본 구조

```
requests ──┬──→ [retain_grant?] ──→ [VX_priority_encoder] ──→ grant_*
           │           ↑
           │     prev_grant (레지스터)
           │           ↑
           └───────────┘ (STICKY 모드)
```

### 우선순위 선택 (STICKY=0)

낮은 인덱스가 항상 우선:

```
requests = 4'b1010
               ↑
               bit 1이 최우선

grant_index  = 2'd1
grant_onehot = 4'b0010
grant_valid  = 1
```

매 사이클 동일한 요청이면 동일한 grant:
```
Cycle 1: requests=1010 → grant=0010
Cycle 2: requests=1010 → grant=0010
Cycle 3: requests=1010 → grant=0010
```

### STICKY 모드 (STICKY=1)

이전 grant를 유지하려고 시도:

```systemverilog
// 이전 grant 저장
always @(posedge clk) begin
    if (grant_valid && grant_ready)
        prev_grant <= grant_onehot;
end

// 이전 grant가 아직 요청 중이면 유지
wire retain_grant = (STICKY != 0) && (|(prev_grant & requests));
wire [NUM_REQS-1:0] requests_w = retain_grant ? prev_grant : requests;
```

동작 예시:
```
Cycle 1: requests=1010, prev=0000 → grant=0010 (bit 1)
         prev_grant ← 0010

Cycle 2: requests=1110, prev=0010 → retain! → grant=0010 유지
         (prev_grant & requests = 0010 ≠ 0)

Cycle 3: requests=1100, prev=0010 → 새 선택 → grant=0100 (bit 2)
         (prev_grant & requests = 0000 = 0)
```

### STICKY 모드 사용 사례

**버스 트랜잭션 보호**:
```
Master A: 4-beat burst 전송 중
Master B: 새로운 요청 발생

STICKY=0: Master B가 중간에 버스 획득 → burst 깨짐
STICKY=1: Master A가 요청 해제까지 버스 유지 → burst 완료
```

## grant_valid 동작

```systemverilog
// STICKY 모드에서는 요청이 있으면 항상 valid
assign grant_valid = (STICKY != 0) ? (| requests) : grant_valid_w;
```

- `STICKY=0`: priority encoder의 valid 출력 사용
- `STICKY=1`: 요청이 하나라도 있으면 valid (prev_grant 유지 가능)

## 타이밍 다이어그램

### STICKY=0
```
clk         ─┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──
             └──┘  └──┘  └──┘  └──┘  └──┘
requests    ─<1010>─<1110>─<0110>─<0100>─<0000>─
grant       ─<0010>─<0010>─<0010>─<0100>─<0000>─
             bit1    bit1    bit1    bit2   none
```

### STICKY=1
```
clk         ─┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──
             └──┘  └──┘  └──┘  └──┘  └──┘
requests    ─<1010>─<1110>─<1100>─<0100>─<0000>─
grant       ─<0010>─<0010>─<0100>─<0100>─<0000>─
             bit1   retain  bit2   retain  none
                    (bit1   (bit1
                    요청중)  해제)
```

## 특수 케이스: NUM_REQS=1

```systemverilog
if (NUM_REQS == 1) begin : g_passthru
    assign grant_index  = '0;
    assign grant_onehot = requests;
    assign grant_valid  = requests[0];
end
```

요청자가 하나면 중재 불필요.

## 사용 예시

```systemverilog
// 메모리 요청 중재
VX_priority_arbiter #(
    .NUM_REQS (4),
    .STICKY   (1)    // burst 전송 보호
) mem_arb (
    .clk         (clk),
    .reset       (reset),
    .requests    (mem_requests),
    .grant_index (selected_master),
    .grant_onehot(grant_mask),
    .grant_valid (has_grant),
    .grant_ready (mem_ready)
);
```

## Priority vs Round-Robin 비교

| 특성 | Priority Arbiter | Round-Robin Arbiter |
|------|------------------|---------------------|
| 공정성 | 낮음 (낮은 인덱스 선호) | 높음 (순환) |
| 레이턴시 | 높은 우선순위 요청자에 낮음 | 균등 |
| 기아 | 가능 (낮은 우선순위가 계속 대기) | 없음 |
| 복잡도 | 낮음 | 약간 높음 |
| 사용처 | 우선순위가 명확한 경우 | 공정성 필요한 경우 |

## 관련 모듈

- [VX_priority_encoder.sv](VX_priority_encoder.md) - 핵심 인코더
- [VX_rr_arbiter.sv](../../../hw/rtl/libs/VX_rr_arbiter.sv) - Round-Robin 중재기
- [VX_generic_arbiter.sv](../../../hw/rtl/libs/VX_generic_arbiter.sv) - 타입 선택 가능한 중재기

## 하드웨어 비용

- 레지스터: NUM_REQS 비트 (prev_grant)
- 조합 논리: Priority encoder + AND/OR 게이트
- STICKY=0이면 prev_grant 레지스터 최적화 가능
