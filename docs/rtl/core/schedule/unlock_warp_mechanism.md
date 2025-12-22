# Warp Unlock Mechanism 분석

## 개요

**unlock_warp**는 Schedule stage에서 stall된 warp를 다시 실행 가능하도록 해제하는 신호입니다. Vortex GPGPU는 특정 명령어 실행 시 warp를 일시 중단(stall)시키고, 조건이 만족되면 unlock하여 다시 fetch를 시작합니다.

### 핵심 개념
- **Warp Stall**: Schedule stage에서 warp의 fetch를 일시 중지
- **Unlock**: Stall된 warp를 다시 활성화하여 명령어 fetch 재개
- **동기화**: Branch, CSR, Warp control 명령어의 순차 실행 보장

---

## Stall/Unlock의 기본 메커니즘

### 모든 Warp는 선택되면 무조건 Stall

**중요**: Vortex는 **모든 warp를 선택과 동시에 무조건 stall**시킵니다!

```systemverilog
// VX_schedule.sv Line 310
wire [`NUM_WARPS-1:0] ready_warps = active_warps & ~stalled_warps;

// Line 312-317: Priority encoder로 ready warp 선택
VX_priority_encoder #(
    .N (`NUM_WARPS)
) wid_select (
    .data_in   (ready_warps),      // stalled가 아닌 warp 중에서
    .index_out (schedule_wid),      // 선택된 warp ID
    .valid_out (schedule_valid)     // 선택 성공
);

// Line 72: schedule_fire = 명령어 fetch 시작
wire schedule_fire = schedule_valid && schedule_ready;

// Line 201-203: 선택된 warp를 즉시 stall!
if (schedule_fire) begin
    stalled_warps_n[schedule_wid] = 1;  // 모든 명령어가 stall됨
end
```

### Unlock 시점의 차이

**핵심**: 명령어 타입에 따라 **unlock 시점만 다릅니다**!

| 명령어 타입 | Unlock 시점 | Stall 기간 | 이유 |
|------------|------------|-----------|------|
| **일반 명령어** (ADD, LW) | Decode stage | ~2 cycles | 즉시 실행 가능 |
| **Branch** (BEQ, JAL) | Execute stage | ~4-5 cycles | 분기 결과 대기 |
| **FPU CSR** | CSR unit | 가변 | Pending FP 명령어 완료 대기 |
| **Warp Control** (SPLIT, JOIN) | Warp Ctl unit | ~3-4 cycles | Warp 상태 업데이트 |

### 타이밍 비교

#### 일반 명령어 (ADD) - 짧은 Stall

```
T0: Schedule → schedule_fire=1 → stalled_warps[0]=1 ✓ (무조건 stall)
T1: Fetch    → ADD 명령어 fetch
T2: Decode   → is_wstall=0 → unlock=1
    Schedule → stalled_warps[0]=0 ✓ (Decode unlock, 2 cycle stall)
T3: Schedule → Warp 0을 다시 선택 가능!
```

#### Branch 명령어 (BEQ) - 긴 Stall

```
T0: Schedule → schedule_fire=1 → stalled_warps[0]=1 ✓ (무조건 stall)
T1: Fetch    → BEQ 명령어 fetch
T2: Decode   → is_wstall=1 → unlock=0
    Schedule → stalled_warps[0]=1 ✓ (계속 stall 유지)
T3: Issue    → BEQ issue
T4: Execute  → Branch 계산
T5: Schedule → branch_valid=1 → stalled_warps[0]=0 ✓ (Execute unlock, 5 cycle stall)
T6: Schedule → Warp 0을 다시 선택 가능!
```

### 왜 이렇게 설계했을까?

**파이프라인 단순화**:
- 모든 warp를 동일하게 처리 (선택 → stall)
- 명령어 타입에 따라 unlock만 다르게 처리
- Fetch/Decode/Execute가 독립적으로 동작 가능

**Resource 충돌 방지**:
- 한 warp가 파이프라인에 여러 명령어를 동시에 넣지 못하게 방지
- Warp-level back-pressure 제공

---

## Warp Stall이 필요한 이유

### 1. Branch 명령어
- Branch 결과가 나올 때까지 다음 명령어 fetch 불가
- 잘못된 경로의 명령어 fetch 방지

### 2. FPU CSR 명령어
- FPU 상태 레지스터(FFLAGS, FRM, FCSR) 읽기 전 이전 FP 명령어 완료 대기
- 정확한 exception flag 및 rounding mode 보장

### 3. Warp Control 명령어
- TMC, WSPAWN, SPLIT, JOIN, BARRIER, PRED 실행 시 warp 상태 업데이트 대기
- Thread mask, PC, barrier 동기화 보장

---

## Stall을 발생시키는 명령어

### VX_decode.sv - is_wstall 플래그

**파일**: [hw/rtl/core/VX_decode.sv](hw/rtl/core/VX_decode.sv)

```systemverilog
// Line 51: Warp stall 플래그
reg is_wstall;

// Decode 로직에서 is_wstall 설정
always @(*) begin
    is_wstall = 0;  // 기본값: stall 없음
    
    case (opcode)
        // 1. Jump 명령어
        INST_JAL: begin
            // Line 264
            is_wstall = 1;  // Unconditional jump
        end
        
        INST_JALR: begin
            // Line 275
            is_wstall = 1;  // Indirect jump (register)
        end
        
        // 2. Branch 명령어
        INST_B: begin
            // Line 287 (BEQ, BNE, BLT, BGE, BLTU, BGEU)
            is_wstall = 1;  // Conditional branch
        end
        
        // 3. CSR 명령어
        INST_SYS: begin
            if (funct3[1:0] != 0) begin  // CSRRW, CSRRS, CSRRC
                // Line 304
                is_wstall = is_fpu_csr;  // FPU CSR만 stall
            end else begin  // ECALL, EBREAK, MRET, etc.
                // Line 319
                is_wstall = 1;
            end
        end
        
        // 4. Warp Control 명령어 (Custom Extension)
        INST_EXT1: begin  // 0x0B opcode
            // Line 472 (TMC, WSPAWN, SPLIT, JOIN, BAR, PRED)
            is_wstall = 1;
        end
    endcase
end

// Line 569: Unlock 신호 생성
assign decode_sched_if.unlock = ~is_wstall;
```

### is_wstall 명령어 분류

| 명령어 타입 | 명령어 예시 | Stall 여부 | 이유 |
|------------|------------|-----------|------|
| **산술/논리** | ADD, SUB, AND, OR | ❌ No | 즉시 실행 가능 |
| **Load/Store** | LW, SW, FLW, FSW | ❌ No | Pipeline으로 처리 |
| **Jump** | JAL, JALR | ✅ Yes | PC 변경 대기 |
| **Branch** | BEQ, BNE, BLT, BGE | ✅ Yes | 분기 결과 대기 |
| **일반 CSR** | CSRRW MCYCLE | ❌ No | 즉시 읽기/쓰기 |
| **FPU CSR** | CSRRW FCSR | ✅ Yes | FP 명령어 완료 대기 |
| **System** | ECALL, EBREAK | ✅ Yes | Exception 처리 |
| **Warp Control** | TMC, SPLIT, JOIN, BAR | ✅ Yes | Warp 상태 동기화 |

---

## Schedule Stage의 Stall/Unlock 관리

### VX_schedule.sv - Stalled Warps 레지스터

**파일**: [hw/rtl/core/VX_schedule.sv](hw/rtl/core/VX_schedule.sv)

```systemverilog
// Line 48-49: Stall 상태 관리 레지스터
reg [`NUM_WARPS-1:0] stalled_warps, stalled_warps_n;

// Combinational logic (always @(*))
always @(*) begin
    stalled_warps_n = stalled_warps;  // 기본값: 현재 상태 유지
    
    // === UNLOCK 경로들 ===
    
    // 1. Decode Unlock (Line 116-118)
    // Non-stalling 명령어는 즉시 unlock
    if (decode_sched_if.valid && decode_sched_if.unlock) begin
        stalled_warps_n[decode_sched_if.wid] = 0;
    end
    
    // 2. CSR Unlock (Line 121-123)
    // FPU CSR 명령어 완료 시
    if (sched_csr_if.unlock_warp) begin
        stalled_warps_n[sched_csr_if.unlock_wid] = 0;
    end
    
    // 3. WSPAWN Unlock (Line 127-134)
    if (wspawn.valid && is_single_warp) begin
        // 새로운 warp 생성 완료
        active_warps_n |= wspawn.wmask;
        for (integer i = 0; i < `NUM_WARPS; ++i) begin
            if (wspawn.wmask[i]) begin
                thread_masks_n[i][0] = 1;
                warp_pcs_n[i] = wspawn.pc;
            end
        end
        stalled_warps_n[wspawn_wid] = 0;  // 생성한 warp unlock
    end
    
    // 4. TMC Unlock (Line 137-141)
    if (warp_ctl_if.valid && warp_ctl_if.tmc.valid) begin
        active_warps_n[warp_ctl_if.wid] = (warp_ctl_if.tmc.tmask != 0);
        thread_masks_n[warp_ctl_if.wid] = warp_ctl_if.tmc.tmask;
        stalled_warps_n[warp_ctl_if.wid] = 0;
    end
    
    // 5. SPLIT Unlock (Line 144-150)
    if (warp_ctl_if.valid && warp_ctl_if.split.valid) begin
        if (warp_ctl_if.split.is_dvg) begin
            thread_masks_n[warp_ctl_if.wid] = warp_ctl_if.split.then_tmask;
        end
        stalled_warps_n[warp_ctl_if.wid] = 0;
    end
    
    // 6. JOIN Unlock (Line 153-161)
    if (join_valid) begin
        if (join_is_dvg) begin
            if (join_is_else) begin
                warp_pcs_n[join_wid] = join_pc;
            end
            thread_masks_n[join_wid] = join_tmask;
        end
        stalled_warps_n[join_wid] = 0;
    end
    
    // 7. Barrier Unlock (Line 164-189)
    // Local barrier
    if (warp_ctl_if.valid && warp_ctl_if.barrier.valid) begin
        if (~warp_ctl_if.barrier.is_noop) begin
            if (~warp_ctl_if.barrier.is_global
             && (barrier_ctrs[id] == size_m1)) begin
                // 모든 warp가 도달 → 전체 unlock
                stalled_warps_n &= ~barrier_masks[id];
                stalled_warps_n[wid] = 0;
            end else begin
                // 아직 대기 중
            end
        end else begin
            stalled_warps_n[wid] = 0;  // No-op barrier는 즉시 unlock
        end
    end
    
    // Global barrier (Line 184-188)
`ifdef GBAR_ENABLE
    if (gbar_bus_if.rsp_valid && (gbar_req_id == gbar_bus_if.rsp_data.id)) begin
        barrier_ctrs_n[id] = '0;
        barrier_masks_n[id] = '0;
        stalled_warps_n = '0;  // 모든 warp unlock
    end
`endif
    
    // 8. Branch Unlock (Line 191-197)
    for (integer i = 0; i < `NUM_ALU_BLOCKS; ++i) begin
        if (branch_valid[i]) begin
            if (branch_taken[i]) begin
                warp_pcs_n[branch_wid[i]] = branch_dest[i];
            end
            stalled_warps_n[branch_wid[i]] = 0;
        end
    end
    
    // === STALL 경로 ===
    
    // 9. Schedule 시 Stall (Line 200-202)
    // 새로운 명령어 fetch 시작 시
    if (schedule_fire) begin
        stalled_warps_n[schedule_wid] = 1;
    end
    
    // 10. PC 자동 증가 (Line 205-207)
    // Fetch 완료 시 다음 명령어 주소로 이동
    if (schedule_if_fire) begin
        warp_pcs_n[schedule_if.data.wid] = schedule_if.data.PC + from_fullPC(`XLEN'(4));
    end
end
```

---

## CSR Unit의 특별한 Unlock 메커니즘

### VX_csr_unit.sv - FPU CSR 동기화

**파일**: [hw/rtl/core/VX_csr_unit.sv](hw/rtl/core/VX_csr_unit.sv)

```systemverilog
// Line 58: FPU CSR 판별
wire is_fpu_csr = (csr_addr <= `VX_CSR_FCSR);
// FFLAGS (0x001), FRM (0x002), FCSR (0x003)

// Line 61-63: Pending 명령어 확인
assign sched_csr_if.alm_empty_wid = execute_if.data.wid;
wire no_pending_instr = sched_csr_if.alm_empty || ~is_fpu_csr;

// CSR 요청은 pending 명령어가 거의 없을 때만 처리
wire csr_req_valid = execute_if.valid && no_pending_instr;
assign execute_if.ready = csr_req_ready && no_pending_instr;

// Line 161-162: FPU CSR 완료 시 Unlock
assign sched_csr_if.unlock_warp = csr_req_valid && csr_req_ready 
                                   && execute_if.data.eop && is_fpu_csr;
assign sched_csr_if.unlock_wid = execute_if.data.wid;
```

### Unlock 조건 상세

```systemverilog
unlock_warp = csr_req_valid       // CSR 요청이 유효
              && csr_req_ready    // CSR 처리 준비 완료
              && execute_if.data.eop   // End of Packet (명령어 그룹의 마지막)
              && is_fpu_csr;      // FPU CSR인 경우만
```

| 조건 | 설명 |
|------|------|
| `csr_req_valid` | CSR 읽기/쓰기 요청이 활성화 (pending 명령어 ≤ 1) |
| `csr_req_ready` | CSR data 모듈이 처리 준비 완료 |
| `execute_if.data.eop` | SIMD 실행 그룹의 마지막 명령어 |
| `is_fpu_csr` | FPU 상태 레지스터 (일반 CSR은 unlock 불필요) |

### 왜 FPU CSR만 특별한가?

**문제**:
```c
// Thread 0
fadd.s f0, f1, f2      // Cycle 10: 실행 시작, exception 발생 가능
fmul.s f3, f4, f5      // Cycle 11: 실행 시작
csrr t0, fflags        // Cycle 12: FFLAGS 읽기 시도
```

**위험**:
- `csrr fflags`가 `fadd`, `fmul`보다 먼저 완료될 수 있음
- 아직 발생하지 않은 exception flag를 읽게 됨 → **부정확한 결과**

**해결책**:
1. **Decode stage**: FPU CSR 명령어 → `is_wstall = 1` → warp stall
2. **CSR unit**: Pending FP 명령어 완료 대기 (`alm_empty = 1`)
3. **CSR 처리 완료**: `unlock_warp = 1` → Schedule stage가 warp unlock
4. 이후 다음 명령어 fetch 재개

---

## Unlock 경로 요약

### 전체 Unlock 경로

| # | Unlock 경로 | 조건 | 파일 위치 |
|---|-------------|------|-----------|
| 1 | **Decode Unlock** | `decode_sched_if.unlock = 1` (non-stalling 명령어) | VX_decode.sv:569 → VX_schedule.sv:116 |
| 2 | **CSR Unlock** | `sched_csr_if.unlock_warp = 1` (FPU CSR 완료) | VX_csr_unit.sv:161 → VX_schedule.sv:121 |
| 3 | **WSPAWN Unlock** | `wspawn.valid && is_single_warp` | VX_schedule.sv:127 |
| 4 | **TMC Unlock** | `warp_ctl_if.tmc.valid` | VX_schedule.sv:137 |
| 5 | **SPLIT Unlock** | `warp_ctl_if.split.valid` | VX_schedule.sv:144 |
| 6 | **JOIN Unlock** | `join_valid` | VX_schedule.sv:153 |
| 7 | **Local Barrier Unlock** | `barrier_ctrs == size_m1` | VX_schedule.sv:164 |
| 8 | **Global Barrier Unlock** | `gbar_bus_if.rsp_valid` | VX_schedule.sv:184 |
| 9 | **Branch Unlock** | `branch_valid[i]` | VX_schedule.sv:191 |

---

## 실행 흐름 예시

### 예시 1: 일반 명령어 (짧은 Stall - 2 Cycles)

```
Cycle  Stage       Event                              stalled_warps[0]
-----  ----------  ---------------------------------  ----------------
T0     Schedule    선택: Warp 0                       0 (ready)
                   schedule_fire = 1
                   stalled_warps_n[0] = 1             → 1 (무조건 stall!)
                   
T1     Fetch       Fetch ADD instruction              1 (stalled)

T2     Decode      Decode ADD                         1 (stalled)
                   is_wstall = 0 (일반 명령어)
                   decode_sched_if.unlock = 1
                   
       Schedule    stalled_warps_n[0] = 0             → 0 (Decode unlock!)

T3     Issue       Issue ADD                          0 (ready)
       Schedule    Warp 0을 다시 선택 가능 ✓          0

T4     Execute     Execute ADD                        0 (ready)

T5     Schedule    선택: Warp 0 (또 다른 명령어)      0 (ready)
```

**핵심**: 일반 명령어는 **2 cycle만 stall** (T0→T2), Decode에서 즉시 unlock!

### 예시 2: Branch 명령어 (긴 Stall - 5 Cycles)

```
Cycle  Stage       Event                              stalled_warps[0]
-----  ----------  ---------------------------------  ----------------
T0     Schedule    선택: Warp 0                       0 (ready)
                   schedule_fire = 1
                   stalled_warps_n[0] = 1             → 1 (무조건 stall!)

T1     Fetch       Fetch BEQ instruction              1 (stalled)

T2     Decode      Decode BEQ                         1 (stalled)
                   is_wstall = 1 (Branch!)
                   decode_sched_if.unlock = 0
                   (stalled_warps는 그대로 유지)      → 1 (계속 stall)

T3     Issue       Issue BEQ                          1 (stalled)

T4     Execute     Execute BEQ                        1 (stalled)
                   Compare rs1, rs2
                   
T5     Execute     branch_ctl_if.valid = 1            1 (stalled)
                   branch_ctl_if.taken = 1
                   branch_ctl_if.dest = target_pc
                   
       Schedule    branch_valid[0] = 1
                   warp_pcs_n[0] = target_pc
                   stalled_warps_n[0] = 0             → 0 (Execute unlock!)

T6     Schedule    선택: Warp 0                       0 (ready)
                   PC = target_pc에서 fetch 시작 ✓
```

**핵심**: Branch 명령어는 **5 cycle 동안 stall** (T0→T5), Execute에서 결과 나온 후 unlock!

### 예시 3: FPU CSR 명령어 (가변 Stall - Pending 대기)

```
Cycle  Stage       Event                              stalled_warps[0]  pending[0]
-----  ----------  ---------------------------------  ----------------  ----------
T0     Issue       FADD issued                        0 (ready)         1

T1     Issue       FMUL issued                        0 (ready)         2
                   (alm_empty = 0, pending > 1)

T2     Schedule    선택: Warp 0                       0 (ready)         2
                   Fetch CSRR FFLAGS
                   schedule_fire = 1
                   stalled_warps_n[0] = 1             → 1 (무조건 stall!) 2

T3     Fetch       Fetch CSRR FFLAGS                  1 (stalled)       2

T4     Decode      Decode CSRR FFLAGS                 1 (stalled)       2
                   is_fpu_csr = 1
                   is_wstall = 1 (FPU CSR!)
                   decode_sched_if.unlock = 0         → 1 (계속 stall)   2

T5     CSR Unit    execute_if.valid = 1               1 (stalled)       2
                   no_pending_instr = 0 (pending=2)
                   csr_req_valid = 0
                   execute_if.ready = 0
                   (CSR unit 대기)                    1 (stalled)       2

T6     Commit      FADD committed                     1 (stalled)       1
                   (alm_empty = 1 ✓)

T7     CSR Unit    no_pending_instr = 1               1 (stalled)       1
                   csr_req_valid = 1
                   Read FFLAGS register

T8     CSR Unit    csr_req_ready = 1                  1 (stalled)       1
                   execute_if.data.eop = 1
                   unlock_warp = 1
                   
       Schedule    sched_csr_if.unlock_warp = 1       1 (stalled)       1
                   stalled_warps_n[0] = 0             → 0 (CSR unlock!)  1

T9     Commit      CSRR committed                     0 (ready)         0

T10    Schedule    선택: Warp 0                       0 (ready)         0
                   다음 명령어 fetch 재개 ✓
```

**핵심**: FPU CSR은 **가변 stall** (T2→T8, 7 cycles), Pending FP 명령어 완료까지 대기 후 unlock!

### 예시 4: SPLIT/JOIN

```
Cycle  Stage       Event                              stalled_warps[0]
-----  ----------  ---------------------------------  ----------------
T0     Schedule    Fetch SPLIT                        0
                   stalled_warps_n[0] = 1             → 1

T1     Decode      Decode SPLIT, is_wstall = 1        1

T2     Execute     Execute SPLIT                      1
                   Compute then_tmask, else_tmask
                   
T3     Wctl Unit   warp_ctl_if.split.valid = 1        1
       
       Schedule    thread_masks_n[0] = then_tmask     1
                   stalled_warps_n[0] = 0             → 0

T4     Schedule    선택: Warp 0, then path 실행       0

...    (then path 실행)

T10    Schedule    Fetch JOIN                         0
                   stalled_warps_n[0] = 1             → 1

T11    Decode      Decode JOIN, is_wstall = 1         1

T12    Split/Join  join_valid = 1                     1
                   join_is_else = 1
                   join_pc = next_pc
                   
       Schedule    warp_pcs_n[0] = next_pc            1
                   thread_masks_n[0] = else_tmask
                   stalled_warps_n[0] = 0             → 0

T13    Schedule    선택: Warp 0, else path 실행       0
```

---

## 인터페이스 신호 정의

### VX_sched_csr_if (CSR ↔ Schedule)

**파일**: [hw/rtl/interfaces/VX_sched_csr_if.sv](hw/rtl/interfaces/VX_sched_csr_if.sv)

```systemverilog
interface VX_sched_csr_if import VX_gpu_pkg::*; ();
    // Schedule → CSR (master output)
    wire [PERF_CTR_BITS-1:0]        cycles;          // Busy cycles
    wire [`NUM_WARPS-1:0]           active_warps;    // Active warp mask
    wire [`NUM_WARPS-1:0][`NUM_THREADS-1:0] thread_masks;  // Thread masks
    wire                            alm_empty;       // Almost empty 신호
    
    // CSR → Schedule (slave output)
    wire [NW_WIDTH-1:0]             alm_empty_wid;   // 확인할 warp ID
    wire                            unlock_warp;     // Unlock 신호 ★
    wire [NW_WIDTH-1:0]             unlock_wid;      // Unlock할 warp ID ★
    
    modport master (  // Schedule side
        output cycles,
        output active_warps,
        output thread_masks,
        input  alm_empty_wid,
        output alm_empty,
        input  unlock_wid,
        input  unlock_warp
    );
    
    modport slave (   // CSR side
        input  cycles,
        input  active_warps,
        input  thread_masks,
        output alm_empty_wid,
        input  alm_empty,
        output unlock_wid,
        output unlock_warp
    );
endinterface
```

### VX_decode_sched_if (Decode → Schedule)

**파일**: [hw/rtl/interfaces/VX_decode_sched_if.sv](hw/rtl/interfaces/VX_decode_sched_if.sv)

```systemverilog
interface VX_decode_sched_if import VX_gpu_pkg::*; ();
    wire                valid;    // Decode 완료
    wire [NW_WIDTH-1:0] wid;      // Warp ID
    wire                unlock;   // Unlock 신호 (= ~is_wstall)
    
    modport master (  // Decode side
        output valid,
        output wid,
        output unlock
    );
    
    modport slave (   // Schedule side
        input  valid,
        input  wid,
        input  unlock
    );
endinterface
```

---

## Stall/Unlock 타이밍 다이어그램

### Branch 명령어 타이밍

```
Clock:    T0    T1    T2    T3    T4    T5    T6
          ┌─────┬─────┬─────┬─────┬─────┬─────┬─────
Schedule  │ BEQ │     │     │     │UNLK │ NXT │
          │STALL│ --- │ --- │ --- │ --- │FETCH│
Fetch     │ --- │ BEQ │     │     │     │     │ NXT
Decode    │     │ --- │ BEQ │     │     │     │
          │     │     │STALL│     │     │     │
Execute   │     │     │ --- │ BEQ │ BEQ │     │
          │     │     │     │ --- │DONE │     │
Branch    │     │     │     │     │VALID│     │
Stalled   │  0  │  1  │  1  │  1  │  1→0│  0  │
          └─────┴─────┴─────┴─────┴─────┴─────┴─────
```

### FPU CSR 명령어 타이밍

```
Clock:    T0    T1    T2    T3    T4    T5    T6    T7    T8
          ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────
Schedule  │ CSR │     │     │     │     │     │UNLK │ NXT │
          │STALL│ --- │ --- │ --- │ --- │ --- │ --- │FETCH│
CSR Unit  │     │     │     │WAIT │WAIT │ CSR │ CSR │     │
          │     │     │     │pend │pend │ REQ │DONE │     │
          │     │     │     │ =2  │ =1  │VALID│UNLK │     │
Commit    │     │FADD │     │     │FADD │     │ CSR │
          │     │ --- │     │     │DONE │     │DONE │
Pending   │  1  │  2  │  2  │  2  │  1  │  1  │  0  │  0  │
alm_empty │  1  │  0  │  0  │  0  │  1  │  1  │  1  │  1  │
Stalled   │  0  │  1  │  1  │  1  │  1  │  1  │ 1→0 │  0  │
          └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────
```

---

## 주요 파일 위치

| 파일 | 역할 | unlock_warp 관련 코드 |
|------|------|----------------------|
| [hw/rtl/core/VX_decode.sv](hw/rtl/core/VX_decode.sv#L569) | Decode stage | `decode_sched_if.unlock = ~is_wstall` |
| [hw/rtl/core/VX_csr_unit.sv](hw/rtl/core/VX_csr_unit.sv#L161) | CSR unit | `sched_csr_if.unlock_warp = ...` |
| [hw/rtl/core/VX_schedule.sv](hw/rtl/core/VX_schedule.sv#L121) | Schedule stage | `if (unlock_warp) stalled_warps_n[wid] = 0` |
| [hw/rtl/interfaces/VX_sched_csr_if.sv](hw/rtl/interfaces/VX_sched_csr_if.sv#L23) | Interface 정의 | `wire unlock_warp; wire unlock_wid;` |
| [hw/rtl/interfaces/VX_decode_sched_if.sv](hw/rtl/interfaces/VX_decode_sched_if.sv) | Interface 정의 | `wire unlock;` |

---

## 디버깅 팁

### RTL Trace

```systemverilog
// VX_schedule.sv에 추가
`ifdef DBG_TRACE_CORE_PIPELINE
    always @(posedge clk) begin
        if (sched_csr_if.unlock_warp) begin
            $display("[%0t] UNLOCK: wid=%0d (CSR unlock)", 
                     $time, sched_csr_if.unlock_wid);
        end
        
        if (decode_sched_if.valid && decode_sched_if.unlock) begin
            $display("[%0t] UNLOCK: wid=%0d (Decode unlock)", 
                     $time, decode_sched_if.wid);
        end
        
        for (int i = 0; i < `NUM_ALU_BLOCKS; i++) begin
            if (branch_valid[i]) begin
                $display("[%0t] UNLOCK: wid=%0d (Branch unlock, taken=%b, dest=0x%h)", 
                         $time, branch_wid[i], branch_taken[i], branch_dest[i]);
            end
        end
    end
`endif
```

### 예상 출력

```
[100] UNLOCK: wid=0 (Decode unlock)
[150] UNLOCK: wid=1 (Branch unlock, taken=1, dest=0x00001008)
[200] UNLOCK: wid=0 (CSR unlock)
```

---

## 요약

| 항목 | 내용 |
|------|------|
| **목적** | Stalled warp를 다시 실행 가능하도록 unlock |
| **Stall 원인** | Branch, FPU CSR, Warp control 명령어 |
| **Unlock 경로** | 9가지 (Decode, CSR, WSPAWN, TMC, SPLIT, JOIN, Barrier, Branch 등) |
| **핵심 레지스터** | `stalled_warps[NUM_WARPS]` |
| **주요 신호** | `decode_sched_if.unlock`, `sched_csr_if.unlock_warp` |
| **타이밍** | 명령어 처리 완료 시 (decode/execute/commit 단계) |
| **특이점** | FPU CSR만 pending 명령어 완료 대기 후 unlock |

**핵심**: Warp stall/unlock 메커니즘은 Vortex GPGPU의 **순차 실행 보장** 및 **동기화**를 위한 필수 기능으로, 각 명령어 타입에 맞는 unlock 조건을 통해 정확한 실행 순서를 유지합니다!

---

*문서 작성일: 2025-12-22*  
*Vortex GPGPU Project - Warp Unlock Mechanism Analysis*
