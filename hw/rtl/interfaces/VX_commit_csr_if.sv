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
// VX_commit_csr_if - Commit → SFU CSR 업데이트 인터페이스
///////////////////////////////////////////////////////////////////////////////
//
// [개요]
// Commit Stage에서 SFU (CSR 유닛)로 완료된 명령어 수를 전달.
// minstret CSR (retired instructions counter) 업데이트에 사용.
//
// [데이터 흐름]
// VX_commit (Commit) ──[commit_csr_if]──> VX_sfu_unit (Execute/CSR)
//                                              ↓
//                                        minstret CSR 업데이트
//
// [신호 설명]
// - instret [PERF_CTR_BITS-1:0]: 완료된 명령어 수 (누적)
//     - RISC-V minstret CSR 값
//     - 코어 시작부터 현재까지 retire된 명령어 총 수
//     - CSR 읽기 시 이 값 반환
//
// [RISC-V CSR 관계]
// - minstret (0xB02): 완료된 명령어 수 (하위 32비트 또는 전체)
// - minstreth (0xB82): 완료된 명령어 수 (상위 32비트, RV32용)
// - PERF_CTR_BITS = 44비트 → 64비트 확장 가능
//
// [사용처]
// - 성능 측정: instructions per cycle (IPC) 계산
// - 프로파일링: 특정 코드 구간의 명령어 수 측정
// - 디버깅: 실행 진행 상황 모니터링
//
// [업데이트 타이밍]
// - 매 사이클 업데이트 (VX_commit에서)
// - 여러 명령어가 동시에 commit되면 한 번에 증가
// - Warp 내 활성 스레드 수와 무관 (명령어 단위)
//
///////////////////////////////////////////////////////////////////////////////

interface VX_commit_csr_if import VX_gpu_pkg::*; ();

    // 완료된 명령어 수 (누적 카운터)
    wire [PERF_CTR_BITS-1:0] instret; // retired instruction counts

    // Master: Commit Stage
    modport master (
        output instret
    );

    // Slave: SFU Unit (CSR 관리)
    modport slave (
        input instret
    );

endinterface
