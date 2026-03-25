# SPLIT/JOIN 상세 동작 분석: LLVM Pass와 RTL 통합 분석

## 개요

이 문서는 Vortex의 SPLIT/JOIN 메커니즘을 LLVM Pass와 RTL 하드웨어 구현을 함께 분석하여, **else basic block이 실행되는 원리**를 상세히 설명합니다.

---

## 핵심 질문에 대한 답변

### Q1: vx_join을 만나면 vx_join이 else basic block으로 jump하는가?
**A: 아니요, vx_join 명령어 자체는 jump하지 않습니다.** 대신 하드웨어가 **PC를 변경**하고 **thread mask를 업데이트**합니다.

### Q2: else block이 끝나면 다시 vx_join을 만나는데 이때는 무슨 일이 발생하는가?
**A: IPDOM stack의 `fallthrough` 플래그를 확인합니다.** 첫 번째 vx_join에서는 else 경로로 전환, 두 번째 vx_join에서는 stack을 pop하고 원래 mask로 복원합니다.

---

## 1. LLVM Pass: 어떻게 SPLIT/JOIN이 삽입되는가

### 1.1. 소스 코드 예시

```c
void example(int tid) {
    int result;
    if (tid < 2) {           // ← Divergent Branch
        result = 65;         // Then Block
    } else {
        result = 66;         // Else Block
    }
    buffer[tid] = result;    // ← Re-convergence Point (IPDOM)
}
```

### 1.2. LLVM IR 변환 과정

**Before VortexBranchDivergence Pass:**
```llvm
entry:
  %cond = icmp slt i32 %tid, 2
  br i1 %cond, label %then, label %else

then:
  store i32 65, i32* %result
  br label %merge

else:
  store i32 66, i32* %result
  br label %merge

merge:
  %val = load i32, i32* %result
  %ptr = getelementptr i32, i32* %buffer, i32 %tid
  store i32 %val, i32* %ptr
  ret void
```

**After VortexBranchDivergence Pass:**
```llvm
entry:
  %cond = icmp slt i32 %tid, 2
  %stack_ptr = call i32 @llvm.riscv.vx.split(i1 %cond)  ; ← SPLIT inserted
  br i1 %cond, label %then, label %else

then:
  store i32 65, i32* %result
  br label %join_stub_then                              ; ← jump to join_stub

else:
  store i32 66, i32* %result
  br label %join_stub_else                              ; ← jump to join_stub

join_stub_then:
  call void @llvm.riscv.vx.join(i32 %stack_ptr)        ; ← JOIN inserted (first)
  br label %merge

join_stub_else:
  call void @llvm.riscv.vx.join(i32 %stack_ptr)        ; ← JOIN inserted (second)
  br label %merge

merge:
  %val = load i32, i32* %result
  %ptr = getelementptr i32, i32* %buffer, i32 %tid
  store i32 %val, i32* %ptr
  ret void
```

### 1.3. LLVM Pass 코드 분석

**VortexBranchDivergence1::processBranch()** ([VortexBranchDivergence.cpp](https://github.com/vortexgpgpu/vortex/blob/main/llvm/lib/Target/RISCV/VortexBranchDivergence.cpp)):

```cpp
// 1. IPDOM (Re-convergence Point) 찾기
auto ipdom = PDT.getNode(block)->getIDom()->getBlock();

// 2. SPLIT 삽입 (분기 직전)
auto stack_ptr = CallInst::Create(split_func_, cond, "", branch);

// 3. Join Stub 블록 생성 및 JOIN 삽입 (IPDOM 직전)
auto stub = BasicBlock::Create(*context, "join_stub", function, ipdom);
auto stub_br = BranchInst::Create(ipdom, stub);
CallInst::Create(join_func_, stack_ptr, "", stub_br);

// 4. IPDOM으로 가는 엣지를 Join Stub로 우회
FindSuccessor(block, ipdom, preds);
for (auto pred : preds) {
  replaceSuccessor_.replaceSuccessor(pred, ipdom, stub);
}
```

**핵심 포인트**:
- **각 경로(then/else)마다 별도의 join_stub**를 만들어 vx_join을 삽입
- IPDOM(merge 블록)으로 가는 모든 엣지를 join_stub로 우회
- 결과적으로 **then 블록 끝에 한 번, else 블록 끝에 한 번, 총 2번 vx_join 호출**

---

## 2. RTL 하드웨어: SPLIT/JOIN의 실제 동작

### 2.1. IPDOM Stack 구조

**VX_ipdom_stack.sv**는 **이중 슬롯 구조**를 사용합니다:

```systemverilog
// SPLIT 시 push되는 데이터
wire [NUM_THREADS + PC_BITS-1:0] ipdom_d0 = {then_tmask | else_tmask, PC'(0)};
wire [NUM_THREADS + PC_BITS-1:0] ipdom_d1 = {else_tmask, next_pc};

// Push: d0와 d1을 동시에 저장, q_idx = 0으로 초기화
.wdata (push ? {1'b0, d1, d0} : {1'b1, q1, q0})

// Pop: q_idx에 따라 d0 또는 d1을 읽음
.q_val (q_idx ? d0 : d1)
```

**Stack Entry 구조** ([sim/simx/emulator.h:38](../../sim/simx/emulator.h#L38)):
```cpp
struct ipdom_entry_t {
  ThreadMask orig_tmask;   // = then_tmask | else_tmask (모든 threads)
  ThreadMask else_tmask;   // 나중에 실행할 threads
  Word PC;                 // else 경로의 PC (실제로는 merge 블록 PC)
  bool fallthrough;        // false: 첫 join, true: 두 번째 join
};
```

### 2.2. SPLIT 명령어 파라미터

README에서는 `SPLIT taken, predicate`라고 되어 있지만, 실제로는:

**어셈블리 인코딩** ([vx_intrinsics.h:134](../../kernel/include/vx_intrinsics.h#L134)):
```c
// vx_split(predicate)
.insn r RISCV_CUSTOM0, 2, 0, rd, rs1, x0
// rd  = stack_ptr (반환값)
// rs1 = predicate (각 thread의 조건 값)
// rs2 = x0 (always 0)

// vx_split_n(predicate) - Negated version
.insn r RISCV_CUSTOM0, 2, 0, rd, rs1, x1
// rs2 = x1 (is_neg flag)
```

**RTL Decode** ([VX_decode.sv:483](../../hw/rtl/core/VX_decode.sv#L483)):
```systemverilog
3'h2: begin // SPLIT
    op_type = INST_OP_BITS'(INST_SFU_SPLIT);
    op_args.wctl.is_neg = rs2[0];  // ← rs2의 LSB가 is_neg flag
    `USED_IREG (rs1);              // ← predicate
    `USED_IREG (rd);               // ← stack_ptr 저장
end
```

**시뮬레이터** ([sim/simx/decode.cpp:1014](../../sim/simx/decode.cpp#L1014)):
```cpp
case 2: // SPLIT
  instr->setOpType(WctlType::SPLIT);
  instr->setDestReg(rd, RegType::Integer);     // stack_ptr
  instr->setSrcReg(0, rs1, RegType::Integer);  // predicate
  wctlArgs.is_neg = (rs2 != 0);                // is_neg flag
  break;
```

**파라미터 의미**:

| 파라미터 | README 표현 | 실제 의미 | 레지스터 | 설명 |
|---------|------------|---------|----------|------|
| **predicate** | predicate | 조건 값 | rs1 | 각 thread의 분기 조건 (0 또는 1) |
| **taken** | taken | is_neg flag | rs2[0] | 0=정상, 1=조건 반전 (vx_split_n) |
| **(반환값)** | - | stack_ptr | rd | IPDOM stack의 현재 depth |

**중요**: "taken"은 실제로는 **is_neg (negation flag)**를 의미합니다:
- `vx_split(cond)`: rs2 = 0, 조건 그대로 사용
- `vx_split_n(cond)`: rs2 = 1, 조건 반전 사용

### 2.3. SPLIT 동작 (VX_wctl_unit.sv + VX_split_join.sv)

#### Step 1: Condition 평가 및 Mask 계산

```systemverilog
// VX_wctl_unit.sv:71-99
wire not_pred = execute_if.data.op_args.wctl.is_neg;  // rs2[0]

// 각 thread의 조건 평가 (XOR로 negation 처리)
for (genvar i = 0; i < NUM_LANES; ++i) begin
    assign taken[i] = (execute_if.data.rs1_data[i][0] ^ not_pred);
end
assign then_tmask = taken & execute_if.data.tmask;
assign else_tmask = ~taken & execute_if.data.tmask;

wire has_then = (then_tmask != 0);
wire has_else = (else_tmask != 0);
```

**시뮬레이터** ([sim/simx/execute.cpp:1333](../../sim/simx/execute.cpp#L1333)):
```cpp
auto not_pred = wctlArgs.is_neg;
for (uint32_t t = 0; t < num_threads; ++t) {
  auto cond = (rs1_data.at(t).i & 0x1) ^ not_pred;  // XOR로 negation
  then_tmask[t] = warp.tmask.test(t) && cond;
  else_tmask[t] = warp.tmask.test(t) && !cond;
}
```

**예시**: `vx_split(tid < 2)`, 활성 threads = 0,1,2,3
- rs1[0] = 1 (tid=0 < 2)
- rs1[1] = 1 (tid=1 < 2)
- rs1[2] = 0 (tid=2 >= 2)
- rs1[3] = 0 (tid=3 >= 2)
- `not_pred = 0` (vx_split)
- `then_tmask = 0b0011` (thread 0, 1)
- `else_tmask = 0b1100` (thread 2, 3)
- `has_then = 1`, `has_else = 1` → **Divergent!**

#### Step 2: 먼저 실행할 경로 선택

```systemverilog
// VX_wctl_unit.sv:113-117
wire then_first = (then_tmask_cnt >= else_tmask_cnt);
wire taken_tmask = then_first ? then_tmask : else_tmask;
wire ntaken_tmask = then_first ? else_tmask : then_tmask;

assign split.then_tmask = taken_tmask;   // 먼저 실행
assign split.else_tmask = ntaken_tmask;  // 나중에 실행
```

**예시**: thread 수가 같으므로 then_first = true
- `split.then_tmask = 0b0011` (먼저 실행)
- `split.else_tmask = 0b1100` (stack에 저장)

#### Step 3: IPDOM Stack에 Push

```systemverilog
// VX_split_join.sv:46-54
wire ipdom_d0 = {then_tmask | else_tmask, PC'(0)};  // {0b1111, 0}
wire ipdom_d1 = {else_tmask, next_pc};              // {0b1100, merge_PC}

wire ipdom_push = split_valid && split.is_dvg;

VX_ipdom_stack ipdom_stack (
  .d0(ipdom_d0),  // Slot 0: 원래 모든 threads + dummy PC
  .d1(ipdom_d1),  // Slot 1: else threads + merge PC
  .push(ipdom_push),
  ...
);
```

**Stack 상태 (Push 후)**:
```
Stack Top:
  q_idx = 0 (fallthrough = false)
  Slot 0 (d0): {orig_tmask: 0b1111, PC: 0}
  Slot 1 (d1): {else_tmask: 0b1100, PC: merge_PC}
```

#### Step 4: Thread Mask 업데이트

```systemverilog
// VX_schedule.sv:145-150
if (warp_ctl_if.split.valid && warp_ctl_if.split.is_dvg) begin
    thread_masks_n[warp_ctl_if.wid] = warp_ctl_if.split.then_tmask;
end
```

**결과**: `thread_masks[wid] = 0b0011` → **thread 0, 1만 활성화**

---

### 2.3. 첫 번째 JOIN 동작 (Then 블록 끝)

#### Step 1: Stack Pointer 확인

```systemverilog
// VX_split_join.sv:49
wire sjoin_is_dvg = (sjoin.stack_ptr != ipdom_wr_ptr[wid]);
```

**시뮬레이터 코드** ([sim/simx/execute.cpp:1364](../../sim/simx/execute.cpp#L1364)):
```cpp
auto stack_ptr = rs1_data.at(thread_last).u;  // SPLIT에서 반환받은 값
if (stack_ptr != warp.ipdom_stack.size()) {   // 0 != 1 → Divergent!
```

**조건**: `stack_ptr (0) != wr_ptr (1)` → **Divergent JOIN**

#### Step 2: Stack에서 읽기 (Pop 아님!)

```systemverilog
// VX_ipdom_stack.sv:110-113
.rd_ptr(sjoin.stack_ptr),  // = 0
.q_val({ipdom_tmask, ipdom_pc}),
.q_idx(ipdom_idx)          // = 0 (fallthrough = false)
```

**q_idx = 0이므로 d1(Slot 1)을 읽음**:
- `ipdom_tmask = 0b1100` (else_tmask)
- `ipdom_pc = merge_PC`

#### Step 3: Pop 신호 및 Fallthrough 설정

```systemverilog
// VX_split_join.sv:51
wire ipdom_pop = sjoin_valid && sjoin_is_dvg;

// VX_ipdom_stack.sv:113-114
.wdata(push ? {1'b0, d1, d0} : {1'b1, q1, q0})  // Pop 시: q_idx = 1로 업데이트
```

**시뮬레이터 코드**:
```cpp
if (!warp.ipdom_stack.top().fallthrough) {
  next_tmask = warp.ipdom_stack.top().else_tmask;  // 0b1100
  next_pc = warp.ipdom_stack.top().PC;             // merge_PC
  warp.ipdom_stack.top().fallthrough = true;       // ← 중요!
}
```

**Stack 상태 (Pop 후)**:
```
Stack Top (여전히 남아있음):
  q_idx = 1 (fallthrough = true)  ← 변경됨!
  Slot 0 (d0): {orig_tmask: 0b1111, PC: 0}
  Slot 1 (d1): {else_tmask: 0b1100, PC: merge_PC}
```

#### Step 4: PC 및 Thread Mask 업데이트

```systemverilog
// VX_schedule.sv:153-158
if (join_valid && join_is_dvg) begin
    if (join_is_else) begin
        warp_pcs_n[join_wid] = join_pc;        // merge_PC로 jump!
    end
    thread_masks_n[join_wid] = join_tmask;     // 0b1100
end
```

**결과**:
- `PC = merge_PC` (else 블록으로 jump!)
- `thread_masks[wid] = 0b1100` → **thread 2, 3만 활성화**

---

### 2.4. 두 번째 JOIN 동작 (Else 블록 끝)

#### Step 1: Stack Pointer 재확인

```cpp
auto stack_ptr = rs1_data.at(thread_last).u;  // 여전히 0
if (stack_ptr != warp.ipdom_stack.size()) {   // 0 != 1 → Divergent!
```

#### Step 2: Fallthrough 확인

```systemverilog
// VX_ipdom_stack.sv:110-113
.rd_ptr(sjoin.stack_ptr),  // = 0
.q_idx(ipdom_idx)          // = 1 (fallthrough = true)
```

**q_idx = 1이므로 d0(Slot 0)을 읽음**:
- `ipdom_tmask = 0b1111` (orig_tmask)
- `ipdom_pc = 0` (dummy)

**시뮬레이터 코드**:
```cpp
if (warp.ipdom_stack.top().fallthrough) {     // true!
  next_tmask = warp.ipdom_stack.top().orig_tmask;  // 0b1111
  warp.ipdom_stack.pop();                          // Stack에서 제거
}
```

#### Step 3: Stack Pop

```systemverilog
// VX_ipdom_stack.sv:66-68
if (pop_s) begin
    wr_ptr_r <= wr_ptr_r - ADDRW'(q_idx);  // 1 - 1 = 0
    empty_r <= (rd_ptr == 0) && q_idx;     // true
end
```

**Stack 상태 (Pop 후)**:
```
Stack: EMPTY
  wr_ptr = 0
```

#### Step 4: Thread Mask 복원 (PC는 변경 없음!)

```systemverilog
// VX_schedule.sv:153-158
if (join_valid && join_is_dvg) begin
    if (join_is_else) begin
        // join_is_else = false (q_idx=1이므로)
        // PC 변경 없음!
    end
    thread_masks_n[join_wid] = join_tmask;     // 0b1111
end
```

**결과**:
- `PC` 변경 없음 → **다음 명령어(merge 블록) 계속 실행**
- `thread_masks[wid] = 0b1111` → **모든 threads 재활성화**

---

## 3. 전체 실행 흐름 요약

### 3.1. 타임라인

```
Cycle   PC          Active Threads  IPDOM Stack           Action
---------------------------------------------------------------------
0       entry       0b1111          []                    -
1       split       0b1111          []                    Evaluate condition
2       then        0b0011          [{0b1111,0b1100,PC}]  Push & activate then
3-5     then_body   0b0011          [{0b1111,0b1100,PC}]  Execute then block
6       join_then   0b0011          [{0b1111,0b1100,PC}]  First JOIN
7       else        0b1100          [{0b1111,0b1100,PC}]  PC jump + switch mask
                                     (fallthrough=true)
8-10    else_body   0b1100          [{0b1111,0b1100,PC}]  Execute else block
11      join_else   0b1100          [{0b1111,0b1100,PC}]  Second JOIN
12      merge       0b1111          []                    Pop & restore mask
```

### 3.2. 시각적 다이어그램

```
                 vx_split(tid<2)
                      │
           ┌──────────┴──────────┐
           │   sp=0, push stack   │
           │   then: 0b0011       │
           │   else: 0b1100       │
           └──────────┬──────────┘
                      │
        ┌─────────────┴─────────────┐
        ↓ (then_tmask)               │
    ┌───────┐                        │
    │ THEN  │ thread 0,1             │
    │ block │ result = 65            │
    └───┬───┘                        │
        │                            │
    vx_join(sp=0)                    │
        │                            │
    ┌───┴────────────────────────┐   │
    │ First JOIN                 │   │
    │ - sp(0) != wr_ptr(1) → dvg │   │
    │ - fallthrough = false      │   │
    │ - Read d1: else_tmask      │   │
    │ - PC = merge_PC            │   │
    │ - Mask = 0b1100            │   │
    │ - fallthrough = true       │   │
    └──────────┬─────────────────┘   │
               │                     │
               ↓ (PC jump!)          ↓ (else_tmask)
           ┌───────┐            ┌───────┐
           │ ELSE  │◄───────────┤ ELSE  │
           │ block │ thread 2,3 │ entry │
           │       │ result=66  └───────┘
           └───┬───┘
               │
           vx_join(sp=0)
               │
           ┌───┴────────────────────────┐
           │ Second JOIN                │
           │ - sp(0) != wr_ptr(1) → dvg │
           │ - fallthrough = true       │
           │ - Read d0: orig_tmask      │
           │ - Mask = 0b1111            │
           │ - POP stack                │
           └──────────┬─────────────────┘
                      │
                      ↓ (no PC change)
                  ┌───────┐
                  │ MERGE │ thread 0,1,2,3
                  │ block │ buffer[tid]=result
                  └───────┘
```

---

## 4. 핵심 메커니즘 정리

### 4.1. IPDOM Stack의 이중 슬롯 구조

**이유**: 하나의 stack entry로 **2번의 JOIN 처리**

- **Slot 0 (d0)**: 원래 모든 threads (재수렴 시 사용)
- **Slot 1 (d1)**: else 경로 threads + PC (else 전환 시 사용)
- **q_idx (fallthrough)**: 0→1로 변경하여 첫 번째/두 번째 JOIN 구분

### 4.2. JOIN이 Jump하는 원리

**JOIN 명령어 자체는 jump하지 않습니다.** 대신:

1. **Hardware가 PC를 변경**: `join_is_else && join_is_dvg`일 때만
2. **VX_schedule.sv가 warp_pcs를 업데이트**: `warp_pcs_n[wid] = join_pc`
3. **다음 사이클에 변경된 PC에서 fetch**: Else 블록으로 "jump"한 것처럼 보임

### 4.3. 두 번째 JOIN의 특별한 동작

- **join_is_else = false** (q_idx=1이므로)
- **PC 변경 없음** → 자연스럽게 다음 명령어(merge 블록)로 진행
- **orig_tmask로 복원** → 모든 threads 재활성화
- **Stack pop** → IPDOM entry 제거

---

## 5. 왜 이런 복잡한 구조인가?

### 5.1. 하드웨어 효율성

- **단일 stack entry로 양방향 처리**: 메모리 절약
- **Fallthrough 플래그로 상태 관리**: 추가 stack 불필요
- **자동 PC 관리**: Software는 vx_join만 호출, 나머지는 hardware가 처리

### 5.2. LLVM Pass와의 협업

- **LLVM**: IPDOM 분석 및 join_stub 생성 (복잡한 제어 흐름 분석)
- **Hardware**: 실행 시 동적으로 mask/PC 관리 (빠른 전환)

### 5.3. 중첩 Divergence 지원

```c
if (cond1) {
  if (cond2) { A } else { B }
} else {
  if (cond3) { C } else { D }
}
```

- Stack에 여러 entry 쌓임
- 각 entry는 독립적으로 fallthrough 플래그 관리
- LIFO 순서로 정확한 재수렴 보장

---

## 6. 시뮬레이터 vs RTL 차이점

| 측면 | 시뮬레이터 (execute.cpp) | RTL (VX_split_join.sv) |
|------|--------------------------|------------------------|
| **Stack 구조** | `std::stack<ipdom_entry_t>` | 이중 슬롯 BRAM + q_idx |
| **Fallthrough** | `entry.fallthrough` boolean | `q_idx` 0/1 비트 |
| **Pop 시점** | 두 번째 JOIN에서 명시적 pop | q_idx에 따라 wr_ptr 조정 |
| **PC 변경** | `next_pc` 변수 설정 | `warp_pcs_n` 레지스터 업데이트 |

---

## 7. 디버깅 팁

### 7.1. Stack Overflow/Underflow

```systemverilog
// VX_ipdom_stack.sv:48-50
`RUNTIME_ASSERT(~(push_s && full_r), ("writing to a full stack!"));
`RUNTIME_ASSERT(~(pop_s && empty_r), ("reading an empty stack!"));
```

### 7.2. 시뮬레이터 디버그 출력

```cpp
// sim/simx/execute.cpp
std::cout << "SPLIT: then=" << then_tmask << ", else=" << else_tmask 
          << ", stack_size=" << warp.ipdom_stack.size() << "\n";
std::cout << "JOIN: stack_ptr=" << stack_ptr << ", fallthrough=" 
          << warp.ipdom_stack.top().fallthrough << "\n";
```

### 7.3. RTL 파형 분석

```
시그널 확인:
- warp_ctl_if.split.{valid, is_dvg, then_tmask, else_tmask}
- warp_ctl_if.sjoin.{valid, stack_ptr}
- join_{valid, is_dvg, is_else, tmask, pc}
- thread_masks[wid]
- warp_pcs[wid]
```

---

## 참고 자료

### 소스 코드
- [VortexBranchDivergence.cpp](https://github.com/vortexgpgpu/vortex-llvm/blob/main/llvm/lib/Target/RISCV/VortexBranchDivergence.cpp) - LLVM Pass
- [VX_split_join.sv](../../hw/rtl/core/VX_split_join.sv) - IPDOM Stack 관리
- [VX_ipdom_stack.sv](../../hw/rtl/core/VX_ipdom_stack.sv) - 이중 슬롯 Stack
- [VX_schedule.sv](../../hw/rtl/core/VX_schedule.sv) - PC/Mask 업데이트
- [sim/simx/execute.cpp](../../sim/simx/execute.cpp) - 시뮬레이터 구현

### 관련 문서
- [vortex_isa_extensions.md](vortex_isa_extensions.md) - ISA 명령어 개요
- [VortexOverview.md](../../vortex-llvm/docs/vortex/VortexOverview.md) - LLVM Pass 개요
