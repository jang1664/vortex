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

`include "VX_fpu_define.vh"

///////////////////////////////////////////////////////////////////////////////
// VX_fpu_csr_if - FPU ↔ SFU FPU CSR 인터페이스
///////////////////////////////////////////////////////////////////////////////
//
// [개요]
// FPU Unit과 SFU (CSR 유닛) 간의 FPU 관련 CSR 통신 인터페이스.
// 반올림 모드(frm) 읽기와 예외 플래그(fflags) 쓰기를 처리.
//
// [데이터 흐름]
// VX_fpu_unit (Execute) ←──[fpu_csr_if]──→ VX_sfu_unit (Execute/CSR)
//      │                                         │
//      ├─→ write_enable, write_wid, write_fflags │  (FPU → SFU: 예외 플래그)
//      │                                         │
//      │←── read_wid ─────────────────────────→│  (SFU → FPU: frm 조회)
//      │←── read_frm ──────────────────────────←│  (SFU 응답)
//
// [FPU → SFU: 예외 플래그 쓰기]
// - write_enable: fflags 업데이트 요청
//     - FPU 연산 완료 시 예외 발생하면 1
// - write_wid [NW_WIDTH-1:0]: 업데이트할 warp ID
//     - 각 warp별로 독립적인 fflags 유지
// - write_fflags [fflags_t]: 예외 플래그 값
//     - NV (Invalid): 잘못된 연산 (0/0, sqrt(-1) 등)
//     - DZ (Divide by Zero): 0으로 나눔
//     - OF (Overflow): 오버플로우
//     - UF (Underflow): 언더플로우
//     - NX (Inexact): 정밀도 손실
//     - 기존 fflags와 OR 연산 (sticky bits)
//
// [SFU → FPU: 반올림 모드 읽기]
// - read_wid [NW_WIDTH-1:0]: frm 조회할 warp ID
//     - FPU 연산 시작 시 해당 warp의 frm 조회
// - read_frm [INST_FRM_BITS-1:0]: 반올림 모드 응답
//     - RNE (000): Round to Nearest, ties to Even
//     - RTZ (001): Round towards Zero
//     - RDN (010): Round Down (-∞)
//     - RUP (011): Round Up (+∞)
//     - RMM (100): Round to Nearest, ties to Max Magnitude
//     - DYN (111): 명령어에서 지정한 모드 사용
//
// [RISC-V FPU CSR]
// - fflags (0x001): 예외 플래그 (5비트)
// - frm (0x002): 반올림 모드 (3비트)
// - fcsr (0x003): frm + fflags 결합 (8비트)
//
// [Warp별 CSR 관리]
// - 각 warp가 독립적인 fflags, frm 값 유지
// - CSR 접근 시 warp ID로 적절한 값 선택
// - 이 인터페이스는 NUM_FPU_BLOCKS 개의 배열로 사용됨
//
///////////////////////////////////////////////////////////////////////////////

interface VX_fpu_csr_if import VX_gpu_pkg::*, VX_fpu_pkg::*; ();

    // FPU → SFU: 예외 플래그 업데이트
    wire                    write_enable;   // fflags 업데이트 요청
    wire [NW_WIDTH-1:0]     write_wid;      // 대상 warp ID
    fflags_t                write_fflags;   // 예외 플래그 값 (NV, DZ, OF, UF, NX)

    // SFU → FPU: 반올림 모드 조회
    wire [NW_WIDTH-1:0]     read_wid;       // frm 조회할 warp ID
    wire [INST_FRM_BITS-1:0] read_frm;      // 반올림 모드 응답

    // Master: FPU Unit
    modport master (
        output write_enable,
        output write_wid,
        output write_fflags,

        output read_wid,
        input  read_frm
    );

    // Slave: SFU Unit (CSR 관리)
    modport slave (
        input  write_enable,
        input  write_wid,
        input  write_fflags,

        input  read_wid,
        output read_frm
    );

endinterface
