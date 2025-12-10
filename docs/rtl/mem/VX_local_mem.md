# `mem/VX_local_mem.sv` — 상세 노트

파일: `hw/rtl/mem/VX_local_mem.sv`

목적(한 문장)
- Local memory (shared memory)를 구현하는 모듈로, 여러 워드 요청을 다중 뱅크로 분산 처리하고, read-during-write 해저드를 감지하며, 뱅크 충돌을 성능 카운터로 집계합니다.

---

## 주요 파라미터

- `INSTANCE_ID` : 인스턴스 이름 (디버그 트레이스용)
- `SIZE` : 전체 local memory 크기(바이트) — 기본값 1024*16*8 = 128KB
- `NUM_REQS` : 사이클당 워드 요청 수 (기본값 4)
- `NUM_BANKS` : 뱅크 수 (기본값 4) — 뱅크 분산으로 병렬성 향상
- `ADDR_WIDTH` : 주소 폭 (`log2(SIZE)`)
- `WORD_SIZE` : 워드 크기(바이트) — 기본값 `XLEN/8` (4바이트)
- `TAG_WIDTH` : 요청 태그 폭 (기본값 16)
- `OUT_BUF` : 응답 출력 버퍼 크기 (기본값 0)

---

## 주요 포트

- `clk`, `reset` : 전역 클럭 및 리셋
- `lmem_perf` (output, `PERF_ENABLE` 시) : 성능 계측 구조체 (reads, writes, bank_stalls, crsp_stalls)
- `mem_bus_if[NUM_REQS]` (slave) : 코어로부터의 메모리 요청/응답 인터페이스 배열

---

## 내부 구조 및 로컬 파라미터

- `NUM_WORDS` : 전체 워드 수 = SIZE / WORD_SIZE
- `WORDS_PER_BANK` : 뱅크당 워드 수 = NUM_WORDS / NUM_BANKS
- `BANK_ADDR_WIDTH` : 뱅크 내 주소 폭 = log2(WORDS_PER_BANK)
- `BANK_SEL_BITS` : 뱅크 선택 비트 수 = log2(NUM_BANKS)
- `BANK_SEL_WIDTH` : 뱅크 선택 신호 폭 (패딩 포함)
- `REQ_DATAW`, `RSP_DATAW` : 요청/응답 데이터 폭 (crossbar용)

**Static Assert**: `ADDR_WIDTH == BANK_ADDR_WIDTH + log2(NUM_BANKS)` 확인

---

## 핵심 블록 및 동작 흐름

### 1. 뱅크 선택 (Bank Selection)
- **뱅크 인덱스 계산**: `req_bank_idx[i] = addr[0 +: BANK_SEL_BITS]`
  - 주소의 하위 비트(BANK_SEL_BITS)를 뱅크 인덱스로 사용
  - 연속 주소가 서로 다른 뱅크로 분산되어 병렬 접근 가능
- **뱅크 주소 계산**: `req_bank_addr[i] = addr[BANK_SEL_BITS +: BANK_ADDR_WIDTH]`
  - 뱅크 선택 비트 이후의 상위 비트를 뱅크 내 주소로 사용

### 2. 요청 크로스바 (Request Crossbar)
- **`VX_stream_xbar`** (요청 분배):
  - `NUM_REQS` 입력을 `NUM_BANKS` 출력으로 분배
  - `sel_in = req_bank_idx`: 각 요청이 어느 뱅크로 갈지 결정
  - Priority arbiter ("P") 사용 — 우선순위 기반 충돌 해결
  - 출력 버퍼 크기 3 — BRAM 주소 지연 보상
  - **뱅크 충돌(collision)**: 여러 요청이 같은 뱅크를 동시 접근 시 발생, `perf_collisions` 카운터로 집계

### 3. 뱅크별 메모리 접근 (Bank Access)
- **`VX_sp_ram`** (Single-Port RAM):
  - 뱅크당 하나의 SRAM 인스턴스
  - 크기: `WORDS_PER_BANK` 워드
  - 쓰기 인에이블 단위: `WORD_SIZE` (바이트별 쓰기 가능)
  - 출력 레지스터: `OUT_REG=1` (읽기 레이턴시 1사이클)
  - 읽기-쓰기 모드: "R" (read-during-write 시 이전 값 반환)

- **Read-After-Write 스톨 (보수적 설계)**:
  - `last_wr_valid`: 이전 사이클에 쓰기가 발생했는지 플래그
  - `last_wr_addr`: 이전 사이클 쓰기 주소
  - `is_rdw_hazard = last_wr_valid && ~per_bank_req_rw[i] && (per_bank_req_addr[i] == last_wr_addr)`
  - 같은 주소에 대한 Write 직후 Read 시 1사이클 스톨
  
  **왜 스톨이 필요한가?**
  
  **이론상**: BRAM의 `RDW_MODE="R"` (read-first)는 **같은 사이클**에만 영향:
  ```systemverilog
  always @(posedge clk) begin
      if (write) ram[addr] <= wdata;  // Write 먼저
      if (read) rdata_r <= ram[addr];  // Read 나중
  end
  ```
  - Cycle 0: Write(A) → ram[A] 업데이트
  - Cycle 1: Read(A) → ram[A] 읽음 (새 값 반환, 정상!)
  
  **실제**: 보수적(conservative) 설계 이유
  1. **FPGA 벤더별 차이**: Xilinx, Intel/Altera BRAM의 미묘한 타이밍 차이
  2. **ASIC 합성 불확실성**: 합성 툴이 BRAM을 어떻게 구현할지 불확실
  3. **안전 마진**: 1사이클 스톨로 모든 경우 안전 보장
  
  **VX_pipe_buffer 역할**:
  - BRAM 데이터: 1사이클 레이턴시 (OUT_REG=1)
  - TAG/IDX: 동일한 1사이클 레이턴시로 매칭 (pipe_buffer)
  - Write는 `bank_rsp_valid=0` → pipe_buffer 통과 안 함
  - Read는 `bank_rsp_valid=1` → pipe_buffer에 TAG/IDX 저장 및 1사이클 지연
  
  **성능 vs 안전성 트레이드오프**:
  - 현재: 보수적 설계 (1사이클 스톨, 100% 안전)
  - 최적화 가능: 벤더별 BRAM 특성 확인 후 스톨 제거 가능
  - 실제 영향: 같은 주소 연속 Write→Read 패턴이 얼마나 빈번한지에 따라 결정

- **쓰기 응답 드롭**:
  - `bank_rsp_valid = per_bank_req_valid && ~per_bank_req_rw && ~is_rdw_hazard`
  - 쓰기 요청은 응답을 생성하지 않음 (fire-and-forget)
  - 읽기 요청만 응답 경로로 전달

- **BRAM 출력 버퍼링**:
  - `VX_pipe_buffer` 사용하여 태그와 인덱스 파이프라인 레지스터 추가
  - BRAM 읽기 레이턴시(1사이클)를 보상

### 4. 응답 크로스바 (Response Crossbar)
- **`VX_stream_xbar`** (응답 병합):
  - `NUM_BANKS` 입력을 `NUM_REQS` 출력으로 라우팅
  - `sel_in = per_bank_rsp_idx`: 응답이 어느 요청으로 갈지 결정 (요청 시 저장된 인덱스)
  - Priority arbiter ("P") 사용
  - 출력 버퍼: `OUT_BUF` 파라미터 (기본값 0)

### 5. 성능 계측 (PERF_ENABLE)
- **per-cycle 집계**:
  - `perf_reads_per_cycle`: 사이클당 읽기 요청 수
  - `perf_writes_per_cycle`: 사이클당 쓰기 요청 수
  - `perf_crsp_stall_per_cycle`: 응답 ready 스톨 수 (백프레셔)
- **누적 카운터**:
  - `perf_reads`: 전체 읽기 횟수
  - `perf_writes`: 전체 쓰기 횟수
  - `perf_bank_stalls`: 뱅크 충돌로 인한 스톨 (crossbar collision)
  - `perf_crsp_stalls`: 응답 경로 스톨

### 6. 디버그 트레이스 (DBG_TRACE_MEM)
- **코어 레벨 트레이스**:
  - `mem_bus_if[i]` 요청/응답 트레이스 (주소, 데이터, 태그, UUID)
  - 읽기/쓰기 구분하여 출력
- **뱅크 레벨 트레이스**:
  - 뱅크별 요청/응답 트레이스 (뱅크 내부 주소, 데이터, 태그)
  - 뱅크 충돌 및 스톨 디버깅에 유용

---

## 읽기 포인트 (권장 라인/섹션)

- **뱅크 선택 (line 59~76)**: 주소를 뱅크 인덱스와 뱅크 주소로 분할하는 로직
- **요청 crossbar (line 95~138)**: `VX_stream_xbar`를 통한 요청 분배 및 충돌 감지
- **SRAM 인스턴스화 (line 152~183)**: `VX_sp_ram` 파라미터 설정 및 RDW 해저드 감지
- **쓰기 응답 드롭 로직 (line 196~198)**: 쓰기는 응답 없음, 읽기만 응답 생성
- **응답 crossbar (line 220~245)**: 뱅크 응답을 원래 요청자로 라우팅
- **성능 계측 (line 247~285)**: reads/writes/stalls 집계 방식
- **디버그 트레이스 (line 289~351)**: 코어/뱅크 레벨 상세 출력

---

## 디버그/검증 체크리스트

1. **뱅크 충돌 빈도**: `perf_bank_stalls`가 높으면 뱅크 수 증가 또는 주소 패턴 최적화 필요
2. **RAW 스톨 빈도**: 연속된 쓰기-읽기(같은 주소) 시 1사이클 스톨 — 빈번하면 성능 저하
3. **태그 매칭**: 요청과 응답의 태그가 정확히 매칭되는지 확인 (특히 여러 요청이 뱅크 충돌 시)
4. **뱅크 분산**: 연속 주소 접근 시 서로 다른 뱅크로 분산되는지 확인 (하위 비트 사용)
5. **쓰기 응답 없음**: 쓰기 요청은 `rsp_valid`를 생성하지 않아야 함 (fire-and-forget)

---

## 학습/분석 팁

- **뱅크 분산의 장점**: 
  - SIMD 워프가 연속 주소를 동시 접근 시 각 레인이 다른 뱅크에 접근하여 병렬 처리 가능
  - 예: 4레인, 4뱅크 → 연속 4워드를 한 사이클에 접근 가능 (충돌 없음)

- **SRAM 설정**:
  - `OUT_REG=1`: 읽기 레이턴시 1사이클 추가, 하지만 클럭 주파수 향상
  - `RDW_MODE="R"`: read-during-write 시 이전 값 반환 (새 값 아님) — 해저드 감지 필수

- **Crossbar 동작**:
  - Priority arbiter는 낮은 인덱스 요청에 우선권 부여
  - 충돌 시 우선순위 낮은 요청은 다음 사이클로 지연

- **Local memory 크기 계산**:
  - 기본 128KB = 32K words (4바이트 워드 기준)
  - 4뱅크 → 뱅크당 8K words
  - 주소 매핑: addr[1:0] = 뱅크 선택, addr[14:2] = 뱅크 내 주소

---

## 질문 리스트

1. 뱅크 충돌 시 우선순위는 어떻게 결정되는가? (Priority arbiter 내부 구현 확인)
2. **RAW 스톨 최적화 가능한가?** → 특정 FPGA 타겟으로 고정 시 BRAM 동작 보장되면 스톨 제거 가능
3. 쓰기 응답을 드롭하는 이유는? (fire-and-forget vs. write acknowledgement)
4. Local memory 크기가 캐시 계층과 어떤 관계인가? (L1 vs. shared memory)
5. 뱅크 수를 늘리면 면적과 성능 트레이드오프는?
6. **VX_pipe_buffer의 DEPTH는?** → 기본값 1 (BRAM OUT_REG=1과 매칭)

---

## 관련 파일

- `VX_local_mem_top.sv`: Local memory의 인터페이스 래퍼 (신호 매핑)
- `VX_lmem_switch.sv`: Local/global memory 분기 스위치
- `VX_stream_xbar.sv`: Crossbar 구현 (요청/응답 분배)
- `VX_sp_ram.sv`: Single-port SRAM 구현

---

생성: `docs/rtl/mem/VX_local_mem.md` (한글, local memory 상세 노트)
