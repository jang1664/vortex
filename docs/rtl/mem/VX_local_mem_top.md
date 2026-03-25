# `mem/VX_local_mem_top.sv` — 상세 노트

파일: `hw/rtl/mem/VX_local_mem_top.sv`

목적(한 문장)
- Local memory의 top-level 래퍼로, 외부 신호(배열)를 `VX_mem_bus_if` 인터페이스로 변환하여 `VX_local_mem` 인스턴스에 연결합니다.

---

## 주요 파라미터

- `INSTANCE_ID` : 인스턴스 이름 (디버그 트레이스용)
- `SIZE` : 전체 local memory 크기(바이트) — 기본값 128KB
- `NUM_REQS` : 사이클당 워드 요청 수 (기본값 4)
- `NUM_BANKS` : 뱅크 수 (기본값 4)
- `WORD_SIZE` : 워드 크기(바이트) — 기본값 `XLEN/8`
- `TAG_WIDTH` : 요청 태그 폭 (기본값 16)
- `ADDR_WIDTH` : 주소 폭 (자동 계산: `BANK_ADDR_WIDTH + log2(NUM_BANKS)`)

---

## 주요 포트

### 입력 (요청 신호)
- `mem_req_valid[NUM_REQS]` : 요청 valid 플래그 배열
- `mem_req_rw[NUM_REQS]` : 읽기(0)/쓰기(1) 플래그 배열
- `mem_req_byteen[NUM_REQS][WORD_SIZE]` : 바이트 인에이블 배열
- `mem_req_addr[NUM_REQS][ADDR_WIDTH]` : 주소 배열
- `mem_req_flags[NUM_REQS][MEM_FLAGS_WIDTH]` : 메모리 플래그 배열
- `mem_req_data[NUM_REQS][WORD_SIZE*8]` : 쓰기 데이터 배열
- `mem_req_tag[NUM_REQS][TAG_WIDTH]` : 요청 태그 배열

### 출력 (요청 응답)
- `mem_req_ready[NUM_REQS]` : 요청 ready 신호 배열

### 출력 (응답 신호)
- `mem_rsp_valid[NUM_REQS]` : 응답 valid 플래그 배열
- `mem_rsp_data[NUM_REQS][WORD_SIZE*8]` : 읽기 데이터 배열
- `mem_rsp_tag[NUM_REQS][TAG_WIDTH]` : 응답 태그 배열

### 입력 (응답 핸드셰이크)
- `mem_rsp_ready[NUM_REQS]` : 응답 ready 신호 배열

---

## 핵심 동작

### 1. 인터페이스 인스턴스화
```systemverilog
VX_mem_bus_if #(
    .DATA_SIZE (WORD_SIZE),
    .TAG_WIDTH (TAG_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH)
) mem_bus_if[NUM_REQS]();
```
- `NUM_REQS` 개의 `VX_mem_bus_if` 인터페이스 배열 생성
- 각 인터페이스는 하나의 요청 채널을 나타냄

### 2. 요청 신호 매핑
```systemverilog
for (genvar i = 0; i < NUM_REQS; ++i) begin
    assign mem_bus_if[i].req_valid = mem_req_valid[i];
    assign mem_bus_if[i].req_data.rw = mem_req_rw[i];
    assign mem_bus_if[i].req_data.byteen = mem_req_byteen[i];
    assign mem_bus_if[i].req_data.addr = mem_req_addr[i];
    assign mem_bus_if[i].req_data.flags = mem_req_flags[i];
    assign mem_bus_if[i].req_data.data = mem_req_data[i];
    assign mem_bus_if[i].req_data.tag = mem_req_tag[i];
    assign mem_req_ready[i] = mem_bus_if[i].req_ready;
end
```
- 포트 신호를 인터페이스 구조체에 할당
- `req_ready`는 인터페이스에서 외부 포트로 출력

### 3. 응답 신호 매핑
```systemverilog
for (genvar i = 0; i < NUM_REQS; ++i) begin
    assign mem_rsp_valid[i] = mem_bus_if[i].rsp_valid;
    assign mem_rsp_data[i] = mem_bus_if[i].rsp_data.data;
    assign mem_rsp_tag[i] = mem_bus_if[i].rsp_data.tag;
    assign mem_bus_if[i].rsp_ready = mem_rsp_ready[i];
end
```
- 인터페이스 응답을 외부 포트로 추출
- `rsp_ready`는 외부에서 인터페이스로 입력

### 4. Local Memory 인스턴스화
```systemverilog
VX_local_mem #(
    .INSTANCE_ID(INSTANCE_ID),
    .SIZE       (SIZE),
    .NUM_REQS   (NUM_REQS),
    .NUM_BANKS  (NUM_BANKS),
    .WORD_SIZE  (WORD_SIZE),
    .ADDR_WIDTH (ADDR_WIDTH),
    .TAG_WIDTH  (TAG_WIDTH),
    .OUT_BUF    (3)
) local_mem (
    .clk        (clk),
    .reset      (reset),
    .mem_bus_if (mem_bus_if)
);
```
- `VX_local_mem` 인스턴스에 인터페이스 배열 전달
- `OUT_BUF = 3`: 응답 출력 버퍼 크기 (성능 최적화)

---

## 역할 및 용도

- **인터페이스 래퍼**: 
  - 외부 모듈이 SystemVerilog 인터페이스를 지원하지 않는 경우 신호 배열로 변환
  - 또는 상위 계층이 신호 기반 연결을 선호하는 경우 사용

- **재사용성**: 
  - `VX_local_mem`은 인터페이스 기반으로 설계되어 모듈화
  - `VX_local_mem_top`은 신호 기반 래퍼로 다양한 환경에 통합 가능

- **파라미터 계산**: 
  - `NUM_WORDS`, `WORDS_PER_BANK`, `BANK_ADDR_WIDTH` 등을 자동 계산
  - 외부에서는 `SIZE`, `NUM_BANKS` 등만 지정하면 됨

---

## 읽기 포인트 (권장 라인/섹션)

- **파라미터 선언 (line 17~43)**: 자동 계산되는 파라미터 확인
- **포트 선언 (line 44~63)**: 신호 배열 형태의 입출력
- **요청/응답 매핑 (line 70~86)**: 신호와 인터페이스 간 변환 로직
- **인스턴스화 (line 88~100)**: `VX_local_mem` 연결 및 파라미터 전달

---

## 디버그/검증 체크리스트

1. 신호 배열과 인터페이스 구조체 간의 매핑이 정확한지 확인 (비트 폭 일치)
2. `OUT_BUF = 3` 설정이 성능에 미치는 영향 분석 (레이턴시 vs. 처리량)
3. 상위 모듈에서 이 래퍼를 사용하는지, 아니면 직접 `VX_local_mem`을 사용하는지 확인

---

## 학습/분석 팁

- 이 파일은 본질적으로 "접착제(glue)" 역할을 하며, 실제 로직은 `VX_local_mem.sv`에 있음
- SystemVerilog 인터페이스의 장점(모듈화, 타입 안전성)과 신호 기반 연결의 필요성을 보여주는 예시
- Verilog-2001 환경이나 구형 툴과의 호환성을 위해 이러한 래퍼가 필요할 수 있음

---

## 관련 파일

- `VX_local_mem.sv`: 실제 local memory 구현
- `VX_mem_bus_if.sv`: 메모리 버스 인터페이스 정의
- `VX_lmem_switch.sv`: Local memory를 사용하는 상위 모듈

---

생성: `docs/rtl/mem/VX_local_mem_top.md` (한글, local memory top 래퍼 노트)
