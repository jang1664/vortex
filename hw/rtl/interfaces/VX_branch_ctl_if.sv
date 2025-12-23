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
// VX_branch_ctl_if - ALU → Scheduler 분기 제어 인터페이스
///////////////////////////////////////////////////////////////////////////////
//
// [개요]
// ALU Unit에서 분기 명령어 실행 결과를 Scheduler로 전달하는 인터페이스.
// Scheduler는 이 정보를 받아 해당 warp의 PC를 업데이트한다.
//
// [데이터 흐름]
// VX_alu_unit (Execute) ──[branch_ctl_if]──> VX_schedule (Schedule)
//                                                ↓
//                                          PC 업데이트
//                                                ↓
//                                          다음 fetch 주소 결정
//
// [신호 설명]
// - valid: 분기 명령어 실행 완료
//     - BEQ, BNE, BLT, BGE, BLTU, BGEU (조건 분기)
//     - JAL, JALR (무조건 점프)
// - wid [NW_WIDTH-1:0]: Warp ID
//     - PC 업데이트할 warp 식별
// - taken: 분기 taken 여부
//     - 1: 분기 조건 충족, dest로 점프
//     - 0: 분기 조건 불충족, PC+4로 진행
//     - JAL/JALR은 항상 taken=1
// - dest [PC_BITS-1:0]: 분기 목적지 주소
//     - taken=1일 때 새로운 PC 값
//     - 조건 분기: PC + imm (sign-extended)
//     - JAL: PC + imm
//     - JALR: (rs1 + imm) & ~1
//
// [SIMT 분기 처리]
// - Vortex는 reconvergence 스택 (IPDOM) 사용
// - 분기 divergence 시 SPLIT 명령어로 처리
// - branch_ctl_if는 warp-level 분기 결과 전달
// - 스레드 간 divergence는 warp_ctl_if의 SPLIT으로 처리
//
// [파이프라인 영향]
// - 분기 미스프레딕션 시 파이프라인 flush 필요
// - Vortex는 분기 예측 없음 (stall until resolved)
// - 분기 결과가 확정될 때까지 해당 warp 스케줄링 중단
//
///////////////////////////////////////////////////////////////////////////////

interface VX_branch_ctl_if import VX_gpu_pkg::*; ();

    wire                valid;  // 분기 명령어 실행 완료
    wire [NW_WIDTH-1:0] wid;    // Warp ID
    wire                taken;  // 분기 taken 여부
    wire [PC_BITS-1:0]  dest;   // 분기 목적지 주소

    // Master: ALU Unit (Execute Stage)
    modport master (
        output valid,
        output wid,
        output taken,
        output dest
    );

    // Slave: Scheduler (Schedule Stage)
    modport slave (
        input valid,
        input wid,
        input taken,
        input dest
    );

endinterface
