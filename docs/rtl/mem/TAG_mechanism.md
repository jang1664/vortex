# BUS Interface TAG 메커니즘 — 상세 분석

파일 위치: `hw/rtl/mem/VX_mem_bus_if.sv`, `hw/rtl/mem/VX_lsu_mem_if.sv`

목적(한 문장)
- TAG는 메모리 요청과 응답을 매칭하기 위한 식별자로, UUID(디버깅용)와 value(라우팅 정보)를 포함하여 비순차(out-of-order) 메모리 처리를 가능하게 합니다.

---

## 1. TAG 구조 개요

### 1.1 기본 TAG 구조체 (`tag_t`)

```systemverilog
// VX_mem_bus_if.sv
typedef struct packed {
    logic [`UP(UUID_WIDTH)-1:0]           uuid;   // 상위 비트
    logic [TAG_WIDTH-`UP(UUID_WIDTH)-1:0] value;  // 하위 비트
} tag_t;
```

- **TAG_WIDTH**: 전체 태그 폭 (파라미터로 지정)
- **UUID**: 고유 식별자(Unique ID) — 디버깅 및 추적용 (상위 비트)
- **value**: 실제 라우팅 정보 (하위 비트) — 요청 소스, 중재 선택, 워드 선택 등 포함

### 1.2 UUID_WIDTH 설정

```systemverilog
// VX_gpu_pkg.sv
`ifdef UUID_ENABLE
    localparam UUID_WIDTH = 44;  // 디버깅 활성화 시
`else
    localparam UUID_WIDTH = 1;   // 최소 폭 (기능만 유지)
`endif
```

- **UUID_ENABLE 활성화**: 44비트 UUID 사용 → 명령어 추적, 디버깅에 유용
- **UUID_ENABLE 비활성화**: 1비트만 사용 → 면적 절약, 프로덕션 빌드

---

## 2. TAG의 주요 용도

### 2.1 요청-응답 매칭 (Request-Response Matching)

**문제**: 메모리 시스템은 비순차(out-of-order) 처리를 지원 — 요청 순서와 응답 순서가 다를 수 있음

**해결**: TAG를 사용하여 각 요청에 고유 식별자 부여 → 응답 시 TAG를 확인하여 원래 요청자에게 전달

**흐름**:
```
1. Core → Cache 요청: req_data.tag = {uuid, core_id, req_idx, ...}
2. Cache 처리 (hit/miss, 임의 레이턴시)
3. Cache → Core 응답: rsp_data.tag = {uuid, core_id, req_idx, ...}
4. Core는 tag를 확인하여 어떤 명령어의 응답인지 식별
```

### 2.2 라우팅 정보 인코딩 (Routing Information)

TAG의 `value` 필드에는 여러 정보가 계층적으로 인코딩됨:

**예시: LSU → Cache 경로**
```systemverilog
TAG_WIDTH = UUID_WIDTH + 
            log2(NUM_LSU_BLOCKS) +  // LSU 블록 선택
            log2(NUM_LANES) +        // 레인 선택
            log2(MSHR_SIZE) +        // MSHR 엔트리 선택
            ...
```

각 중재 단계에서 필요한 정보를 TAG에 삽입/추출:
- **VX_bits_insert**: 중재 선택 정보를 TAG의 특정 위치에 삽입
- **VX_bits_remove**: 응답 시 TAG에서 선택 정보 추출하여 원래 소스로 라우팅

### 2.3 디버깅 및 추적 (Debugging & Tracing)

UUID 부분을 사용하여 명령어 흐름 추적:

```systemverilog
// DBG_TRACE_MEM 활성화 시
`TRACE(2, ("%t: MEM Rd Req[%0d]: addr=0x%0h, tag=0x%0h (#%0d)\n", 
    $time, i, addr, tag.value, tag.uuid))
```

- 각 명령어에 고유 UUID 할당 (VX_uuid_gen.sv)
- 명령어가 파이프라인을 통과하며 UUID 유지
- 로그 파일에서 특정 명령어의 전체 경로 추적 가능

---

## 3. TAG 조작 메커니즘

### 3.1 TAG 비트 삽입 (`VX_bits_insert`)

**목적**: 중재기(arbiter)를 통과할 때 선택 정보를 TAG에 삽입

**모듈**: `hw/rtl/libs/VX_bits_insert.sv`

```systemverilog
VX_bits_insert #(
    .N   (TAG_WIDTH),           // 원래 TAG 폭
    .S   (LOG_NUM_REQS),        // 삽입할 비트 수 (선택 정보)
    .POS (TAG_SEL_IDX)          // 삽입 위치
) bits_insert (
    .data_in  (req_tag_in),     // 입력 TAG
    .ins_in   (req_sel),        // 선택 정보 (어느 입력에서 왔는지)
    .data_out (req_tag_out)     // 출력 TAG (폭: TAG_WIDTH + S)
);
```

**동작**:
```
POS = 10, S = 3 인 경우:
data_in  = [15:0] bits
ins_in   = [2:0] bits
data_out = [18:0] bits = {data_in[15:10], ins_in[2:0], data_in[9:0]}
```

**사용 예시**: `VX_lsu_mem_arb.sv`
```systemverilog
// NUM_INPUTS > NUM_OUTPUTS 경우
// 요청 중재 시 어느 입력에서 왔는지 정보를 TAG에 삽입
if (NUM_INPUTS > NUM_OUTPUTS) begin
    VX_bits_insert #(
        .N   (TAG_WIDTH),
        .S   (LOG_NUM_REQS),
        .POS (TAG_SEL_IDX)
    ) bits_insert (
        .data_in  (req_tag_out),
        .ins_in   (req_sel_out[i]),  // 중재 선택 비트
        .data_out (bus_out_if[i].req_data.tag)
    );
end
```

### 3.2 TAG 비트 추출 (`VX_bits_remove`)

**목적**: 응답을 라우팅할 때 TAG에서 선택 정보 추출

**모듈**: `hw/rtl/libs/VX_bits_remove.sv`

```systemverilog
VX_bits_remove #(
    .N   (TAG_WIDTH + S),       // 입력 TAG 폭 (삽입 후)
    .S   (LOG_NUM_REQS),        // 추출할 비트 수
    .POS (TAG_SEL_IDX)          // 추출 위치
) bits_remove (
    .data_in  (rsp_tag_in),     // 입력 TAG
    .sel_out  (rsp_sel),        // 추출된 선택 정보
    .data_out (rsp_tag_out)     // 출력 TAG (폭: TAG_WIDTH)
);
```

**동작**:
```
data_in  = [18:0] bits = {[18:13], [12:10], [9:0]}
POS = 10, S = 3 인 경우:
sel_out  = data_in[12:10]           // 선택 정보 추출
data_out = {data_in[18:13], data_in[9:0]}  // [15:0] bits (원래 폭)
```

**사용 예시**: `VX_lsu_mem_arb.sv`
```systemverilog
// 응답 스위칭 시 TAG에서 원래 입력 인덱스 추출
if (NUM_INPUTS > NUM_OUTPUTS) begin
    wire [LOG_NUM_REQS-1:0] rsp_sel_in;
    VX_bits_remove #(
        .N   (TAG_WIDTH + LOG_NUM_REQS),
        .S   (LOG_NUM_REQS),
        .POS (TAG_SEL_IDX)
    ) bits_remove (
        .data_in  (bus_out_if[i].rsp_data.tag),
        .sel_out  (rsp_sel_in[i]),     // 어느 입력으로 보낼지
        .data_out (rsp_tag_out)
    );
    // VX_stream_switch를 통해 rsp_sel_in 기반 라우팅
end
```

### 3.3 TAG_SEL_IDX 파라미터

**역할**: TAG 내에서 선택 정보를 삽입/추출할 위치 지정

**이유**: 여러 중재 계층이 있을 때 각 계층이 서로 다른 위치에 정보 저장
- 계층 1: POS = 0 (하위 비트)
- 계층 2: POS = log2(layer1_reqs) (다음 상위 비트)
- 계층 3: POS = log2(layer1_reqs) + log2(layer2_reqs) ...

**예시**: `VX_cache_wrap.sv`
```systemverilog
parameter TAG_SEL_IDX = 0;  // 기본 위치 (하위 비트)
```

---

## 4. TAG 폭 계산 공식

### 4.1 캐시 메모리 TAG 폭

```verilog
// VX_define.vh
`define CACHE_MEM_TAG_WIDTH(mshr_size, num_banks, mem_ports, uuid_width)
    (uuid_width + 
     `CLOG2(mshr_size) +                    // MSHR 엔트리 선택
     `CLOG2(`CDIV(num_banks, mem_ports)))   // 뱅크→포트 매핑
```

**구성 요소**:
- **UUID**: 디버깅용 고유 ID
- **MSHR 인덱스**: Miss Status Holding Register 엔트리 번호 (캐시 미스 추적)
- **뱅크/포트 매핑**: 여러 뱅크가 적은 수의 메모리 포트를 공유할 때 라우팅 정보

### 4.2 캐시 바이패스 TAG 폭

```verilog
`define CACHE_BYPASS_TAG_WIDTH(num_reqs, mem_ports, line_size, word_size, tag_width)
    (`CLOG2(`CDIV(num_reqs, mem_ports)) +  // 요청→포트 중재
     `CLOG2(line_size / word_size) +       // 워드 선택 (LINE↔WORD 변환)
     tag_width)                             // 원래 코어 TAG
```

**구성 요소**:
- **요청 중재**: 여러 요청이 적은 포트를 공유할 때 선택 정보
- **워드 선택**: 캐시 라인 내 워드 위치 (읽기 응답 시 올바른 워드 추출)
- **원래 TAG**: 코어에서 온 원래 TAG 정보 유지

### 4.3 Non-Cacheable TAG 폭

```verilog
`define CACHE_NC_MEM_TAG_WIDTH(mshr_size, num_banks, num_reqs, mem_ports, 
                                line_size, word_size, tag_width, uuid_width)
    (`MAX(`CACHE_MEM_TAG_WIDTH(mshr_size, num_banks, mem_ports, uuid_width),
          `CACHE_BYPASS_TAG_WIDTH(num_reqs, mem_ports, line_size, word_size, tag_width)) 
     + 1)  // +1 for cache/bypass 경로 구분 비트
```

**구성 요소**:
- 캐시 경로와 바이패스 경로 중 더 큰 TAG 폭 선택
- 추가 1비트: 어느 경로(cache/bypass)를 사용했는지 표시

---

## 5. 실전 TAG 사용 예시

### 5.1 LSU → D-Cache 경로

```
1. LSU 요청 생성:
   TAG = {uuid, lsu_block_id, lane_id, ...}
   TAG_WIDTH = UUID_WIDTH + log2(NUM_LSU_BLOCKS) + log2(NUM_LANES) + ...

2. LSU 중재 (VX_lsu_mem_arb):
   - NUM_INPUTS=4, NUM_OUTPUTS=2
   - 선택 비트(2비트) 삽입: TAG_WIDTH → TAG_WIDTH + 2
   - TAG_SEL_IDX = (원래 TAG의 끝)

3. Cache 처리:
   - MSHR 할당 시 MSHR 인덱스를 TAG에 포함
   - TAG_WIDTH → TAG_WIDTH + log2(MSHR_SIZE)

4. Cache 응답:
   - MSHR 인덱스로 원래 요청 복원
   - 중재 선택 비트 추출하여 원래 LSU 블록으로 라우팅
   - 레인 ID로 올바른 레인에 응답 전달

5. LSU 응답 병합:
   - UUID로 원래 명령어 식별
   - Writeback 단계로 응답 전달
```

### 5.2 L2 Cache 중재 예시

```systemverilog
// VX_cluster.sv - L2 cache arbiter
VX_mem_arb #(
    .NUM_INPUTS  (`NUM_SOCKETS),
    .NUM_OUTPUTS (`L2_MEM_PORTS),
    .TAG_WIDTH   (L2_TAG_WIDTH),
    .TAG_SEL_IDX (0),  // 하위 비트부터 삽입
    ...
) l2_mem_arb (
    .clk        (clk),
    .reset      (reset),
    .bus_in_if  (per_socket_mem_bus_if),   // 각 소켓에서 오는 요청
    .bus_out_if (l2cache_mem_bus_if)       // L2 cache로 가는 요청
);

// TAG 삽입:
// 원래: {uuid, socket_dcache_info, ...}
// 삽입 후: {uuid, socket_dcache_info, ..., socket_id[log2(NUM_SOCKETS)-1:0]}
// socket_id: 어느 소켓에서 왔는지 (응답 라우팅용)
```

### 5.3 Local Memory TAG 사용

```systemverilog
// VX_local_mem.sv
// TAG는 crossbar를 통과하며 요청자 인덱스 유지
for (genvar i = 0; i < NUM_BANKS; ++i) begin
    // TAG에서 UUID와 value 분리 (디버깅용)
    assign per_bank_req_tag_value[i] = per_bank_req_tag[i][TAG_WIDTH-UUID_WIDTH-1:0];
    if (UUID_WIDTH != 0) begin
        assign per_bank_req_uuid[i] = per_bank_req_tag[i][TAG_WIDTH-1 -: UUID_WIDTH];
    end
end

// 응답 시 TAG를 그대로 반환하여 원래 요청자에게 전달
assign mem_bus_if[i].rsp_data.tag = rsp_data_out[i].tag;
```

---

## 6. TAG 디버깅 팁

### 6.1 트레이스 활성화

```systemverilog
`ifdef DBG_TRACE_MEM
    always @(posedge clk) begin
        if (mem_bus_if[i].req_valid && mem_bus_if[i].req_ready) begin
            $display("%t: Req[%0d]: addr=0x%0h, tag_value=0x%0h, uuid=#%0d",
                $time, i, mem_bus_if[i].req_data.addr,
                mem_bus_if[i].req_data.tag.value,
                mem_bus_if[i].req_data.tag.uuid);
        end
    end
`endif
```

### 6.2 TAG 불일치 디버깅

**증상**: 응답이 잘못된 요청자에게 전달됨

**체크리스트**:
1. TAG_WIDTH가 모든 계층에서 일치하는가?
2. TAG_SEL_IDX가 여러 중재 계층에서 충돌하지 않는가?
3. VX_bits_insert와 VX_bits_remove의 POS 파라미터가 일치하는가?
4. 중재 선택 비트 수(S)가 실제 입력/출력 수와 맞는가?

### 6.3 UUID 추적

```bash
# 시뮬레이션 로그에서 특정 UUID 추적
grep "#12345" simulation.log

# UUID를 통해 명령어의 전체 경로 확인:
# - Fetch → Decode → Issue → Execute → LSU → Cache → Writeback
```

---

## 7. TAG 설계 원칙

### 7.1 계층적 인코딩
- 각 계층은 자신의 정보를 TAG의 특정 위치에 추가
- 상위 계층은 하위 계층의 TAG를 보존하고 확장
- 응답 시 역순으로 정보 추출 및 TAG 축소

### 7.2 UUID 우선 배치
- UUID는 항상 TAG의 최상위 비트에 위치
- 하위 계층의 정보는 UUID 아래 비트에 추가
- UUID는 전체 경로에서 변경되지 않음 (디버깅 일관성)

### 7.3 면적-기능 트레이드오프
- 프로덕션 빌드: UUID_WIDTH = 1 (최소)
- 디버깅 빌드: UUID_WIDTH = 44 (상세 추적)
- TAG_WIDTH가 커질수록 레지스터/SRAM 면적 증가 → 신중한 설계 필요

### 7.4 TAG 폭 최적화
- 불필요한 정보 인코딩 회피
- 중재 계층 최소화 (TAG 폭 증가 억제)
- 가능한 경우 암묵적 정보 사용 (예: FIFO 순서)

---

## 8. 관련 파일

- **인터페이스 정의**:
  - `VX_mem_bus_if.sv`: 메모리 버스 인터페이스 및 TAG 구조체
  - `VX_lsu_mem_if.sv`: LSU 메모리 인터페이스 및 TAG

- **TAG 조작 라이브러리**:
  - `VX_bits_insert.sv`: TAG에 선택 비트 삽입
  - `VX_bits_remove.sv`: TAG에서 선택 비트 추출

- **TAG 사용 예시**:
  - `VX_lsu_mem_arb.sv`: LSU 중재 시 TAG 삽입/추출
  - `VX_mem_arb.sv`: 일반 메모리 중재 시 TAG 처리
  - `VX_cache_bypass.sv`: 캐시 바이패스 경로의 TAG 관리
  - `VX_cache_bank.sv`: 캐시 뱅크의 MSHR TAG 사용

- **TAG 폭 계산**:
  - `VX_define.vh`: TAG_WIDTH 매크로 정의
  - `VX_gpu_pkg.sv`: UUID_WIDTH 및 각 서브시스템 TAG_WIDTH 정의

---

생성: `docs/rtl/mem/TAG_mechanism.md` (한글, BUS interface TAG 메커니즘 상세 분석)
