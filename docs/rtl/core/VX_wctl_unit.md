# `core/VX_wctl_unit.sv` — Warp Control Unit

## 개요

SIMT Warp 제어 명령어를 처리하는 유닛.
Thread Mask 변경, Warp 생성, Divergence 관리(SPLIT/JOIN), Barrier 동기화를 담당.

## 아키텍처

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    VX_wctl_unit                          │
                    │                                                         │
execute_if ────────┼──→ ┌─────────────────────────────────────────────────┐  │
                    │    │            명령어 디코딩 & 처리                   │  │
                    │    │  ┌─────┐  ┌──────┐  ┌───────┐  ┌──────┐        │  │
                    │    │  │ TMC │  │WSPAWN│  │ SPLIT │  │ JOIN │        │  │
                    │    │  └──┬──┘  └──┬───┘  └───┬───┘  └──┬───┘        │  │
                    │    │     │        │          │         │            │  │
                    │    │  ┌──┴──┐  ┌──┴───┐  ┌───┴───┐  ┌──┴───┐       │  │
                    │    │  │PRED │  │      │  │       │  │BARRIER       │  │
                    │    │  └──┬──┘  │      │  │       │  └──┬───┘       │  │
                    │    └─────┼─────┼──────┼──┴───────┼─────┼────────────┘  │
                    │          └─────┴──────┴──────────┴─────┘               │
                    │                         │                              │
                    │              ┌──────────▼──────────┐                   │
                    │              │     warp_ctl_if     │                   │
                    │              │  (tmc, wspawn,      │                   │
                    │              │   split, join,      │                   │
                    │              │   barrier)          │                   │
                    │              └──────────┬──────────┘                   │
                    └─────────────────────────┼──────────────────────────────┘
                                              │
                              ┌───────────────┴───────────────┐
                              ▼                               ▼
                        result_if                      warp_ctl_if
                        (→ Commit)                     (→ Scheduler)
```

## 지원 명령어

### 1. TMC (Thread Mask Control)

Thread Mask를 직접 설정:

```systemverilog
assign tmc.valid = (is_tmc || is_pred);
assign tmc.tmask = is_pred ? pred_mask : rs1_data[`NUM_THREADS-1:0];
```

**용도**: `vx_tmc(mask)` - 활성 스레드 직접 제어

### 2. PRED (Predicated Execution)

조건에 따라 Thread Mask 설정:

```systemverilog
wire not_pred = execute_if.data.op_args.wctl.is_neg;  // PRED_N이면 반전

for (genvar i = 0; i < NUM_LANES; ++i) begin
    assign taken[i] = (execute_if.data.rs1_data[i][0] ^ not_pred);
end

wire [`NUM_THREADS-1:0] pred_mask = has_then ? then_tmask : rs2_data[`NUM_THREADS-1:0];
```

**용도**: `vx_pred(condition, fallback_mask)` - 조건부 스레드 활성화

### 3. WSPAWN (Warp Spawn)

새로운 Warp 생성:

```systemverilog
for (genvar i = 0; i < `NUM_WARPS; ++i) begin
    // 자신 제외, rs1 수만큼 warp 활성화
    assign wspawn_wmask[i] = (i < rs1_data[NW_BITS:0]) && (i != execute_if.data.wid);
end
assign wspawn.valid = is_wspawn;
assign wspawn.wmask = wspawn_wmask;
assign wspawn.pc    = from_fullPC(rs2_data);  // 시작 PC
```

**용도**: `vx_wspawn(num_warps, func_ptr)` - 병렬 warp 생성

### 4. SPLIT (Divergence Split)

분기 divergence 처리:

```systemverilog
// then/else 경로의 스레드 분류
then_tmask[pid * NUM_LANES +: NUM_LANES] = taken & execute_if.data.tmask;
else_tmask[pid * NUM_LANES +: NUM_LANES] = ~taken & execute_if.data.tmask;

// 더 많은 스레드가 있는 경로를 먼저 실행
wire then_first = (then_tmask_cnt >= else_tmask_cnt);

assign split.valid      = is_split;
assign split.is_dvg     = has_then && has_else;  // 실제 divergence 발생?
assign split.then_tmask = then_first ? then_tmask : else_tmask;
assign split.else_tmask = then_first ? else_tmask : then_tmask;
assign split.next_pc    = execute_if.data.PC + 4;  // reconvergence point
```

**Divergence Stack 동작**:
```
SPLIT 전:  tmask = 1111, PC = 0x100
           ↓
Divergence 발생 (then=1100, else=0011)
           ↓
Stack Push: {else_tmask=0011, next_pc=0x104}
           ↓
SPLIT 후:  tmask = 1100, PC = 0x100 (then 경로 먼저)
```

### 5. JOIN (Divergence Join)

Divergence Stack에서 복원:

```systemverilog
assign sjoin.valid     = is_join;
assign sjoin.stack_ptr = rs1_data[DV_STACK_SIZEW-1:0];  // SPLIT이 반환한 값
```

**동작**:
```
JOIN 전:   tmask = 1100 (then 경로 완료)
           ↓
Stack Pop: {else_tmask=0011, next_pc=0x104}
           ↓
JOIN 후:   tmask = 0011, PC = 0x100 (else 경로 시작)
           또는
           tmask = 1111, PC = 0x104 (reconverge)
```

### 6. BARRIER (Warp Barrier)

Warp 간 동기화:

```systemverilog
assign barrier.valid    = is_bar;
assign barrier.id       = rs1_data[NB_WIDTH-1:0];      // barrier ID
assign barrier.is_global= rs1_data[31];                // global barrier?
assign barrier.size_m1  = rs2_data - 1;                // 참여 warp 수 - 1
assign barrier.is_noop  = (rs2_data == 1);             // 1개면 대기 불필요
```

**용도**: `vx_barrier(barrier_id, num_warps)` - warp 동기화

## 출력 구조체

### tmc_t

```systemverilog
typedef struct packed {
    logic                    valid;
    logic [`NUM_THREADS-1:0] tmask;  // 새 thread mask
} tmc_t;
```

### wspawn_t

```systemverilog
typedef struct packed {
    logic                   valid;
    logic [`NUM_WARPS-1:0]  wmask;  // 활성화할 warp 비트맵
    logic [PC_BITS-1:0]     pc;     // 시작 PC
} wspawn_t;
```

### split_t

```systemverilog
typedef struct packed {
    logic                   valid;
    logic                   is_dvg;     // divergence 발생 여부
    logic [`NUM_THREADS-1:0] then_tmask; // then 경로 스레드
    logic [`NUM_THREADS-1:0] else_tmask; // else 경로 스레드
    logic [PC_BITS-1:0]     next_pc;    // reconvergence PC
} split_t;
```

### join_t

```systemverilog
typedef struct packed {
    logic                   valid;
    logic [DV_STACK_SIZEW-1:0] stack_ptr;  // divergence stack 포인터
} join_t;
```

### barrier_t

```systemverilog
typedef struct packed {
    logic                   valid;
    logic [NB_WIDTH-1:0]    id;        // barrier ID
    logic                   is_global; // global barrier 여부
    logic [NW_WIDTH-1:0]    size_m1;   // 참여 warp 수 - 1
    logic                   is_noop;   // 1개 warp면 noop
} barrier_t;
```

## Divergence 처리 흐름

### C 코드 → 어셈블리 변환

```c
// C 코드
if (condition) {
    r2 = r2 + 1;   // then path
} else {
    r2 = r2 - 1;   // else path
}
// reconverge point
```

```asm
// 컴파일된 어셈블리
        vx_split r0, r1         ; r0 = stack_ptr, r1 = condition (각 스레드별)
        bne r1, #0, @then       ; condition != 0 이면 then으로 점프
@else:  subi r2, r2, #1         ; else path: r2 = r2 - 1
        j @join                 ; join으로 점프
@then:  addi r2, r2, #1         ; then path: r2 = r2 + 1
@join:  vx_join r0              ; divergence 복원
```

### 실행 흐름 (4 스레드, condition = [1,0,1,0])

```
초기 상태: tmask = 1111, PC = vx_split

Step 1: vx_split r0, r1
        ┌─────────────────────────────────────────────────────┐
        │ 입력: r1 = [1, 0, 1, 0] (각 스레드의 condition)      │
        │                                                     │
        │ 계산:                                                │
        │   then_tmask = 1010 (r1[i] == 1인 스레드)           │
        │   else_tmask = 0101 (r1[i] == 0인 스레드)           │
        │                                                     │
        │ Divergence Stack Push:                              │
        │   {else_tmask=0101, PC=@join}                       │
        │                                                     │
        │ 출력:                                                │
        │   r0 = stack_ptr (나중에 join에서 사용)              │
        │   tmask = 1010 (then 경로 먼저, 더 많은 스레드)       │
        │   PC = 다음 명령어 (bne)                             │
        └─────────────────────────────────────────────────────┘

Step 2: bne r1, #0, @then
        tmask = 1010
        → T0, T2만 활성 (condition=1)
        → 조건 만족하므로 @then으로 점프

Step 3: addi r2, r2, #1  (@then)
        tmask = 1010
        → T0, T2의 r2만 +1

Step 4: vx_join r0 (첫 번째)
        ┌─────────────────────────────────────────────────────┐
        │ Stack Pop: {else_tmask=0101, PC=@join}              │
        │                                                     │
        │ else_tmask != 0 이므로:                              │
        │   tmask = 0101 (else 경로)                          │
        │   PC = @else (else 경로 시작)                        │
        │   Stack 다시 Push: {tmask=0000, PC=@join}           │
        └─────────────────────────────────────────────────────┘

Step 5: subi r2, r2, #1  (@else)
        tmask = 0101
        → T1, T3의 r2만 -1

Step 6: j @join
        → @join으로 점프

Step 7: vx_join r0 (두 번째)
        ┌─────────────────────────────────────────────────────┐
        │ Stack Pop: {tmask=0000, PC=@join}                   │
        │                                                     │
        │ tmask == 0 이므로:                                   │
        │   tmask = 1111 (모든 스레드 재활성화)                 │
        │   PC = @join 다음 (reconverge)                       │
        └─────────────────────────────────────────────────────┘

최종: tmask = 1111, 모든 스레드가 reconverge
```

### 타이밍 다이어그램

```
Cycle   │ PC        │ tmask │ 실행 스레드      │ 동작
────────┼───────────┼───────┼─────────────────┼──────────────────
  1     │ vx_split  │ 1111  │ T0,T1,T2,T3     │ split, stack push
  2     │ bne       │ 1010  │ T0,T2           │ taken → @then
  3     │ @then     │ 1010  │ T0,T2           │ r2 += 1
  4     │ vx_join   │ 1010  │ T0,T2           │ pop, goto @else
  5     │ @else     │ 0101  │ T1,T3           │ r2 -= 1
  6     │ j @join   │ 0101  │ T1,T3           │ jump
  7     │ vx_join   │ 0101  │ T1,T3           │ pop, reconverge
  8     │ (next)    │ 1111  │ T0,T1,T2,T3     │ 정상 실행 계속
```

### Divergence가 없는 경우

모든 스레드가 같은 경로를 선택하면:

```
condition = [1, 1, 1, 1]  (모두 then)

vx_split:
  then_tmask = 1111
  else_tmask = 0000
  is_dvg = 0 (divergence 없음!)
  → Stack Push 생략
  → tmask = 1111 유지

vx_join:
  → Stack이 비었으므로 그냥 통과
```

## 마지막 활성 스레드 선택

여러 스레드의 값 중 대표값 선택:

```systemverilog
VX_priority_encoder #(
    .N (NUM_LANES),
    .REVERSE (1)  // 가장 높은 인덱스 선택
) last_tid_select (
    .data_in (execute_if.data.tmask),
    .index_out (last_tid)
);

wire [`XLEN-1:0] rs1_data = execute_if.data.rs1_data[last_tid];
wire [`XLEN-1:0] rs2_data = execute_if.data.rs2_data[last_tid];
```

## 패킷 축적 (Multi-packet 처리)

SIMD_WIDTH > NUM_LANES일 때 여러 패킷에 걸쳐 tmask 축적:

```systemverilog
if (PID_BITS != 0) begin
    reg [`NUM_WARPS-1:0][2*`NUM_THREADS-1:0] tmask_table;

    always @(*) begin
        // SOP면 초기화, 아니면 이전 값 유지
        {else_tmask, then_tmask} = execute_if.data.sop ? '0 : tmask_r;
        // 현재 패킷의 결과 추가
        then_tmask[pid * NUM_LANES +: NUM_LANES] = taken & tmask;
        else_tmask[pid * NUM_LANES +: NUM_LANES] = ~taken & tmask;
    end
end
```

## 성능 특성

- **레이턴시**: 2 사이클 (elastic buffer + pipe register)
- **스루풋**: 사이클당 1 명령어
- **warp_ctl_if 전송**: EOP에서만 (warp의 마지막 패킷)

## 관련 파일

- [VX_sfu_unit.sv](VX_sfu_unit.md) - 상위 모듈
- [VX_warp_ctl_if.sv](../../../../hw/rtl/interfaces/VX_warp_ctl_if.sv) - Warp 제어 인터페이스
- [VX_warp_sched.sv](../../../../hw/rtl/core/VX_warp_sched.sv) - Divergence Stack 관리
