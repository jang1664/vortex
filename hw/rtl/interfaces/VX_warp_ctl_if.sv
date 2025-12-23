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
// VX_warp_ctl_if - SFU → Scheduler Warp 제어 인터페이스
///////////////////////////////////////////////////////////////////////////////
//
// [개요]
// SFU Unit (VX_wctl_unit)에서 Scheduler로 warp 제어 명령어 결과를 전달.
// SIMT divergence 처리, warp 생성/종료, 배리어 동기화 등을 수행.
//
// [데이터 흐름]
// VX_sfu_unit (Execute) ──[warp_ctl_if]──> VX_schedule (Schedule)
//                                              ↓
//                                    Warp 상태 업데이트
//                                    (thread mask, PC, active warps 등)
//
// [신호 설명]
// - valid: warp 제어 명령어 실행 완료
// - wid [NW_WIDTH-1:0]: Target Warp ID
//
// [tmc_t - Thread Mask Control]
// Vortex 커스텀 명령어: TMC (Thread Mask Control)
// - valid: TMC 명령어 실행됨
// - tmask [NUM_THREADS-1:0]: 새로운 스레드 마스크
//     - 특정 스레드 활성화/비활성화
//     - tmask=0이면 warp 종료
//
// [wspawn_t - Warp Spawn]
// Vortex 커스텀 명령어: WSPAWN
// - valid: WSPAWN 명령어 실행됨
// - wmask [NUM_WARPS-1:0]: 새로 생성할 warp 마스크
// - pc [PC_BITS-1:0]: 새 warp의 시작 PC
//     - 커널 시작 시 여러 warp 동시 생성
//     - 동적 parallelism 지원
//
// [split_t - Divergence Split]
// Vortex 커스텀 명령어: SPLIT
// - valid: SPLIT 명령어 실행됨
// - is_dvg: divergence 발생 여부
//     - 1: 스레드들이 다른 경로 선택 (divergence)
//     - 0: 모든 스레드가 같은 경로 (no divergence)
// - then_tmask [NUM_THREADS-1:0]: then 경로 스레드 마스크
// - else_tmask [NUM_THREADS-1:0]: else 경로 스레드 마스크
// - next_pc [PC_BITS-1:0]: else 경로 또는 reconvergence PC
//     - IPDOM (Immediate Post Dominator) 스택에 푸시
//
// [join_t - Split Join]
// Vortex 커스텀 명령어: JOIN
// - valid: JOIN 명령어 실행됨
// - stack_ptr [DV_STACK_SIZEW-1:0]: 현재 divergence 스택 포인터
//     - 스택에서 팝하여 reconvergence 수행
//     - then 경로 완료 후 else 경로 실행
//     - else 경로 완료 후 reconvergence point에서 합류
//
// [barrier_t - Barrier Synchronization]
// Vortex 커스텀 명령어: BAR
// - valid: BAR 명령어 실행됨
// - id [NB_WIDTH-1:0]: Barrier ID
// - is_global: 글로벌 배리어 여부
//     - 0: 코어 내 배리어 (warps만)
//     - 1: 글로벌 배리어 (모든 코어, GBAR_ENABLE 필요)
// - size_m1: 동기화할 warp/코어 수 - 1
// - is_noop: warp 수가 1이면 배리어 불필요
//
// [Divergence Stack 조회]
// - dvstack_wid: 조회할 warp ID (SFU → Scheduler)
// - dvstack_ptr: 해당 warp의 현재 스택 포인터 (Scheduler → SFU)
//     - JOIN 명령어에서 스택 상태 확인용
//
///////////////////////////////////////////////////////////////////////////////

interface VX_warp_ctl_if import VX_gpu_pkg::*; ();

    wire        valid;              // Warp 제어 명령어 실행 완료
    wire [NW_WIDTH-1:0] wid;        // Target Warp ID

    tmc_t       tmc;                // Thread Mask Control
    wspawn_t    wspawn;             // Warp Spawn
    split_t     split;              // Divergence Split
    join_t      sjoin;              // Split Join (reconvergence)
    barrier_t   barrier;            // Barrier Synchronization

    // Divergence stack 조회 (JOIN 명령어용)
    wire [NW_WIDTH-1:0] dvstack_wid;        // 조회할 warp ID
    wire [DV_STACK_SIZEW-1:0] dvstack_ptr;  // 스택 포인터 응답

    // Master: SFU Unit (Execute Stage)
    modport master (
        output valid,
        output wid,
        output wspawn,
        output tmc,
        output split,
        output sjoin,
        output barrier,

        output dvstack_wid,
        input  dvstack_ptr
    );

    // Slave: Scheduler (Schedule Stage)
    modport slave (
        input valid,
        input wid,
        input wspawn,
        input tmc,
        input split,
        input sjoin,
        input barrier,

        input dvstack_wid,
        output dvstack_ptr
    );

endinterface
