# Schedule Stage - Warp 스케줄링 및 제어 흐름 관리

## 개요
Schedule stage는 Vortex GPU 파이프라인의 **첫 번째 단계**로, 실행할 warp를 선택하고 PC 및 thread mask를 관리하는 핵심 모듈이다.

**파일**: `hw/rtl/core/VX_schedule.sv`

## 파이프라인 위치
```
[SCHEDULE] → Fetch → Decode → Issue → Execute → Commit
```

Schedule stage는 파이프라인의 시작점으로, 다른 모든 stage들이 실행할 명령어를 결정한다.

---

## 주요 역할

### 1. **Warp Scheduling**
- 실행 가능한 warp 중 하나를 선택하여 Fetch stage로 전송
- Priority encoder 사용 (라운드 로빈 방식)

### 2. **PC 관리**
- 각 warp의 Program Counter 추적
- Branch, JOIN, WSPAWN 시 PC 업데이트

### 3. **Thread Mask 관리**
- 각 warp의 활성 thread 추적
- SPLIT, TMC, PRED 명령어로 mask 업데이트

### 4. **Stall 관리**
- Branch, warp control 명령어 실행 시 warp stall
- Decode/Execute/Commit에서 unlock 신호 수신 시 재개

### 5. **Divergence 처리**
- SPLIT/JOIN을 통한 thread divergence 관리
- VX_split_join 서브모듈로 IPDOM stack 처리

### 6. **Barrier 동기화**
- Local/Global barrier 관리
- Barrier ID별 warp 카운터 추적

---

## 주요 인터페이스

### 입력 인터페이스

#### 1. Warp Control Interface (Execute → Schedule)
```systemverilog
VX_warp_ctl_if.slave warp_ctl_if
- valid: Warp control 명령어 실행
- wid: Warp ID
- tmc: TMC 명령어 정보 {valid, tmask}
- wspawn: WSPAWN 명령어 정보 {valid, wmask, pc}
- split: SPLIT 명령어 정보 {valid, is_dvg, then_tmask, else_tmask}
- sjoin: JOIN 명령어 정보 {valid, stack_ptr}
- barrier: Barrier 명령어 정보 {valid, id, size_m1, is_global, is_noop}
```

#### 2. Branch Control Interface (Execute → Schedule)
```systemverilog
VX_branch_ctl_if.slave branch_ctl_if[NUM_ALU_BLOCKS]
- valid: Branch 명령어 실행
- wid: Warp ID
- taken: Branch taken 여부
- dest: Branch destination PC
```

#### 3. Decode Unlock Interface (Decode → Schedule)
```systemverilog
VX_decode_sched_if.slave decode_sched_if
- valid: Unlock 신호
- unlock: Warp stall 해제 플래그
- wid: 해제할 warp ID
```

#### 4. Issue Interface (Issue → Schedule)
```systemverilog
VX_issue_sched_if.slave issue_sched_if[ISSUE_WIDTH]
- valid: 명령어 issue 완료
- wis: Warp-in-socket index
```
Pending instruction counter 업데이트에 사용.

#### 5. Commit Interface (Commit → Schedule)
```systemverilog
VX_commit_sched_if.slave commit_sched_if
- committed_warps[NUM_WARPS]: 각 warp의 명령어 commit 완료
```
Pending instruction counter 감소에 사용.

### 출력 인터페이스

#### 1. Schedule Interface (Schedule → Fetch)
```systemverilog
VX_schedule_if.master schedule_if
- valid, ready: Handshake
- data.wid: 선택된 warp ID (NW_WIDTH)
- data.PC: Program Counter (PC_BITS)
- data.tmask: Thread mask (NUM_THREADS)
- data.uuid: Debug UUID (UUID_WIDTH)
```

#### 2. CSR Interface (Schedule → CSR)
```systemverilog
VX_sched_csr_if.master sched_csr_if
- cycles: 실행 사이클 수
- active_warps: 활성 warp mask
- thread_masks: 각 warp의 thread mask
- alm_empty: 특정 warp의 pending 명령어 거의 비었는지
- unlock_warp: CSR 명령어로 warp unlock
- unlock_wid: unlock할 warp ID
```

#### 3. Global Barrier Interface (Schedule → GBAR)
```systemverilog
VX_gbar_bus_if.master gbar_bus_if (GBAR_ENABLE시)
- req_valid, req_ready
- req_data.id: Barrier ID
- req_data.size_m1: 필요한 core 수 - 1
- req_data.core_id: 현재 core ID
- rsp_valid: Barrier 해제 신호
- rsp_data.id: 해제된 barrier ID
```

---

## 핵심 상태 레지스터

### 1. Warp 상태 관리
```systemverilog
reg [NUM_WARPS-1:0] active_warps;   // 활성화된 warps
reg [NUM_WARPS-1:0] stalled_warps;  // stall된 warps (branch/wctl 실행 중)
```

**ready_warps 계산**:
```systemverilog
wire [NUM_WARPS-1:0] ready_warps = active_warps & ~stalled_warps;
```
실행 가능한 warp = 활성화되었지만 stall되지 않은 warp.

### 2. 각 Warp별 상태
```systemverilog
reg [NUM_WARPS-1:0][NUM_THREADS-1:0] thread_masks;  // 각 warp의 활성 threads
reg [NUM_WARPS-1:0][PC_BITS-1:0] warp_pcs;          // 각 warp의 PC
```

### 3. Barrier 상태
```systemverilog
reg [NUM_BARRIERS-1:0][NUM_WARPS-1:0] barrier_masks;  // 각 barrier에 도달한 warps
reg [NUM_BARRIERS-1:0][NW_WIDTH-1:0] barrier_ctrs;    // 각 barrier 카운터
```

### 4. WSPAWN 상태
```systemverilog
wspawn_t wspawn;              // 대기 중인 wspawn 정보 {valid, wmask, pc}
reg [NW_WIDTH-1:0] wspawn_wid;  // wspawn을 실행한 warp ID
reg is_single_warp;             // 현재 단일 warp만 활성화되었는지
```

---

## 핵심 동작 흐름

### 1. Warp Selection (Priority Encoder)

```systemverilog
wire [NUM_WARPS-1:0] ready_warps = active_warps & ~stalled_warps;

VX_priority_encoder #(.N (NUM_WARPS)) wid_select (
    .data_in   (ready_warps),
    .index_out (schedule_wid),     // 선택된 warp ID
    .valid_out (schedule_valid),   // ready warp 존재 여부
    ...
);
```

**동작**:
1. `ready_warps` 계산: 실행 가능한 warp들
2. Priority encoder: 가장 낮은 인덱스의 ready warp 선택 (라운드 로빈)
3. `schedule_valid`: ready warp가 하나라도 있으면 1

### 2. Schedule Data 준비

```systemverilog
wire [NUM_WARPS-1:0][(NUM_THREADS + PC_BITS)-1:0] schedule_data;
for (genvar i = 0; i < NUM_WARPS; ++i) begin
    assign schedule_data[i] = {thread_masks[i], warp_pcs[i]};
end

assign {schedule_tmask, schedule_pc} = schedule_data[schedule_wid];
```

**동작**: 선택된 warp의 PC와 thread mask를 읽어 Fetch로 전송.

### 3. Output Elastic Buffer

```systemverilog
VX_elastic_buffer #(
    .DATAW (NUM_THREADS + PC_BITS + NW_WIDTH + UUID_WIDTH),
    .SIZE  (2),
    .OUT_REG (1)  // Fetch의 BRAM 접근을 위한 레지스터
) out_buf (
    .data_in   ({schedule_tmask, schedule_pc, schedule_wid, instr_uuid}),
    .data_out  ({schedule_if.data.tmask, schedule_if.data.PC, 
                 schedule_if.data.wid, schedule_if.data.uuid}),
    ...
);
```

**이유**: 
- Fetch stage가 backpressure 걸 때 buffering
- OUT_REG=1로 Fetch의 tag store BRAM 접근 타이밍 개선

---

## 제어 흐름 처리

### 1. Branch 처리

**입력**: Execute의 ALU block에서 branch 결과 전송
```systemverilog
// Branch handling
for (integer i = 0; i < NUM_ALU_BLOCKS; ++i) begin
    if (branch_valid[i]) begin
        if (branch_taken[i]) begin
            warp_pcs_n[branch_wid[i]] = branch_dest[i];  // PC 업데이트
        end
        stalled_warps_n[branch_wid[i]] = 0;  // unlock warp
    end
end
```

**타임라인**:
1. Branch 명령어가 Schedule → Fetch → Decode 진행
2. Decode에서 branch 감지 → **warp stall**
3. Execute에서 branch 평가 → `branch_ctl_if`로 결과 전송
4. Schedule에서 PC 업데이트 및 **warp unlock**

### 2. SPLIT/JOIN 처리 (Divergence)

**VX_split_join 서브모듈**:
```systemverilog
VX_split_join split_join (
    .valid      (warp_ctl_if.valid),
    .wid        (warp_ctl_if.wid),
    .split      (warp_ctl_if.split),   // SPLIT 정보
    .sjoin      (warp_ctl_if.sjoin),   // JOIN 정보
    .join_valid (join_valid),          // JOIN 결과
    .join_is_dvg(join_is_dvg),
    .join_is_else(join_is_else),       // Else 경로로 전환 여부
    .join_wid   (join_wid),
    .join_tmask (join_tmask),          // 복원할 thread mask
    .join_pc    (join_pc),             // Else 경로 PC
    ...
);
```

**SPLIT 처리**:
```systemverilog
if (warp_ctl_if.valid && warp_ctl_if.split.valid) begin
    if (warp_ctl_if.split.is_dvg) begin
        thread_masks_n[warp_ctl_if.wid] = warp_ctl_if.split.then_tmask;
    end
    stalled_warps_n[warp_ctl_if.wid] = 0; // unlock warp
end
```
- `is_dvg`: Divergent인지 (then/else 모두 활성 thread 있음)
- Divergent이면 **then_tmask로 mask 업데이트**
- IPDOM stack은 VX_split_join에서 자동 관리

**JOIN 처리**:
```systemverilog
if (join_valid) begin
    if (join_is_dvg) begin
        if (join_is_else) begin
            warp_pcs_n[join_wid] = join_pc;  // ← Else 경로로 PC 변경!
        end
        thread_masks_n[join_wid] = join_tmask;  // Mask 업데이트
    end
    stalled_warps_n[join_wid] = 0; // unlock warp
end
```

**핵심 포인트**:
- `join_is_else == 1`: **첫 번째 JOIN** (Then 블록 끝) → PC를 merge 블록으로 변경
- `join_is_else == 0`: **두 번째 JOIN** (Else 블록 끝) → PC 변경 없음 (fallthrough)
- Thread mask는 두 경우 모두 업데이트

이것이 **split_join_detailed_analysis.md**에서 설명한 메커니즘의 **하드웨어 구현**이다!

### 3. TMC (Thread Mask Control) 처리

```systemverilog
if (warp_ctl_if.valid && warp_ctl_if.tmc.valid) begin
    active_warps_n[warp_ctl_if.wid]  = (warp_ctl_if.tmc.tmask != 0);
    thread_masks_n[warp_ctl_if.wid]  = warp_ctl_if.tmc.tmask;
    stalled_warps_n[warp_ctl_if.wid] = 0; // unlock warp
end
```

**동작**:
- `TMC count` 명령어로 활성 thread 수 설정
- `tmask == 0`이면 warp 비활성화

### 4. WSPAWN (Warp Spawn) 처리

**2-Phase 처리**:

**Phase 1: Execute에서 요청**
```systemverilog
if (warp_ctl_if.valid && warp_ctl_if.wspawn.valid) begin
    wspawn.valid <= 1;
    wspawn.wmask <= warp_ctl_if.wspawn.wmask;  // 활성화할 warps
    wspawn.pc    <= warp_ctl_if.wspawn.pc;     // 시작 PC
    wspawn_wid   <= warp_ctl_if.wid;
end
```

**Phase 2: Single warp 상태에서만 실행**
```systemverilog
if (wspawn.valid && is_single_warp) begin
    active_warps_n |= wspawn.wmask;  // 새 warps 활성화
    for (integer i = 0; i < NUM_WARPS; ++i) begin
        if (wspawn.wmask[i]) begin
            thread_masks_n[i][0] = 1;  // 첫 번째 thread만 활성화
            warp_pcs_n[i] = wspawn.pc;
        end
    end
    stalled_warps_n[wspawn_wid] = 0; // unlock 요청한 warp
    wspawn.valid <= 0;
end
```

**왜 `is_single_warp` 조건?**
- WSPAWN은 모든 warp의 상태를 변경하는 global operation
- 다른 warps가 실행 중이면 race condition 발생 가능
- 단일 warp만 남았을 때 안전하게 실행

**is_single_warp 계산**:
```systemverilog
wire [CLOG2(NUM_WARPS+1)-1:0] active_warps_cnt;
POP_COUNT(active_warps_cnt, active_warps);

is_single_warp <= (active_warps_cnt == 1);
```

---

## Barrier 동기화

### 1. Local Barrier

```systemverilog
curr_barrier_mask_p1 = barrier_masks[warp_ctl_if.barrier.id];
curr_barrier_mask_p1[warp_ctl_if.wid] = 1;

if (warp_ctl_if.valid && warp_ctl_if.barrier.valid) begin
    if (~warp_ctl_if.barrier.is_global) begin
        if (barrier_ctrs[id] == size_m1) begin
            // 모든 warps 도달 → Barrier 해제
            barrier_ctrs_n[id] = '0;
            barrier_masks_n[id] = '0;
            stalled_warps_n &= ~barrier_masks[id];  // unlock all warps
        end else begin
            // 아직 대기 중
            barrier_ctrs_n[id] = barrier_ctrs[id] + 1;
            barrier_masks_n[id] = curr_barrier_mask_p1;
        end
    end
end
```

**동작**:
1. Warp가 barrier에 도달 → `barrier_masks[id][wid] = 1`
2. Counter 증가
3. Counter == size_m1 → 모든 warp unlock

### 2. Global Barrier (GBAR_ENABLE)

```systemverilog
if (warp_ctl_if.valid && warp_ctl_if.barrier.valid
 && warp_ctl_if.barrier.is_global
 && (curr_barrier_mask_p1 == active_warps)) begin  // 모든 local warps 도달
    gbar_req_valid <= 1;
    gbar_req_id <= warp_ctl_if.barrier.id;
    gbar_req_size_m1 <= warp_ctl_if.barrier.size_m1;
end
```

**응답 처리**:
```systemverilog
if (gbar_bus_if.rsp_valid && (gbar_req_id == gbar_bus_if.rsp_data.id)) begin
    barrier_ctrs_n[id] = '0;
    barrier_masks_n[id] = '0;
    stalled_warps_n = '0;  // unlock ALL warps
end
```

**Global barrier 플로우**:
1. 모든 local warps가 barrier 도달 → Global barrier controller에 요청
2. 다른 cores도 모두 도달 → Global barrier 해제 신호
3. Schedule이 응답 수신 → 모든 warps unlock

---

## Stall 관리

### 1. Stall 발생 시점

```systemverilog
// Schedule fire → Decode까지 stall
if (schedule_fire) begin
    stalled_warps_n[schedule_wid] = 1;
end
```

**이유**: 
- Decode가 명령어 해석하는 동안 동일 warp의 다음 명령어 fetch 방지
- Out-of-order execution 방지

### 2. Unlock 시점

**Decode Unlock** (일반 명령어):
```systemverilog
if (decode_sched_if.valid && decode_sched_if.unlock) begin
    stalled_warps_n[decode_sched_if.wid] = 0;
end
```

**CSR Unlock** (CSR 명령어):
```systemverilog
if (sched_csr_if.unlock_warp) begin
    stalled_warps_n[sched_csr_if.unlock_wid] = 0;
end
```

**Branch Unlock** (Execute에서):
```systemverilog
if (branch_valid[i]) begin
    stalled_warps_n[branch_wid[i]] = 0;
end
```

### 3. Timeout Assertion

```systemverilog
if (timeout_enable && active_warps != 0 && active_warps == stalled_warps) begin
    timeout_ctr <= timeout_ctr + 1;
end

RUNTIME_ASSERT(timeout_ctr < STALL_TIMEOUT, 
    ("*** timeout: stalled_warps=%b", stalled_warps))
```

**목적**: 모든 warps가 영구히 stall되면 deadlock → timeout으로 감지.

---

## PC 관리

### 1. PC 증가 (Normal Flow)

```systemverilog
// Fetch가 명령어 fetch 완료 시
if (schedule_if_fire) begin
    warp_pcs_n[schedule_if.data.wid] = schedule_if.data.PC + from_fullPC(XLEN'(4));
end
```

**참고**: RISC-V는 4-byte 정렬 명령어.

### 2. PC 변경 (Control Flow)

**Branch Taken**:
```systemverilog
if (branch_taken[i]) begin
    warp_pcs_n[branch_wid[i]] = branch_dest[i];
end
```

**JOIN Else 전환**:
```systemverilog
if (join_is_else) begin
    warp_pcs_n[join_wid] = join_pc;
end
```

**WSPAWN**:
```systemverilog
if (wspawn.wmask[i]) begin
    warp_pcs_n[i] = wspawn.pc;
end
```

---

## Pending Instruction Tracking

```systemverilog
for (genvar i = 0; i < NUM_WARPS; ++i) begin
    VX_pending_size #(.SIZE (4096), .ALM_EMPTY (1)) counter (
        .incr  (issue_sched_if[isw].valid && (issue_sched_if[isw].wis == wis)),
        .decr  (commit_sched_if.committed_warps[i]),
        .empty (pending_warp_empty[i]),
        .alm_empty (pending_warp_alm_empty[i]),
        ...
    );
end
```

**용도**:
- 각 warp별 파이프라인 내 명령어 수 추적
- Issue → increment
- Commit → decrement
- `alm_empty`: CSR read에서 사용 (거의 비었는지 확인)

**Busy 신호**:
```systemverilog
wire no_pending_instr = (& pending_warp_empty);
assign busy = (active_warps != 0 || ~no_pending_instr);
```
활성 warp가 있거나 pending 명령어가 있으면 busy.

---

## 초기화 및 Reset

```systemverilog
if (reset) begin
    barrier_masks   <= '0;
    barrier_ctrs    <= '0;
    stalled_warps   <= '0;
    warp_pcs        <= '0;
    active_warps    <= '0;
    thread_masks    <= '0;
    wspawn.valid    <= 0;

    // 첫 번째 warp 활성화
    warp_pcs[0]     <= from_fullPC(base_dcrs.startup_addr);
    active_warps[0] <= 1;
    thread_masks[0][0] <= 1;
    is_single_warp  <= 1;
end
```

**부팅 시**:
- Warp 0만 활성화
- Thread 0만 활성화
- PC = `startup_addr` (boot vector)
- Single warp 모드

---

## 성능 카운터 (PERF_ENABLE)

```systemverilog
wire schedule_idle = ~schedule_valid;  // Ready warp 없음
wire schedule_stall = schedule_if.valid && ~schedule_if.ready;  // Fetch backpressure

assign sched_perf.idles = perf_sched_idles;
assign sched_perf.stalls = perf_sched_stalls;
```

**메트릭**:
- `idles`: Ready warp 없어서 idle한 사이클 수
- `stalls`: Fetch가 ready 안 되어 stall된 사이클 수

---

## 디버그 트레이스

```systemverilog
`ifdef DBG_TRACE_PIPELINE
    if (schedule_fire) begin
        TRACE(1, ("%t: %s: wid=%0d, PC=0x%0h, tmask=%b (#%0d)\n", 
            $time, INSTANCE_ID, schedule_wid, to_fullPC(schedule_pc), 
            schedule_tmask, instr_uuid))
    end
`endif
```

**출력 예시**:
```
1234: core-schedule: wid=0, PC=0x80000000, tmask=0001 (#1)
1235: core-schedule: wid=1, PC=0x80000004, tmask=0011 (#2)
```

---

## 설계 특징

### 1. 중앙집중식 제어
- 모든 warp의 PC, thread mask를 한 곳에서 관리
- 제어 흐름 명령어(branch, split, join)가 Schedule에 feedback

### 2. Stall-on-Issue
- 명령어를 schedule하면 즉시 stall
- Decode가 unlock할 때까지 대기
- 같은 warp의 명령어가 순서대로 실행되도록 보장

### 3. Priority-based Round Robin
- 가장 낮은 인덱스의 ready warp 선택
- 공정한 warp 스케줄링

### 4. 2-Stage Pipelining
- Schedule → Elastic Buffer → Fetch
- Backpressure 처리 및 타이밍 개선

### 5. IPDOM Stack 분리
- VX_split_join 서브모듈로 복잡한 divergence 로직 분리
- Schedule은 결과만 받아서 PC/mask 업데이트

### 6. Global Barrier 지원
- Local barrier는 scheduler 내부 처리
- Global barrier는 외부 controller와 통신

---

## 주요 서브모듈

### 1. VX_split_join
- IPDOM stack 관리
- SPLIT/JOIN 처리
- 상세: [VX_split_join.sv](../../hw/rtl/core/VX_split_join.sv)

### 2. VX_priority_encoder
- Ready warps 중 선택
- 가장 낮은 인덱스 우선

### 3. VX_elastic_buffer
- Schedule → Fetch buffering
- Backpressure 흡수

### 4. VX_pending_size
- Warp별 pending instruction counter
- Issue/Commit 추적

### 5. VX_uuid_gen (UUID_ENABLE)
- 각 명령어에 고유 UUID 부여
- 디버깅 및 트레이싱용

---

## 타이밍 다이어그램

### 일반 명령어 실행
```
Cycle   Schedule    Stall   Action
--------------------------------------
0       wid=0 선택  False   Schedule fire
1       -           True    Warp 0 stalled
2       -           True    Decode processing
3       wid=1 선택  False   Decode unlocks warp 0
```

### Branch 명령어 실행
```
Cycle   Schedule    Stall   PC      Action
-------------------------------------------
0       wid=0 BR    False   0x100   Schedule fire
1       -           True    0x100   Warp 0 stalled
2       -           True    0x100   Decode detects branch
3       -           True    0x100   Execute evaluates
4       wid=0       False   0x200   Branch result → PC update & unlock
```

### SPLIT/JOIN 실행 (Divergent)
```
Cycle   Event           PC      Tmask   Note
-----------------------------------------------
0       SPLIT           0x100   1111    Divergence detected
1       Stall           0x100   0011    Then mask applied
2       Then block      0x110   0011    Execute then path
3       JOIN (1st)      0x120   0011    Join_is_else=1
4       Stall           0x200   1100    PC jump + Else mask
5       Else block      0x210   1100    Execute else path
6       JOIN (2nd)      0x220   1100    Join_is_else=0
7       Merge           0x120   1111    Restore mask, no PC jump
```

---

## 문제 해결 가이드

### 1. 모든 Warps Stalled (Deadlock)
**증상**: `timeout_ctr` assertion 발생

**원인**:
- Decode/Execute가 unlock 신호 안 보냄
- Barrier count 불일치

**디버그**:
- `stalled_warps` 비트 확인
- `barrier_masks`, `barrier_ctrs` 확인
- Decode/Execute unlock 신호 확인

### 2. Warp가 Schedule되지 않음
**증상**: 특정 warp가 실행 안 됨

**원인**:
- `active_warps[wid] == 0` (비활성화)
- `stalled_warps[wid] == 1` (영구 stall)

**디버그**:
- WSPAWN, TMC 명령어 실행 확인
- Unlock 신호 확인

### 3. PC 점프 오류
**증상**: 잘못된 주소로 점프

**원인**:
- Branch destination 계산 오류
- JOIN PC 잘못 설정
- IPDOM stack 손상

**디버그**:
- `warp_pcs` 변화 추적
- VX_split_join 출력 확인
- Branch_ctl_if 신호 확인

### 4. Thread Mask 불일치
**증상**: 잘못된 threads 활성화

**원인**:
- SPLIT then_tmask 계산 오류
- TMC tmask 잘못 설정

**디버그**:
- `thread_masks` 추적
- Warp_ctl_if 신호 확인

---

## 관련 문서

### ISA 및 소프트웨어
- [Vortex ISA Extensions](../../docs/software/vortex_isa_extensions.md) - SPLIT/JOIN/TMC/WSPAWN/BAR 명령어
- [SPLIT/JOIN 상세 분석](../../docs/software/split_join_detailed_analysis.md) - LLVM Pass + RTL 통합

### 하드웨어 모듈
- [Fetch Stage](01_Fetch_stage.md) - Schedule의 다음 단계
- [VX_split_join.sv](../../hw/rtl/core/VX_split_join.sv) - IPDOM stack 관리
- [VX_wctl_unit.sv](../../hw/rtl/core/VX_wctl_unit.sv) - Warp control 명령어 실행

### 아키텍처
- [Microarchitecture](../../docs/microarchitecture.md) - 전체 파이프라인 개요
- [Control Flow Divergence](../../docs/microarchitecture.md#control-flow-divergence) - SPLIT/JOIN 개념

---

## 요약

VX_schedule.sv는 Vortex GPU의 **심장부**로서:

1. **Warp Scheduling**: Priority encoder로 ready warp 선택
2. **PC 관리**: Branch, JOIN, WSPAWN으로 PC 업데이트
3. **Thread Mask 관리**: SPLIT, TMC로 활성 threads 제어
4. **Stall 관리**: 명령어 issue 시 stall, decode/execute에서 unlock
5. **Divergence 처리**: VX_split_join으로 IPDOM stack 관리
6. **Barrier 동기화**: Local/Global barrier 처리
7. **Pending Tracking**: 각 warp의 파이프라인 내 명령어 수 추적

Schedule stage 없이는 어떤 명령어도 실행될 수 없으며, 모든 제어 흐름은 여기서 관리된다.
