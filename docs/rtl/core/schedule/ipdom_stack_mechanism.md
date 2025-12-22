# IPDOM Stack Mechanism 분석

## 개요

**IPDOM (Immediate Post-Dominator) Stack**은 Vortex GPGPU의 structured control flow를 구현하는 핵심 모듈입니다. SPLIT/JOIN을 사용한 thread divergence를 관리하며, "어느 path를 실행했는지" 추적하는 state machine 역할을 합니다.

### 핵심 개념
- **SPLIT**: Thread divergence 발생 시 then/else path 정보를 stack에 저장
- **JOIN**: Path 실행 완료 시 stack에서 정보를 읽어 다음 path로 전환 또는 convergence
- **Path Selection**: `q_idx` 플래그로 then path(idx=0) vs else path/convergence(idx=1) 선택

---

## IPDOM Stack의 특별한 구조

### 일반 Stack vs IPDOM Stack

**일반 Stack**:
```
PUSH → 데이터 저장
POP  → 데이터 읽고 제거
```

**IPDOM Stack**:
```
PUSH → 두 가지 path 정보 저장 (d0, d1), idx=0
POP #1 → 데이터 읽고, idx를 1로 바꿔서 다시 저장! (제거 안함)
POP #2 → 데이터 읽고, 이제 완전히 제거
```

### 핵심: Pop 시 "Read-Modify-Write"

**VX_ipdom_stack.sv**:
```systemverilog
// Line 120-126
VX_dp_ram #(
    .DATAW    (BRAM_DATAW),  // BRAM_DATAW = 1 + WIDTH * 2
    .SIZE     (BRAM_SIZE),
    .RDW_MODE ("R"),
    .RADDR_REG(1)
) ipdom_store (
    .clk   (clk),
    .reset (reset),
    .read  (pop),
    .write (push || pop),        // ★ Pop 시에도 write!
    .wren  (1'b1),
    .waddr (waddr),
    .raddr (raddr),
    .wdata (push ? {1'b0, d1, d0} : {1'b1, q1, q0}),  // ★ 핵심!
    .rdata ({q_idx, q1, q0})
);

// Line 133
assign q_val = q_idx ? q0 : q1;  // idx로 path 선택
```

### 데이터 구조

| 필드 | 비트 수 | 설명 |
|------|--------|------|
| `q_idx` | 1 bit | Path selection flag<br>0 = Then path 실행 필요<br>1 = Else path/Convergence |
| `q1` (d1) | WIDTH | Else path 정보<br>{else_tmask, next_pc} |
| `q0` (d0) | WIDTH | Then/Convergence 정보<br>{full_tmask, 0} |

---

## SPLIT 시 동작 (PUSH)

### VX_split_join.sv - 데이터 준비

**파일**: [hw/rtl/core/VX_split_join.sv](hw/rtl/core/VX_split_join.sv#L46)

```systemverilog
// Line 46-47: 두 path의 정보 준비
wire [(`NUM_THREADS + PC_BITS)-1:0] ipdom_d0 = {split.then_tmask | split.else_tmask, PC_BITS'(0)};
wire [(`NUM_THREADS + PC_BITS)-1:0] ipdom_d1 = {split.else_tmask, split.next_pc};

// Line 51-52
wire ipdom_push = split_valid && split.is_dvg;
wire ipdom_pop  = sjoin_valid && sjoin_is_dvg;
```

### Stack에 저장되는 데이터

```
PUSH (split_valid && split.is_dvg):
┌─────────┬────────────────────────┬────────────────────────┐
│ q_idx=0 │ d1 (q1)                │ d0 (q0)                │
│         │ {else_tmask, next_pc}  │ {full_tmask, 0}        │
└─────────┴────────────────────────┴────────────────────────┘
          ↑                         ↑
          Else path 정보            Then/Convergence 정보
```

### 필드별 의미

| 필드 | SPLIT 시 값 | 의미 |
|------|------------|------|
| **q_idx** | 0 | "Then path 먼저 실행해야 함" |
| **d1 (else)** | {else_tmask, next_pc} | Else path로 갈 때 필요한 정보 |
| **d0 (then/full)** | {then_tmask \| else_tmask, 0} | Convergence 시 전체 thread mask |

---

## 첫 번째 JOIN 시 동작 (POP #1)

### Then Path 실행 완료

```systemverilog
// VX_ipdom_stack.sv

// === READ ===
.rdata ({q_idx, q1, q0})
     = {0, {else_tmask, next_pc}, {full_tmask, 0}}

// === PATH SELECTION ===
q_val = q_idx ? q0 : q1
      = 0 ? q0 : q1
      = q1                          // ★ Else path 정보 선택!
      = {else_tmask, next_pc}

// === WRITE (다시 저장!) ===
.wdata = push ? {1'b0, d1, d0} : {1'b1, q1, q0}
       = {1'b1, q1, q0}             // ★ idx를 1로 변경!
       = {1, {else_tmask, next_pc}, {full_tmask, 0}}
```

### Stack 상태 변화

```
BEFORE (Then path 실행 후):
┌─────────┬────────────────────────┬────────────────────────┐
│ q_idx=0 │ {else_tmask, next_pc}  │ {full_tmask, 0}        │
└─────────┴────────────────────────┴────────────────────────┘

JOIN #1 (pop=1):
  - READ:  idx=0 → q1 선택 → else path 정보
  - WRITE: idx=1로 업데이트하여 다시 저장

AFTER (Else path 실행 시작):
┌─────────┬────────────────────────┬────────────────────────┐
│ q_idx=1 │ {else_tmask, next_pc}  │ {full_tmask, 0}        │
└─────────┴────────────────────────┴────────────────────────┘
         ↑
         "Then path 실행 완료" 표시!
```

### VX_split_join.sv 출력

```systemverilog
// Line 82
.data_in ({sjoin_valid, wid, sjoin_is_dvg, ~ipdom_idx, ipdom_tmask, ipdom_pc})
//                                          ^^^^^^^^^^
// join_is_else = ~ipdom_idx = ~0 = 1  ★ Else path로!

.data_out ({join_valid, join_wid, join_is_dvg, join_is_else, join_tmask, join_pc})
```

| 출력 신호 | 값 | 의미 |
|----------|-----|------|
| `join_valid` | 1 | JOIN 유효 |
| `join_is_dvg` | 1 | Divergence 중 |
| `join_is_else` | ~0 = **1** | **Else path로 전환** |
| `join_tmask` | else_tmask | Else path thread mask |
| `join_pc` | next_pc | Else path 시작 주소 |

---

## 두 번째 JOIN 시 동작 (POP #2)

### Else Path 실행 완료

```systemverilog
// === READ ===
.rdata ({q_idx, q1, q0})
     = {1, {else_tmask, next_pc}, {full_tmask, 0}}

// === PATH SELECTION ===
q_val = q_idx ? q0 : q1
      = 1 ? q0 : q1
      = q0                          // ★ Convergence 정보 선택!
      = {full_tmask, 0}

// === POP (완전히 제거) ===
// VX_ipdom_stack.sv Line 68-69
if (pop_s) begin
    wr_ptr_r <= wr_ptr_r - ADDRW'(q_idx);  // q_idx=1 → ptr 감소
    empty_r  <= (rd_ptr == 0) && q_idx;    // Stack empty
end
```

### Stack 상태 변화

```
BEFORE (Else path 실행 후):
┌─────────┬────────────────────────┬────────────────────────┐
│ q_idx=1 │ {else_tmask, next_pc}  │ {full_tmask, 0}        │
└─────────┴────────────────────────┴────────────────────────┘

JOIN #2 (pop=1):
  - READ:  idx=1 → q0 선택 → convergence 정보
  - POP:   wr_ptr 감소 (q_idx=1이므로 실제로 pop)

AFTER (Convergence):
Stack = [  ]  (비어 있음)
```

### VX_split_join.sv 출력

```systemverilog
// Line 82
.data_in ({sjoin_valid, wid, sjoin_is_dvg, ~ipdom_idx, ipdom_tmask, ipdom_pc})
//                                          ^^^^^^^^^^
// join_is_else = ~ipdom_idx = ~1 = 0  ★ Convergence!

.data_out ({join_valid, join_wid, join_is_dvg, join_is_else, join_tmask, join_pc})
```

| 출력 신호 | 값 | 의미 |
|----------|-----|------|
| `join_valid` | 1 | JOIN 유효 |
| `join_is_dvg` | 1 | (마지막 divergence) |
| `join_is_else` | ~1 = **0** | **Convergence!** |
| `join_tmask` | full_tmask | 모든 thread 다시 활성화 |
| `join_pc` | 0 | (사용 안함) |

---

## Write Pointer 관리

### VX_ipdom_stack.sv - Pointer 업데이트

```systemverilog
// Line 62-72
always @(posedge clk) begin
    if (reset) begin
        wr_ptr_r <= '0;
        empty_r  <= 1;
        full_r   <= 0;
    end else begin
        if (push_s) begin
            wr_ptr_r <= wr_ptr_r + ADDRW'(1);     // Push: ptr 증가
            empty_r  <= 0;
            full_r   <= (ADDRW'(DEPTH-1) == wr_ptr_r);
        end else if (pop_s) begin
            wr_ptr_r <= wr_ptr_r - ADDRW'(q_idx); // Pop: idx만큼 감소
            empty_r  <= (rd_ptr == 0) && q_idx;   // idx=1일 때만 empty
            full_r   <= 0;
        end
    end
end
```

### Pointer 동작 예시

```
초기: wr_ptr = 0, Stack = [  ]

SPLIT (push):
  wr_ptr = 0 + 1 = 1
  Stack[0] = {idx=0, else_info, then_info}

JOIN #1 (pop, q_idx=0):
  wr_ptr = 1 - 0 = 1  ★ 그대로 유지!
  Stack[0] = {idx=1, else_info, then_info}  (업데이트)

JOIN #2 (pop, q_idx=1):
  wr_ptr = 1 - 1 = 0  ★ 실제로 pop!
  Stack = [  ]  (비어 있음)
```

**핵심**: 
- **q_idx=0 (첫 번째 JOIN)**: `wr_ptr - 0 = wr_ptr` → **Pointer 유지**
- **q_idx=1 (두 번째 JOIN)**: `wr_ptr - 1` → **실제 Pop**

---

## 전체 실행 흐름

### 시나리오: if-else 분기

```c
// Kernel code
if (condition) {
    // Then path
    x = a + b;
} else {
    // Else path
    x = a - b;
}
// Convergence point
y = x * 2;
```

### 타이밍 다이어그램

```
Cycle  Event               Stack State                        Output
-----  ------------------  ---------------------------------  -------------------------
T0     SPLIT               [{idx=0, else, then}]              → Then path 실행 시작
                           wr_ptr=1

...    (Then path 실행)

T10    JOIN #1             [{idx=1, else, then}]              join_is_else=1
       (Then 완료)         wr_ptr=1 (유지!)                   → Else path 전환
                           q_idx=0 → q1 선택

...    (Else path 실행)

T20    JOIN #2             [  ]                               join_is_else=0
       (Else 완료)         wr_ptr=0 (감소!)                   → Convergence
                           q_idx=1 → q0 선택

T21    (Convergence)       [  ]                               모든 thread 활성화
                                                              → y = x * 2 실행
```

### 상세 단계

| Cycle | Stage | Event | Stack | wr_ptr | q_idx | 선택 | 다음 동작 |
|-------|-------|-------|-------|--------|-------|------|----------|
| T0 | Execute | SPLIT | [{0, else, then}] | 1 | - | - | Then path |
| T10 | Execute | JOIN #1 | [{1, else, then}] | 1 | 0 → 1 | q1 (else) | Else path |
| T20 | Execute | JOIN #2 | [ ] | 0 | 1 | q0 (full) | Convergence |

---

## 중첩 Divergence (Nested If)

### 시나리오

```c
if (cond1) {        // SPLIT #1
    if (cond2) {    // SPLIT #2
        // A
    } else {
        // B
    }               // JOIN #2
} else {
    // C
}                   // JOIN #1
```

### Stack 변화

```
SPLIT #1:
Stack = [{idx=0, else_1, then_1}]
wr_ptr = 1

SPLIT #2 (Then path 내부):
Stack = [{idx=0, else_1, then_1}, {idx=0, else_2, then_2}]
wr_ptr = 2

JOIN #2-1 (Path A 완료):
Stack = [{idx=0, else_1, then_1}, {idx=1, else_2, then_2}]
wr_ptr = 2  (유지)

JOIN #2-2 (Path B 완료):
Stack = [{idx=0, else_1, then_1}]
wr_ptr = 1  (pop)

JOIN #1-1 (Then path 완료):
Stack = [{idx=1, else_1, then_1}]
wr_ptr = 1  (유지)

JOIN #1-2 (Else path 완료):
Stack = [  ]
wr_ptr = 0  (pop)
```

---

## Divergence 판단 메커니즘 (sjoin_is_dvg)

### 핵심 질문: "어떻게 실제 Divergence를 판단하는가?"

**VX_split_join.sv Line 49**:
```systemverilog
wire sjoin_is_dvg = (sjoin.stack_ptr != ipdom_wr_ptr[wid]);

// Line 52
wire ipdom_pop = sjoin_valid && sjoin_is_dvg;
```

### 비교 대상

| 신호 | 출처 | 의미 |
|------|------|------|
| **sjoin.stack_ptr** | 컴파일러 (immediate) | "이 JOIN과 매칭되는 SPLIT의 stack depth" |
| **ipdom_wr_ptr[wid]** | Hardware (runtime) | "현재 warp의 실제 stack top pointer" |

### join_t 구조 정의

**VX_gpu_pkg.sv**:
```systemverilog
// Line 468-471
typedef struct packed {
    logic                   valid;
    logic [DV_STACK_SIZEW-1:0] stack_ptr;  // ★ 컴파일러가 명령어에 hardcode
} join_t;
```

### Divergence 판단 로직

```systemverilog
if (sjoin.stack_ptr == ipdom_wr_ptr[wid]) {
    // 이 JOIN의 SPLIT이 이미 완료됨
    sjoin_is_dvg = 0;
    ipdom_pop = 0;  // Stack 건드리지 않음 (No-op JOIN)
} else {  // sjoin.stack_ptr < ipdom_wr_ptr[wid]
    // 이 JOIN의 SPLIT이 아직 활성화 중
    sjoin_is_dvg = 1;
    ipdom_pop = 1;  // Stack pop 필요 (path 전환/convergence)
}
```

| 조건 | 의미 | 동작 |
|------|------|------|
| `stack_ptr < wr_ptr` | JOIN의 SPLIT 위에 다른 SPLIT이 있음 | **Divergence** → Pop 실행 |
| `stack_ptr == wr_ptr` | JOIN의 SPLIT이 이미 완료됨 | **No Divergence** → No-op |
| `stack_ptr > wr_ptr` | 컴파일러 오류 (불가능) | - |

---

## 시나리오별 Divergence 판단

### 시나리오 1: 실제 Divergence (ptr ≠)

```c
if (threadIdx.x < 4) {  // SPLIT, depth=0, is_dvg=1
    // Then path (threads 0-3)
    x = a + b;
} else {                // JOIN #1, depth=0
    // Else path (threads 4-7)
    x = a - b;
}                       // JOIN #2, depth=0
```

**SPLIT 실행** (Divergence 발생):
```
Condition: threads 0-3 = true, threads 4-7 = false
split.is_dvg = 1 (실제 분기!)

ipdom_push = 1
ipdom_wr_ptr[0] = 0 → 1
Stack = [{idx=0, else_info, then_info}]
```

**JOIN #1** (Then path 끝):
```
sjoin.stack_ptr = 0 (컴파일러: "depth 0 SPLIT과 매칭")
ipdom_wr_ptr[0] = 1 (현재 stack top)

비교: 0 != 1 → sjoin_is_dvg = 1 ✓ (Divergence 중!)

동작:
  - ipdom_pop = 1 → Stack 읽기
  - q_idx = 0 → q1 선택 (else path)
  - Stack write: idx=1로 업데이트
  - ipdom_wr_ptr[0] = 1 (유지)
  - join_is_else = 1 (else path로 전환)
```

**JOIN #2** (Else path 끝):
```
sjoin.stack_ptr = 0 (동일한 SPLIT)
ipdom_wr_ptr[0] = 1

비교: 0 != 1 → sjoin_is_dvg = 1 ✓ (아직 Divergence!)

동작:
  - ipdom_pop = 1 → Stack 읽기
  - q_idx = 1 → q0 선택 (convergence)
  - Stack pop: 완전히 제거
  - ipdom_wr_ptr[0] = 0 (감소)
  - join_is_else = 0 (convergence!)
```

### 시나리오 2: Uniform 조건 (ptr =)

```c
if (true) {         // SPLIT, depth=0, is_dvg=0
    // Then path (모든 threads)
    x = a + b;
} else {
    // Else path (실행 안됨)
}                   // JOIN, depth=0
```

**SPLIT 실행** (No Divergence):
```
Condition: 모든 threads = true
split.is_dvg = 0 (분기 없음!)

ipdom_push = split_valid && split.is_dvg = 0 (push 안함!)
ipdom_wr_ptr[0] = 0 (그대로)
Stack = [  ] (비어 있음)
```

**JOIN 실행**:
```
sjoin.stack_ptr = 0 (컴파일러 지정)
ipdom_wr_ptr[0] = 0 (변화 없음)

비교: 0 == 0 → sjoin_is_dvg = 0 ✓ (No divergence!)

동작:
  - ipdom_pop = 0 → Stack 건드리지 않음
  - join_valid = 1 (하지만 no-op)
  - join_is_dvg = 0
  - 그냥 통과 (완전 bypass!)
```

**성능 최적화**:
- Stack 읽기/쓰기 **0회**
- BRAM 접근 없음 → 전력 절약
- Latency 없음

### 시나리오 3: 중첩 If (Multiple ptr)

```c
if (cond1) {        // SPLIT #1, depth=0
    if (cond2) {    // SPLIT #2, depth=1
        // A
    } else {        // JOIN #2-1, depth=1
        // B
    }               // JOIN #2-2, depth=1
} else {            // JOIN #1-1, depth=0
    // C
}                   // JOIN #1-2, depth=0
```

**실행 흐름 및 Pointer 추적**:

```
초기:
  ipdom_wr_ptr[0] = 0
  Stack = [  ]

SPLIT #1 (depth=0):
  ipdom_wr_ptr[0] = 0 → 1
  Stack = [{SPLIT #1}]

SPLIT #2 (depth=1, Then path 내부):
  ipdom_wr_ptr[0] = 1 → 2
  Stack = [{SPLIT #1}, {SPLIT #2}]

JOIN #2-1 (Path A 끝):
  sjoin.stack_ptr = 1 (SPLIT #2와 매칭)
  ipdom_wr_ptr[0] = 2
  
  비교: 1 != 2 → sjoin_is_dvg = 1 ✓ (SPLIT #2 divergence 중)
  Pop: q_idx=0 → wr_ptr 유지 (2)

JOIN #2-2 (Path B 끝):
  sjoin.stack_ptr = 1 (SPLIT #2와 매칭)
  ipdom_wr_ptr[0] = 2
  
  비교: 1 != 2 → sjoin_is_dvg = 1 ✓ (SPLIT #2 convergence)
  Pop: q_idx=1 → wr_ptr 감소 (1)
  Stack = [{SPLIT #1}]

JOIN #1-1 (Then path 전체 끝):
  sjoin.stack_ptr = 0 (SPLIT #1과 매칭)
  ipdom_wr_ptr[0] = 1
  
  비교: 0 != 1 → sjoin_is_dvg = 1 ✓ (SPLIT #1 divergence 중)
  Pop: q_idx=0 → wr_ptr 유지 (1)

JOIN #1-2 (Else path 끝):
  sjoin.stack_ptr = 0 (SPLIT #1과 매칭)
  ipdom_wr_ptr[0] = 1
  
  비교: 0 != 1 → sjoin_is_dvg = 1 ✓ (SPLIT #1 convergence)
  Pop: q_idx=1 → wr_ptr 감소 (0)
  Stack = [  ]
```

### Pointer 비교 다이어그램

```
Stack Depth:    2         1         0
                │         │         │
SPLIT #2  ──────┤         │         │  wr_ptr = 2
                │         │         │  
JOIN #2-1 ──────┤         │         │  sjoin.ptr=1, wr_ptr=2 → dvg=1
JOIN #2-2 ──────┘         │         │  sjoin.ptr=1, wr_ptr=2 → dvg=1
                          │         │  (pop 후 wr_ptr=1)
                          │         │
SPLIT #1  ────────────────┤         │  wr_ptr = 1
                          │         │
JOIN #1-1 ────────────────┤         │  sjoin.ptr=0, wr_ptr=1 → dvg=1
JOIN #1-2 ────────────────┘         │  sjoin.ptr=0, wr_ptr=1 → dvg=1
                                    │  (pop 후 wr_ptr=0)
                                    │
CONVERGE ───────────────────────────┘  wr_ptr = 0
```

---

## Compiler와 Hardware의 협력

### Compiler의 역할

**1. Stack Depth 할당**:
```asm
SPLIT r1, .else_label, .next_label   # depth=0 (implicit)
  # Then path
  ...
JOIN  0                              # stack_ptr=0 (explicit!)
.else_label:
  # Else path
  ...
JOIN  0                              # stack_ptr=0 (same SPLIT)
.next_label:
  # Convergence
```

**2. 중첩 IF 처리**:
```asm
SPLIT r1, .else1, .next1             # depth=0
  # Then path
  SPLIT r2, .else2, .next2           # depth=1
    # A
  JOIN  1                            # stack_ptr=1 (SPLIT #2)
  .else2:
    # B
  JOIN  1                            # stack_ptr=1 (SPLIT #2)
  .next2:
JOIN  0                              # stack_ptr=0 (SPLIT #1)
.else1:
  # C
JOIN  0                              # stack_ptr=0 (SPLIT #1)
.next1:
```

### Hardware의 역할

**Runtime Divergence 판단**:
```systemverilog
// VX_split_join.sv
always @(*) begin
    // 각 JOIN마다:
    // 1. 컴파일러가 준 stack_ptr 읽기
    // 2. 현재 runtime wr_ptr과 비교
    // 3. 같으면 no-op, 다르면 pop
    
    if (sjoin.stack_ptr == ipdom_wr_ptr[wid]) begin
        // 이미 convergence 완료 → bypass
        ipdom_pop = 0;
    end else begin
        // 아직 divergence 중 → stack 처리
        ipdom_pop = 1;
    end
end
```

### 협력의 이점

| 역할 | Compiler | Hardware |
|------|----------|----------|
| **Static** | Stack depth 할당 | - |
| **Dynamic** | - | Divergence 여부 판단 |
| **최적화** | No-op JOIN 명령어 생성 | No-op 감지 시 bypass |
| **정확성** | Structured 구조 보장 | Pointer 비교로 검증 |

---

## 왜 이렇게 설계했을까?

## 왜 이렇게 설계했을까?

### 1. **No-op JOIN 최적화**

**Uniform 조건 시**:
```
모든 thread가 동일한 분기:
- SPLIT → is_dvg=0 → push 안함
- JOIN → stack_ptr == wr_ptr → pop 안함
→ Stack 접근 0회! BRAM 전력 절약
```

**성능 이득**:
- BRAM 읽기/쓰기 없음
- Latency 0 cycle
- 전력 소비 최소화

### 2. **중첩 Divergence 완벽 지원**

**Stack Pointer 비교로 Level 식별**:
```systemverilog
JOIN depth=2: sjoin.ptr=2, wr_ptr=3 → Pop from level 3
JOIN depth=1: sjoin.ptr=1, wr_ptr=2 → Pop from level 2  
JOIN depth=0: sjoin.ptr=0, wr_ptr=1 → Pop from level 1
```

각 JOIN이 어느 SPLIT과 매칭되는지 명확히 추적!

### 3. **Compiler-Hardware 분업**

**Compiler (Static)**:
- Stack depth 할당 (컴파일 타임)
- Structured control flow 보장
- 최적화 기회 식별 (uniform branch)

**Hardware (Dynamic)**:
- Runtime divergence 판단
- Actual branch 결과에 따라 처리
- Pointer 비교만으로 간단히 결정

### 4. **메모리 효율성**

**일반적인 Stack 방식** (비효율):
```
SPLIT: Push {else_info}
JOIN #1: Pop → Push {marker}
JOIN #2: Pop
→ 3번의 BRAM 접근
```

**IPDOM Stack 방식** (효율):
```
SPLIT: Push {idx=0, else, then}  (1번)
JOIN #1: Pop & Write {idx=1, else, then}  (1번)
JOIN #2: Pop  (1번)
→ 3번의 BRAM 접근이지만, 정보 손실 없음
→ Pointer 비교로 no-op 최적화 가능
```

### 5. **정확성 보장**

**컴파일러 오류 감지**:
```systemverilog
if (sjoin.stack_ptr > ipdom_wr_ptr[wid]) begin
    // 컴파일러가 잘못된 depth 할당!
    $error("Stack underflow!");
end
```

Runtime에 structured control flow 위반 감지 가능!

---

## 주요 파일 위치

| 파일 | 역할 | 핵심 코드 |
|------|------|----------|
| [hw/rtl/core/VX_ipdom_stack.sv](hw/rtl/core/VX_ipdom_stack.sv#L120) | IPDOM Stack 구현 | `wdata = push ? {0, d1, d0} : {1, q1, q0}` |
| [hw/rtl/core/VX_split_join.sv](hw/rtl/core/VX_split_join.sv#L46) | SPLIT/JOIN 제어 | `ipdom_d0/d1` 생성, `join_is_else` 계산 |
| [hw/rtl/core/VX_schedule.sv](hw/rtl/core/VX_schedule.sv#L153) | Schedule 통합 | JOIN 신호 처리 |

---

## 디버깅 팁

### RTL Trace

```systemverilog
// VX_ipdom_stack.sv에 추가
`ifdef DBG_TRACE_CORE_PIPELINE
    always @(posedge clk) begin
        if (push) begin
            $display("[%0t] IPDOM PUSH: wid=%0d, ptr=%0d→%0d, d0={%b,%h}, d1={%b,%h}", 
                     $time, wid, wr_ptr_w[wid], wr_ptr_w[wid]+1, 
                     d0[`NUM_THREADS-1:0], d0[PC_BITS-1:0],
                     d1[`NUM_THREADS-1:0], d1[PC_BITS-1:0]);
        end
        
        if (pop) begin
            $display("[%0t] IPDOM POP: wid=%0d, ptr=%0d→%0d, idx=%0d, q_val={%b,%h}", 
                     $time, wid, wr_ptr_w[wid], wr_ptr_w[wid]-q_idx,
                     q_idx, q_val[`NUM_THREADS-1:0], q_val[PC_BITS-1:0]);
        end
    end
`endif
```

### 예상 출력

```
[100] IPDOM PUSH: wid=0, ptr=0→1, d0={11111111,00000000}, d1={00001111,00001008}
[200] IPDOM POP: wid=0, ptr=1→1, idx=0, q_val={00001111,00001008}
[300] IPDOM POP: wid=0, ptr=1→0, idx=1, q_val={11111111,00000000}
```

---

## 요약

| 항목 | 내용 |
|------|------|
| **목적** | SPLIT/JOIN의 path 추적 및 convergence 관리 |
| **핵심 메커니즘** | Pop 시 Read-Modify-Write로 idx 업데이트 |
| **Divergence 판단** | `sjoin.stack_ptr != ipdom_wr_ptr[wid]` |
| **q_idx 의미** | 0 = Then path 실행 필요<br>1 = Else path/Convergence |
| **q0 (d0)** | Then path 또는 Convergence 정보 |
| **q1 (d1)** | Else path 정보 |
| **Write Pointer** | PUSH → +1, POP → -q_idx (0 또는 1) |
| **No-op 최적화** | stack_ptr == wr_ptr → Stack bypass |
| **특이점** | 첫 번째 JOIN은 pop만 하고 다시 저장 (제거 안함) |

### 핵심 개념 정리

**1. IPDOM Stack = Path Selection State Machine**
- 단순한 Stack이 아닌, **어느 path를 실행했는지 추적**하는 FSM
- `q_idx`로 state 관리: 0 (Then 차례) → 1 (Else/Convergence 차례)

**2. Divergence 판단 = Compiler + Hardware 협력**
- **Compiler**: 각 JOIN에 `stack_ptr` immediate 할당 (static)
- **Hardware**: Runtime에 `wr_ptr`과 비교 (dynamic)
- 같으면 no-op, 다르면 실제 JOIN 처리

**3. 최적화 = No-op JOIN Bypass**
- Uniform 분기: SPLIT push 안함 → JOIN도 pop 안함
- BRAM 접근 0회 → 전력 절약, latency 제거

**4. 중첩 지원 = Multi-level Stack Pointer**
- 각 SPLIT이 다른 depth에 저장
- JOIN의 `stack_ptr`로 매칭되는 SPLIT 식별
- Nested if-else 완벽 처리

**핵심**: IPDOM Stack은 Compiler가 지정한 구조(stack_ptr)와 Hardware가 추적하는 상태(wr_ptr, q_idx)를 결합하여, **structured control flow를 효율적으로 구현**합니다!

---

## dvstack_wid/dvstack_ptr: Software-Hardware 인터페이스

### 개요

**dvstack (Divergence Stack)** 신호는 SPLIT 명령어가 현재 IPDOM stack depth를 software에게 알려주는 메커니즘입니다. 이를 통해 compiler가 control flow를 추적하고, JOIN 명령어에서 올바른 stack depth를 검증할 수 있습니다.

### 1. Software Level 사용

#### C Intrinsics
```cpp
// vx_split이 stack pointer를 반환
int sp1 = vx_split(condition);
// ... divergent code ...
vx_join(sp1);  // stack pointer를 JOIN에 전달
```

#### 실제 사용 예제 (Nested Divergence)
```cpp
int sp1 = vx_split(cond1);
{
    // Then path
    int sp2 = vx_split(cond2);
    {
        // Nested then
    }
    vx_join(sp2);
}
{
    // Else path
    int sp3 = vx_split(cond3);
    {
        // Another nested divergence
    }
    vx_join(sp3);
}
vx_join(sp1);
```

#### Assembly 인코딩
```assembly
# SPLIT 명령어 - rd 레지스터에 dvstack_ptr 저장
.insn r CUSTOM0, 2, 0, rd, predicate, x0

# JOIN 명령어 - rs1 레지스터에서 stack_ptr 읽음
.insn r CUSTOM0, 3, 0, x0, stack_ptr, x0
```

**핵심**: SPLIT은 return value가 있고, JOIN은 argument가 있습니다!

### 2. Hardware Pipeline 흐름

#### SPLIT 명령어: dvstack_ptr을 레지스터에 쓰기

```
┌─────────────────────────────────────────────────────────────┐
│ 1. VX_execute → VX_wctl_unit                                │
│    - is_split = 1 감지                                       │
│    - warp_ctl_if.dvstack_wid = execute_if.data.wid         │
│      (현재 warp ID 설정)                                     │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. VX_schedule → VX_split_join                              │
│    - split_join.stack_wid = warp_ctl_if.dvstack_wid        │
│    - split_join.stack_ptr = ipdom_wr_ptr[stack_wid]        │
│      (현재 IPDOM stack pointer 읽기)                        │
│    - warp_ctl_if.dvstack_ptr = split_join.stack_ptr        │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. VX_wctl_unit → VX_result                                 │
│    - Elastic buffer를 통해 dvstack_ptr 전달                │
│    - result_if.data.data[i] = dvstack_ptr                  │
│      (모든 lane에 동일 값)                                  │
│    - result_if.data.wb = 1  (writeback enable)             │
│    - result_if.data.rd = destination register              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. Writeback Stage                                           │
│    - Register File에 dvstack_ptr 기록                       │
│    - Software가 이 값을 나중에 JOIN에 사용                  │
└─────────────────────────────────────────────────────────────┘
```

#### JOIN 명령어: stack_ptr을 immediate로 사용

```
┌─────────────────────────────────────────────────────────────┐
│ 1. VX_decode → VX_execute                                    │
│    - JOIN 명령어 디코딩                                      │
│    - rs1_data = 레지스터에서 읽은 stack_ptr 값              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. VX_wctl_unit                                              │
│    - sjoin.valid = 1                                         │
│    - sjoin.stack_ptr = rs1_data[DV_STACK_SIZEW-1:0]        │
│      (software가 제공한 값)                                  │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. VX_schedule → VX_split_join                              │
│    - sjoin.stack_ptr (software) vs ipdom_wr_ptr (hardware) │
│      비교                                                    │
│    - sjoin_is_dvg = (sjoin.stack_ptr != ipdom_wr_ptr[wid]) │
│    - is_dvg이면 IPDOM stack에서 PC/tmask 복원              │
└─────────────────────────────────────────────────────────────┘
```

### 3. 코드 구현

#### VX_wctl_unit.sv
```systemverilog
// Line 155: dvstack_wid 설정
assign warp_ctl_if.dvstack_wid = execute_if.data.wid;
wire [DV_STACK_SIZEW-1:0] dvstack_ptr;

// Line 166-167: Elastic buffer를 통한 dvstack_ptr 전달
VX_elastic_buffer #(
    .DATAW (DATAW),
    .SIZE  (2)
) rsp_buf (
    .clk       (clk),
    .reset     (reset),
    .valid_in  (execute_if.valid),
    .ready_in  (execute_if.ready),
    .data_in   ({..., warp_ctl_if.dvstack_ptr}),
    .data_out  ({..., dvstack_ptr}),
    .valid_out (result_if.valid),
    .ready_out (result_if.ready)
);

// Line 186-188: Result data로 출력
for (genvar i = 0; i < NUM_LANES; ++i) begin : g_result_if
    assign result_if.data.data[i] = `XLEN'(dvstack_ptr);
end
```

#### VX_schedule.sv
```systemverilog
// Line 303-304: split_join 모듈 연결
VX_split_join split_join (
    ...
    .stack_wid  (warp_ctl_if.dvstack_wid),
    .stack_ptr  (warp_ctl_if.dvstack_ptr)
);
```

#### VX_split_join.sv
```systemverilog
// Line 26-33: 인터페이스
input  wire [NW_WIDTH-1:0]       stack_wid,   // 읽을 warp ID
output wire [DV_STACK_SIZEW-1:0] stack_ptr    // 해당 warp의 stack pointer

// Line 87: 구현
assign stack_ptr = ipdom_wr_ptr[stack_wid];
```

### 4. 핵심 포인트

#### 1) dvstack의 용도
- **SPLIT 명령어의 return value**: Hardware가 현재 IPDOM stack depth를 반환
- **JOIN 명령어의 argument**: Software가 저장한 depth를 전달하여 검증
- **Nested divergence 처리**: 각 SPLIT이 고유한 depth를 반환, JOIN에서 매칭

#### 2) 왜 필요한가?
- **Compiler의 Control Flow 추적**: Compiler가 각 SPLIT/JOIN 쌍을 추적
- **Runtime 검증**: Hardware가 올바른 stack depth에서 JOIN이 실행되는지 확인
- **중첩 처리**: Nested if-else에서 올바른 JOIN을 찾기 위한 식별자 역할

#### 3) 데이터 경로
```
SPLIT: IPDOM Stack → dvstack_ptr → Register File → Software (C Variable)
       ipdom_wr_ptr    hardware      writeback       int sp = vx_split()

JOIN:  Software → Register (rs1) → sjoin.stack_ptr → Compare with IPDOM Stack
       vx_join(sp)    read          decode           sjoin_is_dvg check
```

#### 4) 안전성 메커니즘
- **Compiler 책임**: SPLIT/JOIN을 올바르게 짝 맞춰야 함
- **Hardware 검증**: Runtime에 `sjoin_is_dvg` 플래그로 검증
  ```systemverilog
  sjoin_is_dvg = (sjoin.stack_ptr != ipdom_wr_ptr[wid])
  ```
- **Stack pointer 불일치**: 아직 실행할 path가 남아있음 (divergence)
- **Stack pointer 일치**: 모든 path 완료 (convergence)

### 5. 실행 시나리오

#### 시나리오 1: Simple Divergence
```cpp
int sp = vx_split(condition);  // sp = 1 (hardware에서 반환)
// ... divergent code ...
vx_join(sp);  // sp == ipdom_wr_ptr[wid] → Convergence
```

**Hardware 상태**:
```
SPLIT: ipdom_wr_ptr[wid] = 0 → 1, dvstack_ptr = 1 → sp
JOIN:  sjoin.stack_ptr = 1 (from sp), ipdom_wr_ptr[wid] = 1
       sjoin_is_dvg = (1 != 1) = 0 → Convergence!
```

#### 시나리오 2: Nested Divergence
```cpp
int sp1 = vx_split(cond1);    // sp1 = 1
{
    int sp2 = vx_split(cond2);  // sp2 = 2
    // ...
    vx_join(sp2);  // sp2 = 2, wr_ptr = 2 → Convergence at level 2
}
vx_join(sp1);  // sp1 = 1, wr_ptr = 1 → Convergence at level 1
```

**Hardware 상태**:
```
SPLIT 1: wr_ptr = 0 → 1, dvstack_ptr = 1
SPLIT 2: wr_ptr = 1 → 2, dvstack_ptr = 2
JOIN 2:  sjoin.stack_ptr = 2, wr_ptr = 2 → Convergence (level 2 완료)
         wr_ptr = 2 → 1 (pop)
JOIN 1:  sjoin.stack_ptr = 1, wr_ptr = 1 → Convergence (level 1 완료)
         wr_ptr = 1 → 0 (pop)
```

### 6. 요약 비교

| 항목 | SPLIT | JOIN |
|------|-------|------|
| **Software API** | `int sp = vx_split(cond)` | `vx_join(sp)` |
| **Return/Arg** | Return: stack pointer | Argument: stack pointer |
| **Register** | rd (destination) | rs1 (source) |
| **dvstack_ptr** | Hardware → Software | Software → Hardware |
| **Hardware 동작** | Read ipdom_wr_ptr → writeback | Read rs1 → compare with wr_ptr |
| **목적** | 현재 depth 알림 | JOIN 검증 및 convergence |

### 7. 핵심 인사이트

**1. Compiler-Hardware 협업**
- Compiler: Control flow structure를 static하게 분석
- Hardware: Runtime에 dynamic하게 추적 및 검증
- dvstack: 두 세계를 연결하는 인터페이스!

**2. Stack Pointer의 이중 역할**
- **Identifier**: 어느 SPLIT/JOIN 쌍인지 식별
- **Validator**: Runtime에 올바른 depth인지 검증

**3. 최적화 가능성**
- Uniform 분기: dvstack_ptr은 반환되지만 사용 안됨 (wr_ptr 변화 없음)
- Compiler 최적화: Dead code elimination 가능

**4. 디버깅 지원**
- Software가 stack depth를 알 수 있음
- Divergence 상태를 explicit하게 추적 가능
- 중첩 레벨을 integer로 확인 가능

**핵심**: dvstack_wid/ptr은 단순한 hardware signal이 아닌, **Compiler와 Hardware가 SPLIT/JOIN을 협력하여 처리하는 계약(contract)**입니다!

---

*문서 작성일: 2025-12-22*  
*최종 업데이트: 2025-12-22 (dvstack 섹션 추가)*  
*Vortex GPGPU Project - IPDOM Stack Mechanism Analysis*
