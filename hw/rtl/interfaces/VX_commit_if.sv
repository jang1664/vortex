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
// VX_commit_if - Execute Stage → Commit Stage 커밋 인터페이스
///////////////////////////////////////////////////////////////////////////////
//
// [개요]
// Execute Stage의 실행 유닛에서 Commit Stage로 실행 결과를 전달하는 인터페이스.
// Valid-Ready 핸드셰이크 프로토콜 사용.
//
// [데이터 흐름]
// VX_alu_unit / VX_lsu_unit / ... (Execute) ──[commit_if]──> VX_commit (Commit)
//                                                              ↓
//                                                         VX_writeback
//                                                              ↓
//                                                    Register File 업데이트
//
// [commit_t 구조] (VX_gpu_pkg.sv에서 정의)
// - uuid [UUID_WIDTH-1:0]: 명령어 고유 ID
//     - dispatch_t.uuid와 동일
//     - 트레이싱/디버깅에 사용
// - wid [NW_WIDTH-1:0]: Warp ID
//     - 해당 명령어가 속한 warp
//     - dispatch_t.wis에서 디코딩됨
// - sid [SIMD_IDX_W-1:0]: SIMD index
//     - dispatch_t.sid와 동일
// - tmask [SIMD_WIDTH-1:0]: Thread mask
//     - 실행된 스레드들의 마스크
//     - 결과 데이터의 유효성 표시
// - PC [PC_BITS-1:0]: Program Counter
//     - 완료된 명령어의 주소
// - wb: Writeback 필요 여부
//     - 1: rd에 data 기록 필요
//     - 0: writeback 불필요 (Store, Branch 등)
// - rd [NUM_REGS_BITS-1:0]: Destination register
//     - 결과를 기록할 레지스터 번호
// - data [SIMD_WIDTH][XLEN-1:0]: 실행 결과 데이터
//     - SIMD_WIDTH 스레드분의 결과
//     - tmask가 1인 스레드만 유효
// - sop: Start of Packet
//     - 멀티사이클 명령어의 첫 번째 결과
// - eop: End of Packet
//     - 멀티사이클 명령어의 마지막 결과
//
// [Out-of-Order Completion]
// - 각 실행 유닛이 독립적으로 완료
// - Issue는 in-order이지만 commit은 out-of-order 가능
// - VX_commit에서 arbiter로 여러 유닛의 결과 병합
// - Scoreboard가 WAW/WAR hazard 방지
//
// [핸드셰이크]
// - valid=1 & ready=1: 결과 커밋 완료
// - valid=1 & ready=0: Commit stage busy (backpressure)
// - valid=0: 완료된 명령어 없음
//
///////////////////////////////////////////////////////////////////////////////

interface VX_commit_if import VX_gpu_pkg::*; ();

    logic  valid;       // 유효한 커밋 요청 (명령어 실행 완료)
    commit_t data;      // 커밋 데이터 (실행 결과)
    logic  ready;       // Commit Stage의 수신 준비 상태

    // Master: Execute Stage (실행 유닛들)
    modport master (
        output valid,
        output data,
        input  ready
    );

    // Slave: Commit Stage
    modport slave (
        input  valid,
        input  data,
        output ready
    );

endinterface
