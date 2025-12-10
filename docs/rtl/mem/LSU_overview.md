# `mem/` — LSU (Load-Store Unit) 개요

파일 위치: `hw/rtl/mem/`

목적(한 문장)
- LSU(Load-Store Unit)는 코어의 메모리 load/store 명령을 처리하는 하드웨어 유닛으로, 다중 레인(lane) 요청을 받아 global memory와 local memory로 라우팅하고, 응답을 병합하여 코어로 반환합니다.

---

## LSU 관련 주요 파일

### 1. `VX_lsu_mem_if.sv` — LSU 메모리 인터페이스
- **인터페이스 정의**: LSU와 메모리 서브시스템 간의 통신 프로토콜
- **파라미터**:
  - `NUM_LANES`: 동시 처리 레인 수 (SIMD 폭)
  - `DATA_SIZE`: 데이터 크기(바이트) — 워드 크기
  - `TAG_WIDTH`: 요청 태그 폭 (UUID 포함)
  - `FLAGS_WIDTH`: 메모리 플래그 폭 (non-cacheable, local mem 등)
  - `ADDR_WIDTH`: 주소 폭 (`MEM_ADDR_WIDTH - log2(DATA_SIZE)`)

- **요청 구조체 (`req_data_t`)**:
  ```systemverilog
  - mask[NUM_LANES-1:0]: 레인 활성화 마스크
  - rw: 읽기(0)/쓰기(1) 플래그
  - addr[NUM_LANES][ADDR_WIDTH]: 레인별 주소
  - data[NUM_LANES][DATA_SIZE*8]: 레인별 쓰기 데이터
  - byteen[NUM_LANES][DATA_SIZE]: 레인별 바이트 인에이블
  - flags[NUM_LANES][FLAGS_WIDTH]: 레인별 메모리 플래그 (MEM_REQ_FLAG_LOCAL 등)
  - tag: 요청 식별 태그 (UUID + value)
  ```

- **응답 구조체 (`rsp_data_t`)**:
  ```systemverilog
  - mask[NUM_LANES-1:0]: 응답 레인 마스크
  - data[NUM_LANES][DATA_SIZE*8]: 레인별 읽기 데이터
  - tag: 응답 태그 (요청과 매칭용)
  ```

- **핸드셰이크**: valid/ready 프로토콜
  - `req_valid`, `req_data`, `req_ready` (master→slave)
  - `rsp_valid`, `rsp_data`, `rsp_ready` (slave→master)

### 2. `VX_lsu_adapter.sv` — LSU-메모리 버스 어댑터
- **역할**: LSU 인터페이스(`VX_lsu_mem_if`)를 표준 메모리 버스(`VX_mem_bus_if`)로 변환
- **동작 흐름**:
  1. **요청 언패킹(unpack)**: 
     - `NUM_LANES` 레인의 병렬 요청을 개별 레인별 요청으로 분리
     - `VX_stream_unpack` 사용 — mask 기반으로 활성 레인만 valid 출력
     - 각 레인에 대해 별도의 `mem_bus_if[i]` 생성
  2. **응답 패킹(pack)**:
     - 각 레인의 응답을 다시 병렬 구조로 병합
     - `VX_stream_pack` 사용 — 여러 레인 응답을 하나의 `lsu_mem_if.rsp`로 조립
     - TAG를 이용해 원래 요청과 매칭

- **파라미터**:
  - `NUM_LANES`: 레인 수
  - `DATA_SIZE`: 워드 크기
  - `TAG_WIDTH`: 태그 폭
  - `TAG_SEL_BITS`: 태그 선택 비트 (arbiter용)
  - `ARBITER`: 응답 병합 중재 방식 ("P"=priority)
  - `REQ_OUT_BUF`, `RSP_OUT_BUF`: 출력 버퍼 크기

- **용도**: 다중 레인 LSU 요청을 단일 레인 캐시/메모리 인터페이스로 직렬화

### 3. `VX_lsu_mem_arb.sv` — LSU 메모리 중재기
- **역할**: 여러 LSU 블록(또는 입력)의 요청을 중재하여 제한된 수의 출력 포트로 전달
- **동작 흐름**:
  1. **요청 중재(arbitration)**:
     - `NUM_INPUTS` 입력에서 `NUM_OUTPUTS` 출력으로 중재
     - `VX_stream_arb` 사용 — ARBITER 파라미터에 따라 라운드로빈("R") 또는 우선순위("P") 방식
     - 중재 선택 정보(`req_sel_out`)를 태그에 삽입 (TAG_SEL_IDX 위치)
  2. **응답 라우팅**:
     - `NUM_INPUTS > NUM_OUTPUTS` 경우: `VX_stream_switch` 사용 — 태그에서 선택 정보 추출하여 원래 입력으로 라우팅
     - `NUM_INPUTS <= NUM_OUTPUTS` 경우: `VX_stream_arb` 사용 — 단순 중재

- **파라미터**:
  - `NUM_INPUTS`, `NUM_OUTPUTS`: 입출력 포트 수
  - `NUM_LANES`: 레인 수
  - `TAG_SEL_IDX`: 태그 내 선택 비트 삽입 위치
  - `ARBITER`: 중재 방식 ("R"=round-robin, "P"=priority)

- **용도**: 여러 LSU 블록이 하나의 캐시/메모리 포트를 공유할 때 사용

### 4. `VX_lmem_switch.sv` — Local/Global 메모리 스위치
- **역할**: LSU 요청을 local memory와 global memory(캐시)로 분기
- **동작 흐름**:
  1. **주소 기반 분기 판정**:
     - `flags[i][MEM_REQ_FLAG_LOCAL]` 플래그 확인
     - `is_addr_local_mask[i]`: 레인별로 local 여부 판단
     - `is_addr_global`: 하나라도 global 요청이 있으면 true
     - `is_addr_local`: 하나라도 local 요청이 있으면 true
  2. **요청 버퍼링 및 라우팅**:
     - global 요청: `mask & ~is_addr_local_mask` 적용하여 `global_out_if`로 전송
     - local 요청: `mask & is_addr_local_mask` 적용하여 `local_out_if`로 전송
     - `VX_elastic_buffer` 사용하여 각 경로 버퍼링
  3. **응답 병합**:
     - `VX_stream_arb` 사용하여 global/local 응답을 하나로 병합
     - 원래 요청 순서는 태그로 유지

- **파라미터**:
  - `GLOBAL_OUT_BUF`, `LOCAL_OUT_BUF`: 각 경로의 출력 버퍼 크기
  - `RSP_OUT_BUF`: 응답 병합 버퍼 크기
  - `ARBITER`: 응답 중재 방식 ("R")

- **용도**: shared local memory와 global memory를 단일 LSU 인터페이스로 통합

---

## LSU 처리 흐름 요약

```
Core Execute Stage
    ↓ (VX_lsu_mem_if, NUM_LANES 병렬 요청)
VX_lsu_adapter (lane unpack/pack)
    ↓ (VX_mem_bus_if[NUM_LANES], 레인별 직렬화)
VX_lmem_switch (local/global 분기)
    ↓ local → VX_local_mem
    ↓ global → VX_cache (D-cache)
응답 병합 및 pack
    ↓ (VX_lsu_mem_if, NUM_LANES 병렬 응답)
Core Writeback Stage
```

---

## 학습 포인트

1. **다중 레인 처리**: 
   - SIMD 방식으로 여러 스레드의 메모리 요청을 병렬 처리
   - mask 기반으로 활성 레인만 선택
   - unpack/pack 메커니즘으로 직렬화↔병렬화 변환

2. **Local vs Global 메모리**:
   - Local memory: 워크그룹 공유 메모리(scratchpad), 낮은 레이턴시
   - Global memory: 캐시 계층을 통한 DRAM 접근, 높은 레이턴시
   - 플래그 기반 자동 라우팅

3. **중재 및 태그 관리**:
   - 여러 LSU 블록의 요청 중재 시 태그에 선택 정보 삽입
   - 응답 시 태그에서 선택 정보 추출하여 원래 요청자로 라우팅
   - UUID를 통한 디버깅 및 추적

4. **버퍼링 전략**:
   - 요청/응답 경로에 elastic buffer 배치하여 스톨 감소
   - OUT_BUF 파라미터로 성능/면적 트레이드오프 조정

---

## 디버그 체크리스트

1. `VX_lsu_mem_if`의 mask와 flags가 올바르게 설정되는지 확인
2. local/global 분기 시 mask가 중복되거나 누락되지 않는지 검증
3. 태그 폭 계산 시 TAG_SEL_IDX 위치가 충돌하지 않는지 확인
4. unpack/pack 시 레인 순서와 태그 매칭이 정확한지 확인
5. 중재기 사용 시 NUM_INPUTS/NUM_OUTPUTS 관계에 따른 응답 라우팅 방식 차이 이해

---

## 관련 파일
- `VX_mem_unit.sv`: LSU를 포함한 메모리 유닛 상위 모듈
- `VX_lsu_unit.sv`, `VX_lsu_slice.sv`: LSU 내부 구현
- `VX_local_mem.sv`, `VX_local_mem_top.sv`: Local memory 구현 (별도 문서 참조)
- `VX_cache.sv`: D-cache 구현 (global memory 경로)

---

생성: `docs/rtl/mem/LSU_overview.md` (한글, LSU 개요 및 주요 파일 분석)
