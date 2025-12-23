// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

///////////////////////////////////////////////////////////////////////////////
// VX_execute - Execute Stage Top Module
///////////////////////////////////////////////////////////////////////////////
//
// [개요]
// Vortex GPU 파이프라인의 Execute Stage를 구현하는 최상위 모듈.
// Issue Stage에서 디스패치된 명령어를 받아 적절한 실행 유닛으로 라우팅하고,
// 실행 결과를 Commit Stage로 전달한다.
//
// [파이프라인 위치]
// Schedule → Fetch → Decode → Issue → [EXECUTE] → Commit → Writeback
//
// [실행 유닛 구성] (VX_gpu_pkg.sv에서 정의)
// - EX_ALU (0): 정수 연산, 분기 (VX_alu_unit)
// - EX_LSU (1): 메모리 Load/Store (VX_lsu_unit)
// - EX_SFU (2): CSR, Warp Control 등 특수 기능 (VX_sfu_unit)
// - EX_FPU (3): 부동소수점 연산 (VX_fpu_unit) - EXT_F_ENABLE 필요
// - EX_TCU (4): Tensor Core 연산 (VX_tcu_unit) - EXT_TCU_ENABLE 필요
//
// [주요 특징]
// - In-Order Issue, Out-of-Order Completion
// - 각 실행 유닛은 ISSUE_WIDTH 개의 병렬 슬롯을 가짐
// - Scoreboard가 데이터 의존성을 관리 (Issue Stage에서 처리)
//
// [인터페이스 배치 - dispatch_if/commit_if]
//   [EX_ALU * ISSUE_WIDTH +: ISSUE_WIDTH] → ALU
//   [EX_LSU * ISSUE_WIDTH +: ISSUE_WIDTH] → LSU
//   [EX_SFU * ISSUE_WIDTH +: ISSUE_WIDTH] → SFU
//   [EX_FPU * ISSUE_WIDTH +: ISSUE_WIDTH] → FPU (조건부)
//   [EX_TCU * ISSUE_WIDTH +: ISSUE_WIDTH] → TCU (조건부)
//
///////////////////////////////////////////////////////////////////////////////

module VX_execute import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",     // 디버깅용 인스턴스 식별자
    parameter CORE_ID = 0                   // 멀티코어 환경에서 현재 코어 ID
) (
    `SCOPE_IO_DECL                          // 디버깅 스코프 I/O

    input wire              clk,
    input wire              reset,

`ifdef PERF_ENABLE
    input sysmem_perf_t     sysmem_perf,    // 메모리 계층 성능 통계 (SFU에서 CSR로 제공)
    input pipeline_perf_t   pipeline_perf,  // 파이프라인 성능 통계 (SFU에서 CSR로 제공)
`endif

    input base_dcrs_t       base_dcrs,      // Device Control Registers

    // LSU → Memory Hierarchy 인터페이스
    VX_lsu_mem_if.master    lsu_mem_if [`NUM_LSU_BLOCKS],

    // Issue Stage → Execute (명령어 디스패치)
    VX_dispatch_if.slave    dispatch_if [NUM_EX_UNITS * `ISSUE_WIDTH],

    // Execute → Commit Stage (실행 결과)
    VX_commit_if.master     commit_if [NUM_EX_UNITS * `ISSUE_WIDTH],

    // Scheduler CSR 읽기 (cycle counter, warp masks 등)
    VX_sched_csr_if.slave   sched_csr_if,

    // ALU → Scheduler (분기 결과 전달)
    VX_branch_ctl_if.master branch_ctl_if [`NUM_ALU_BLOCKS],

    // SFU → Scheduler (warp 제어: TMC, SPLIT, JOIN, BARRIER 등)
    VX_warp_ctl_if.master   warp_ctl_if,

    // Commit → SFU (instret 카운터)
    VX_commit_csr_if.slave  commit_csr_if
);

    ///////////////////////////////////////////////////////////////////////////
    // FPU CSR 인터페이스 (조건부)
    ///////////////////////////////////////////////////////////////////////////
    // FPU 활성화 시 FPU와 SFU 간 CSR 통신용 인터페이스
    // - FPU → SFU: fflags 업데이트 (예외 플래그)
    // - SFU → FPU: frm 읽기 (반올림 모드)
`ifdef EXT_F_ENABLE
    VX_fpu_csr_if fpu_csr_if[`NUM_FPU_BLOCKS]();
`endif

    ///////////////////////////////////////////////////////////////////////////
    // ALU Unit - 정수 연산 및 분기 처리
    ///////////////////////////////////////////////////////////////////////////
    // 담당 명령어:
    // - 산술: ADD, SUB, LUI, AUIPC
    // - 논리: AND, OR, XOR
    // - 시프트: SLL, SRL, SRA
    // - 비교: SLT, SLTU
    // - 분기: BEQ, BNE, BLT, BGE, JAL, JALR
    // - SIMT 확장: VOTE, SHUFFLE
    // - 조건부 제로 (Zicond): CZERO.EQZ, CZERO.NEZ
    // - M 확장: MUL, MULH, DIV, REM (EXT_M_ENABLE)
    //
    // 출력:
    // - commit_if: 연산 결과
    // - branch_ctl_if: 분기 결과 → Scheduler (PC 업데이트)
    VX_alu_unit #(
        .INSTANCE_ID (`SFORMATF(("%s-alu", INSTANCE_ID)))
    ) alu_unit (
        .clk            (clk),
        .reset          (reset),
        .dispatch_if    (dispatch_if[EX_ALU * `ISSUE_WIDTH +: `ISSUE_WIDTH]),
        .commit_if      (commit_if[EX_ALU * `ISSUE_WIDTH +: `ISSUE_WIDTH]),
        .branch_ctl_if  (branch_ctl_if)
    );

    `SCOPE_IO_SWITCH (1);   // 디버깅 스코프 전환

    ///////////////////////////////////////////////////////////////////////////
    // LSU Unit - 메모리 Load/Store 처리
    ///////////////////////////////////////////////////////////////////////////
    // 담당 명령어:
    // - Load: LB, LH, LW, LD, LBU, LHU, LWU
    // - Store: SB, SH, SW, SD
    // - FP Load/Store: FLW, FLD, FSW, FSD (EXT_F_ENABLE)
    // - Fence: 메모리 순서 보장
    //
    // 메모리 계층:
    // - Local Memory (shared/scratchpad)
    // - D-Cache → L2/L3 → DRAM
    //
    // 특징:
    // - Variable latency (캐시 히트/미스에 따라)
    // - 주소 계산: base + offset
    // - Coalescing: 같은 캐시 라인 접근 병합
    VX_lsu_unit #(
        .INSTANCE_ID (`SFORMATF(("%s-lsu", INSTANCE_ID)))
    ) lsu_unit (
        `SCOPE_IO_BIND  (0)
        .clk            (clk),
        .reset          (reset),
        .dispatch_if    (dispatch_if[EX_LSU * `ISSUE_WIDTH +: `ISSUE_WIDTH]),
        .commit_if      (commit_if[EX_LSU * `ISSUE_WIDTH +: `ISSUE_WIDTH]),
        .lsu_mem_if     (lsu_mem_if)
    );

    ///////////////////////////////////////////////////////////////////////////
    // FPU Unit - 부동소수점 연산 (조건부 인스턴스화)
    ///////////////////////////////////////////////////////////////////////////
    // 담당 명령어 (EXT_F_ENABLE 필요):
    // - 산술: FADD, FSUB, FMUL, FDIV, FSQRT
    // - FMA: FMADD, FMSUB, FNMSUB, FNMADD
    // - 비교: FEQ, FLT, FLE
    // - 변환: FCVT.W.S, FCVT.S.W, ...
    // - 이동: FMV.X.W, FMV.W.X
    // - 부호: FSGNJ, FSGNJN, FSGNJX
    // - Min/Max: FMIN, FMAX
    // - 분류: FCLASS
    //
    // 특징:
    // - 파이프라인 구조 (multi-cycle)
    // - fflags 예외 플래그 생성 → SFU로 전달
`ifdef EXT_F_ENABLE
    VX_fpu_unit #(
        .INSTANCE_ID (`SFORMATF(("%s-fpu", INSTANCE_ID)))
    ) fpu_unit (
        .clk            (clk),
        .reset          (reset),
        .dispatch_if    (dispatch_if[EX_FPU * `ISSUE_WIDTH +: `ISSUE_WIDTH]),
        .commit_if      (commit_if[EX_FPU * `ISSUE_WIDTH +: `ISSUE_WIDTH]),
        .fpu_csr_if     (fpu_csr_if)
    );
`endif

    ///////////////////////////////////////////////////////////////////////////
    // TCU Unit - Tensor Core 연산 (조건부 인스턴스화)
    ///////////////////////////////////////////////////////////////////////////
    // 담당 명령어 (EXT_TCU_ENABLE 필요):
    // - WMMA: Warp-level Matrix Multiply-Accumulate
    //
    // 특징:
    // - 행렬 연산 가속
    // - 딥 파이프라인
`ifdef EXT_TCU_ENABLE
    VX_tcu_unit #(
        .INSTANCE_ID (`SFORMATF(("%s-tcu", INSTANCE_ID)))
    ) tcu_unit (
        .clk            (clk),
        .reset          (reset),
        .dispatch_if    (dispatch_if[EX_TCU * `ISSUE_WIDTH +: `ISSUE_WIDTH]),
        .commit_if      (commit_if[EX_TCU * `ISSUE_WIDTH +: `ISSUE_WIDTH])
    );
`endif

    ///////////////////////////////////////////////////////////////////////////
    // SFU Unit - 특수 기능 유닛
    ///////////////////////////////////////////////////////////////////////////
    // 담당 명령어:
    // - CSR 접근: CSRRW, CSRRS, CSRRC (및 즉시값 버전)
    // - Warp 제어: TMC, WSPAWN, SPLIT, JOIN, BAR, PRED
    // - 성능 카운터 읽기
    // - GPU 상태: Thread ID, Warp ID, Grid 정보
    //
    // 서브 유닛:
    // - VX_wctl_unit: Warp 제어 (WSPAWN, SPLIT, JOIN, ...)
    // - VX_gather_unit: 스레드 데이터 수집
    //
    // 인터페이스:
    // - sched_csr_if: Scheduler로부터 CSR 값 읽기
    // - warp_ctl_if: Scheduler로 warp 제어 신호 전달
    // - fpu_csr_if: FPU CSR (frm, fflags) 관리
    // - commit_csr_if: instret 카운터 수신
    VX_sfu_unit #(
        .INSTANCE_ID (`SFORMATF(("%s-sfu", INSTANCE_ID))),
        .CORE_ID (CORE_ID)
    ) sfu_unit (
        .clk            (clk),
        .reset          (reset),
    `ifdef PERF_ENABLE
        .sysmem_perf    (sysmem_perf),
        .pipeline_perf  (pipeline_perf),
    `endif
        .base_dcrs      (base_dcrs),
        .dispatch_if    (dispatch_if[EX_SFU * `ISSUE_WIDTH +: `ISSUE_WIDTH]),
        .commit_if      (commit_if[EX_SFU * `ISSUE_WIDTH +: `ISSUE_WIDTH]),
    `ifdef EXT_F_ENABLE
        .fpu_csr_if     (fpu_csr_if),
    `endif
        .commit_csr_if  (commit_csr_if),
        .sched_csr_if   (sched_csr_if),
        .warp_ctl_if    (warp_ctl_if)
    );

endmodule
