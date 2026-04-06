# CSR Pending Instruction Check: Almost Empty 메커니즘

## 개요

**CSR Unit**에서 FPU CSR (FFLAGS, FRM, FCSR)에 접근할 때, **pending instruction counter**가 **almost empty** 상태가 될 때까지 대기합니다. 이 문서는 왜 `empty`가 아닌 `almost_empty`를 사용하는지, 그 핵심 메커니즘을 설명합니다.

### 핵심 질문
> "Empty면 이미 모든 명령어가 완료되었다는 의미인데, 왜 Almost Empty를 사용하는가?"

**답**: CSR 명령어 자신이 counter에 포함되어 있기 때문입니다!

---

## 1. Pending Instruction Counter 구조

### Counter 동작 원리

**VX_schedule.sv (Line 370-383)**:
```systemverilog
VX_pending_size #(
    .SIZE      (4096),
    .ALM_EMPTY (1)        // Almost empty threshold = 1
) counter (
    .clk       (clk),
    .reset     (reset),
    .incr      (issue_sched_if[isw].valid && ...),  // Issue stage에서 +1
    .decr      (commit_sched_if.committed_warps[i]), // Commit stage에서 -1
    .empty     (pending_warp_empty[i]),              // Counter = 0
    .alm_empty (pending_warp_alm_empty[i]),          // Counter ≤ 1
    ...
);
```

### Counter 업데이트 시점

```
Pipeline Stage:    Fetch → Decode → Issue → Execute → Commit
Counter 변화:                        ↑ +1            ↓ -1
```

**핵심 포인트**:
- **Increment**: Issue stage에서 +1 (명령어가 pipeline에 진입)
- **Decrement**: Commit stage에서 -1 (명령어가 완전히 완료)

---

## 2. CSR 명령어 실행 Timeline

### 상황 설정
```
1. FPU 명령어 (fadd) issue
2. CSR 명령어 (csrr x1, fcsr) issue
3. CSR가 Execute stage에 도달했을 때 무슨 일이?
```

### Timeline 분석

```
┌─────────────────────────────────────────────────────────────┐
│ Cycle 1: FPU 명령어 (fadd) Issue                            │
│   - counter = 1                                              │
│   - Pipeline: [fadd]                                         │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Cycle 2: CSR 명령어 Issue                                    │
│   - counter = 2 (fadd + csrr)                               │
│   - Pipeline: [fadd] [csrr]                                 │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Cycle 5: CSR 명령어가 Execute Stage 도달                     │
│   - counter = 2 (fadd 아직 실행 중)                          │
│   - alm_empty_wid = csrr의 wid                              │
│   - alm_empty 확인:                                          │
│     * counter = 2 → alm_empty = 0 (≤1이 아님)               │
│     * no_pending_instr = 0                                  │
│     * CSR 명령어 STALL! 🛑                                   │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Cycle 8: FPU 명령어 Commit                                   │
│   - fadd가 FCSR 업데이트 (exception flags)                   │
│   - counter = 1 (csrr만 남음)                                │
│   - alm_empty = 1 ✅                                         │
│   - no_pending_instr = 1                                    │
│   - CSR 명령어 진행 가능! ✅                                  │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Cycle 9: CSR 명령어 실행                                      │
│   - FCSR 읽기 (최신 값 보장)                                 │
│   - counter = 1                                              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Cycle 10: CSR 명령어 Commit                                   │
│   - counter = 0                                              │
│   - empty = 1, alm_empty = 1                                │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Empty vs Almost Empty 비교

### Counter 값에 따른 상태

| Counter 값 | Empty | Almost Empty | 현재 상황 | CSR 진행 가능? |
|-----------|-------|--------------|-----------|---------------|
| 0 | ✅ 1 | ✅ 1 | 모든 명령어 완료 | CSR이 execute에 있을 수 없음 |
| 1 | ❌ 0 | ✅ 1 | **CSR만 남음** | ✅ **진행 가능!** |
| 2 | ❌ 0 | ❌ 0 | CSR + 1개 명령어 | ❌ 대기 필요 |
| 3+ | ❌ 0 | ❌ 0 | CSR + 여러 명령어 | ❌ 대기 필요 |

### Almost Empty의 의미

**VX_pending_size.sv (Line 90)**:
```systemverilog
alm_empty_r <= (size_n <= SIZEW'(ALM_EMPTY));  // ALM_EMPTY = 1
```

**Counter ≤ 1일 때 `alm_empty = 1`**:
- Counter = 0: 모든 명령어 완료
- Counter = 1: **현재 Execute stage의 CSR 명령어만 남음**

---

## 4. 왜 Empty를 사용할 수 없는가?

### Deadlock 시나리오

```systemverilog
// 만약 empty를 사용한다면?
wire no_pending_instr = sched_csr_if.empty || ~is_fpu_csr;
```

**문제점**:
```
1. CSR 명령어가 Execute stage에 도달
   └─> 이미 Issue를 통과 → counter에 자신이 포함됨
   └─> Counter ≥ 1 (최소값)

2. Empty (counter = 0)를 기다림
   └─> Empty가 되려면 CSR 자신이 commit되어야 함
   └─> 하지만 CSR은 아직 execute stage!
   └─> Execute는 empty를 기다림...
   └─> 🔄 Deadlock!

3. CSR이 자기 자신의 완료를 기다리는 상황
   └─> 영원히 진행 불가능
```

### Deadlock 다이어그램

```
CSR in Execute: "나는 empty가 될 때까지 기다릴 거야!"
       ↓
Counter = 1 (CSR 자신 포함)
       ↓
Empty = 0 (Counter > 0)
       ↓
CSR: "empty가 아니네? 계속 기다려야지..."
       ↓
Empty가 되려면 CSR이 commit되어야 함
       ↓
CSR은 empty를 기다리며 stall 중
       ↓
🔄 무한 대기 (Deadlock!)
```

---

## 5. Almost Empty의 정확한 조건

### 코드 분석

**VX_csr_unit.sv (Line 58-64)**:
```systemverilog
wire is_fpu_csr = (csr_addr <= `VX_CSR_FCSR);

// wait for all pending instructions for current warp to complete
assign sched_csr_if.alm_empty_wid = execute_if.data.wid;
wire no_pending_instr = sched_csr_if.alm_empty || ~is_fpu_csr;

wire csr_req_valid = execute_if.valid && no_pending_instr;
assign execute_if.ready = csr_req_ready && no_pending_instr;
```

### 동작 흐름

```
1. CSR 명령어 Execute stage 도달
   └─> sched_csr_if.alm_empty_wid = execute_if.data.wid

2. VX_schedule에서 해당 warp의 counter 확인
   └─> sched_csr_if.alm_empty = pending_warp_alm_empty[alm_empty_wid]

3. Counter 값 체크:
   ├─ Counter = 1 (CSR만 남음)
   │  └─> alm_empty = 1 → no_pending_instr = 1 → 진행 ✅
   │
   └─ Counter ≥ 2 (이전 명령어들 있음)
      └─> alm_empty = 0 → no_pending_instr = 0 → stall ❌
```

---

## 6. FPU CSR vs Non-FPU CSR

### FPU CSR (FFLAGS, FRM, FCSR)

**특징**:
- FPU 명령어 실행 중에 **동적으로 업데이트**됨
- FFLAGS: Exception flags (NV, DZ, OF, UF, NX)
- FRM: Rounding mode
- FCSR: FFLAGS + FRM 통합

**문제**:
```
FPU 명령어 실행 → Exception 발생 → FFLAGS 업데이트

만약 FPU 완료 전에 FCSR를 읽으면?
→ 잘못된 (outdated) exception flags 읽음!
```

**해결**:
```systemverilog
wire no_pending_instr = sched_csr_if.alm_empty || ~is_fpu_csr;
                        ^^^^^^^^^^^^^^^^^^^^^^^^^
                        FPU CSR일 때만 대기!
```

### Non-FPU CSR (TIME, CYCLE, WID 등)

**특징**:
- Pipeline 명령어에 의해 변경되지 않음
- Read-only 또는 independent

**동작**:
```systemverilog
wire no_pending_instr = sched_csr_if.alm_empty || ~is_fpu_csr;
                                                   ^^^^^^^^^^^^
                                                   Non-FPU면 즉시 진행!
```

**최적화**:
- Pending 명령어 확인 불필요
- 언제 읽어도 올바른 값
- 불필요한 stall 회피

---

## 7. 실제 사용 예제

### C 코드
```c
float a = 1.5f;
float b = 0.0f;
float c = a / b;  // Division by zero!

unsigned int flags;
asm volatile("csrr %0, fcsr" : "=r"(flags));  // Exception flags 읽기

if (flags & 0x08) {  // DZ (Division by Zero) flag
    printf("Division by zero detected!\n");
}
```

### Hardware 동작

```
1. fdiv 명령어 issue
   └─> counter = 1

2. csrr fcsr 명령어 issue
   └─> counter = 2

3. csrr이 execute stage 도달
   └─> alm_empty_wid = csrr의 wid
   └─> counter = 2 → alm_empty = 0
   └─> CSR STALL! (fdiv 완료 대기)

4. fdiv 실행 완료
   └─> Division by zero 감지
   └─> FFLAGS.DZ = 1 (bit 3)
   └─> FCSR 업데이트
   └─> counter = 1 (csrr만 남음)
   └─> alm_empty = 1

5. csrr 진행
   └─> FCSR 읽기 → 0x08 (DZ flag set)
   └─> Software가 올바른 exception flag 확인 ✅
```

### 만약 Almost Empty를 확인하지 않는다면?

```
1. fdiv issue → counter = 1
2. csrr issue → counter = 2
3. csrr execute stage 도달 → 즉시 진행 (체크 없음)
4. FCSR 읽기 → 0x00 (아직 DZ flag 설정 전!)
5. fdiv 완료 → FFLAGS.DZ = 1 (너무 늦음)

결과: Software가 exception을 놓침! ❌
```

---

## 8. 핵심 인사이트

### 1. Counter에 자기 자신 포함

**문제의 근본 원인**:
```
Issue stage에서 increment → Execute stage에서 체크
                          ↑
                          여기서 자신이 이미 카운트됨!
```

**해결책**:
```
Almost Empty (counter ≤ 1) 사용
= "자신을 제외한 모든 이전 명령어 완료"
```

### 2. Almost Empty의 재정의

**일반적 의미**: "거의 비어있음" (약간 애매)

**정확한 의미**: 
> **"현재 Execute stage의 명령어를 제외한 모든 이전 명령어가 완료됨"**

### 3. FPU CSR의 특수성

**왜 FPU CSR만?**
- FPU 명령어가 CSR을 동적으로 업데이트
- Race condition 방지 필수
- Non-FPU CSR은 bypass 가능 (최적화)

### 4. Deadlock vs Correctness

| 선택 | 결과 |
|------|------|
| Empty 사용 | ❌ Deadlock (자기 자신 대기) |
| Almost Empty 사용 | ✅ 정확한 동기화 (이전 명령어 완료) |
| 체크 안함 | ❌ Race condition (잘못된 CSR 값) |

---

## 9. 요약

### 핵심 메커니즘

```
┌─────────────────────────────────────────────────────────────┐
│ Counter에 CSR 자신이 포함되어 있음                            │
│   ↓                                                          │
│ Empty (counter = 0) = CSR도 완료 = CSR이 execute에 있을 수 없음 │
│   ↓                                                          │
│ Almost Empty (counter ≤ 1) = CSR만 남음 = 이전 명령어 완료   │
│   ↓                                                          │
│ 정확한 동기화 조건!                                           │
└─────────────────────────────────────────────────────────────┘
```

### 왜 Almost Empty인가?

| 이유 | 설명 |
|------|------|
| **Deadlock 방지** | CSR이 자기 자신의 완료를 기다리는 상황 회피 |
| **정확한 조건** | "CSR 이전의 모든 명령어 완료"를 올바르게 표현 |
| **Counter 구조** | Issue stage increment → Execute stage check |
| **FPU CSR 보장** | FPU 명령어의 CSR 업데이트 완료 대기 |

### 최종 정리

**질문**: Empty면 더 안전한 게 아닌가?

**답**:
- ✅ **맞습니다**: Empty가 더 안전합니다 (모든 명령어 완료)
- ❌ **하지만**: CSR 자신이 counter에 포함되어 있어서 사용 불가능
- ✅ **해결**: Almost Empty = "자신을 제외한 모든 명령어 완료"

**핵심**:
> Almost Empty는 타협이 아닌, **Counter 구조상 유일하게 올바른 조건**입니다!

---

*문서 작성일: 2025-12-22*  
*Vortex GPGPU Project - CSR Pending Instruction Check Analysis*
