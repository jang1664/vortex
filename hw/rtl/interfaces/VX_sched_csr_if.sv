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
// VX_sched_csr_if - Scheduler ↔ SFU CSR 인터페이스
///////////////////////////////////////////////////////////////////////////////
//
// [개요]
// Scheduler와 SFU (CSR 유닛) 간의 양방향 인터페이스.
// Scheduler는 시스템 상태를 제공하고, SFU는 CSR 접근 관련 요청/응답을 수행.
//
// [데이터 흐름]
// VX_schedule (Schedule) ←──[sched_csr_if]──→ VX_sfu_unit (Execute)
//        │                                           │
//        ├─→ cycles, active_warps, thread_masks ────→│  (Scheduler → SFU)
//        │                                           │
//        │←── alm_empty_wid, unlock_wid/warp ───────←│  (SFU → Scheduler)
//        │                                           │
//        ├─→ alm_empty ──────────────────────────────│  (Scheduler 응답)
//
// [Scheduler → SFU 신호 (CSR 읽기용)]
// - cycles [PERF_CTR_BITS-1:0]: 코어 busy 사이클 카운터
//     - mcycle CSR 값
//     - 코어 시작부터 현재까지의 클럭 사이클
// - active_warps [NUM_WARPS-1:0]: 활성 warp 마스크
//     - 각 비트가 해당 warp의 활성 상태
//     - 커널 실행 중인 warp 식별
// - thread_masks [NUM_WARPS][NUM_THREADS-1:0]: 각 warp의 스레드 마스크
//     - 각 warp에서 어떤 스레드가 활성화되어 있는지
//     - divergence 상태 추적
//
// [SFU → Scheduler 신호 (Almost Empty 조회)]
// - alm_empty_wid [NW_WIDTH-1:0]: almost empty 조회할 warp ID
//     - CSR 명령어 실행 시 해당 warp의 pending 상태 확인
// - alm_empty: 해당 warp의 almost empty 상태 응답
//     - 1: pending 명령어가 적음 (거의 비어있음)
//     - 0: 아직 많은 명령어가 in-flight
//     - FPU CSR 접근 시 타이밍 결정에 사용
//
// [SFU → Scheduler 신호 (Warp Unlock)]
// - unlock_warp: warp unlock 요청
//     - FPU CSR 접근 명령어 실행 완료 시
//     - Scoreboard에서 해당 warp 스케줄링 재개
// - unlock_wid [NW_WIDTH-1:0]: unlock할 warp ID
//
// [FPU CSR 접근 시나리오]
// FPU CSR (frm, fflags, fcsr) 접근 시:
// 1. CSR 명령어가 SFU에서 실행 시작
// 2. SFU가 alm_empty_wid로 해당 warp 조회
// 3. Scheduler가 alm_empty 응답 (pending FPU 명령어 확인)
// 4. alm_empty=1이면 FPU CSR 안전하게 접근 가능
// 5. CSR 접근 완료 후 unlock_warp 신호로 warp 재개
//
// 이 메커니즘은 FPU 명령어의 out-of-order 완료와 CSR 접근 간의
// 정확한 순서 보장을 위해 필요함.
//
///////////////////////////////////////////////////////////////////////////////

interface VX_sched_csr_if import VX_gpu_pkg::*; ();

    // Scheduler → SFU: 시스템 상태 (CSR 읽기용)
    wire [PERF_CTR_BITS-1:0]        cycles;               // 코어 사이클 카운터
    wire [`NUM_WARPS-1:0]           active_warps;         // 활성 warp 마스크
    wire [`NUM_WARPS-1:0][`NUM_THREADS-1:0] thread_masks; // 각 warp의 스레드 마스크

    // SFU → Scheduler: Almost empty 조회
    wire [NW_WIDTH-1:0]             alm_empty_wid;        // 조회할 warp ID
    wire                            alm_empty;            // almost empty 응답

    // SFU → Scheduler: Warp unlock (FPU CSR 접근 후)
    wire                            unlock_warp;          // warp unlock 요청
    wire [NW_WIDTH-1:0]             unlock_wid;           // unlock할 warp ID

    // Master: Scheduler (Schedule Stage)
    modport master (
        output cycles,
        output active_warps,
        output thread_masks,
        input  alm_empty_wid,
        output alm_empty,
        input  unlock_wid,
        input  unlock_warp
    );

    // Slave: SFU Unit (Execute Stage)
    modport slave (
        input  cycles,
        input  active_warps,
        input  thread_masks,
        output alm_empty_wid,
        input  alm_empty,
        output unlock_wid,
        output unlock_warp
    );

endinterface
