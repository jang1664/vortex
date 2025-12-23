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
// VX_dispatch_if - Issue Stage → Execute Stage 디스패치 인터페이스
///////////////////////////////////////////////////////////////////////////////
//
// [개요]
// Issue Stage의 Dispatch 유닛에서 Execute Stage의 실행 유닛으로
// 명령어와 피연산자 데이터를 전달하는 인터페이스.
// Valid-Ready 핸드셰이크 프로토콜 사용.
//
// [데이터 흐름]
// VX_dispatch (Issue) ──[dispatch_if]──> VX_alu_unit / VX_lsu_unit / ... (Execute)
//
// [dispatch_t 구조] (VX_gpu_pkg.sv에서 정의)
// - uuid [UUID_WIDTH-1:0]: 명령어 고유 ID (디버깅/트레이싱용)
// - wis [ISSUE_WIS_W-1:0]: Warp Issue Slot
//     - warp ID + issue slot 정보를 인코딩
//     - commit 시 warp ID로 디코딩됨
// - sid [SIMD_IDX_W-1:0]: SIMD index
//     - SIMD_WIDTH > NUM_THREADS 시 사용
//     - 스레드를 여러 SIMD 그룹으로 분할
// - tmask [SIMD_WIDTH-1:0]: Thread mask
//     - 각 비트가 해당 스레드의 활성 상태
//     - divergence로 인해 일부 스레드만 활성화 가능
// - PC [PC_BITS-1:0]: Program Counter
//     - 현재 명령어 주소
// - op_type [INST_ALU_BITS-1:0]: 연산 타입
//     - ALU: ADD, SUB, AND, ... (INST_ALU_*)
//     - LSU: LOAD, STORE, FENCE
//     - FPU: FADD, FMUL, ... (INST_FPU_*)
//     - SFU: CSR, WCTL 등
// - op_args [op_args_t]: 연산별 인자 (union 구조)
//     - alu: use_PC, use_imm, imm, is_br, ...
//     - lsu: offset, is_store, mem_flags
//     - fpu: frm (반올림 모드)
//     - sfu: csr_addr, wctl_type 등
// - wb: Writeback 필요 여부
//     - 1: rd에 결과 기록 필요
//     - 0: Store, Branch 등 writeback 불필요
// - rd [NUM_REGS_BITS-1:0]: Destination register
//     - INT: x0-x31 (x0 제외)
//     - FP: f0-f31 (EXT_F_ENABLE)
// - rs1_data, rs2_data, rs3_data [SIMD_WIDTH][XLEN-1:0]:
//     - 소스 레지스터 데이터
//     - SIMD_WIDTH 스레드분의 데이터
//     - rs3는 FMA 명령어에서 사용
// - sop: Start of Packet
//     - 멀티사이클 명령어의 첫 번째 패킷
// - eop: End of Packet
//     - 멀티사이클 명령어의 마지막 패킷
//
// [핸드셰이크]
// - valid=1 & ready=1: 데이터 전송 완료
// - valid=1 & ready=0: 수신측 busy (backpressure)
// - valid=0: 전송할 데이터 없음
//
///////////////////////////////////////////////////////////////////////////////

interface VX_dispatch_if import VX_gpu_pkg::*; ();

    logic  valid;       // 유효한 디스패치 요청
    dispatch_t data;    // 디스패치 데이터 (명령어 + 피연산자)
    logic  ready;       // 실행 유닛의 수신 준비 상태

    // Master: Issue Stage (Dispatch)
    modport master (
        output valid,
        output data,
        input  ready
    );

    // Slave: Execute Stage (실행 유닛들)
    modport slave (
        input  valid,
        input  data,
        output ready
    );

endinterface
