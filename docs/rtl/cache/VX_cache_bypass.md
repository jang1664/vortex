# `VX_cache_bypass.sv` — Bypass 로직 상세 분석

파일: `hw/rtl/cache/VX_cache_bypass.sv`

## 1. 역할

`VX_cache_bypass`는 **non-cacheable (NC) 주소**에 대한 요청을 캐시를 거치지 않고 직접 메모리로 전달하는 모듈입니다. `CACHE_ENABLE=0`이면 모든 요청을 bypass(passthru)합니다.

주요 기능:
- NC 주소 판별 및 요청 분리 (cacheable vs non-cacheable)
- 워드 → 라인 크기 변환 (코어는 워드, 메모리는 라인 단위)
- 캐시 경로와 NC 경로의 메모리 요청 병합
- 태그에 word select 정보 인코딩/디코딩

## 2. 파라미터

| 파라미터 | 설명 |
|----------|------|
| `NUM_REQS` | 코어 요청 포트 수 |
| `MEM_PORTS` | 메모리 포트 수 |
| `TAG_SEL_IDX` | 태그 내 selector 삽입 위치 |
| `CACHE_ENABLE` | 캐시 경로 활성화 여부 (0이면 완전 passthru) |
| `WORD_SIZE`, `LINE_SIZE` | 워드/라인 크기 |
| `CORE_ADDR_WIDTH`, `CORE_TAG_WIDTH` | 코어 측 주소/태그 폭 |
| `MEM_ADDR_WIDTH`, `MEM_TAG_IN_WIDTH` | 메모리 측 주소/태그 폭 |

## 3. 인터페이스

```
core_bus_in_if  [NUM_REQS] (slave)  — 원본 코어 요청
core_bus_out_if [NUM_REQS] (master) — cacheable 코어 요청 (→ VX_cache)

mem_bus_in_if   [MEM_PORTS] (slave)  — 캐시의 메모리 요청
mem_bus_out_if  [MEM_PORTS] (master) — 최종 메모리 요청 (NC + 캐시 병합)
```

## 4. 내부 구조

```
                    ┌──────────────────────────────┐
 core_bus_in_if ──→ │  core_bus_nc_switch           │
                    │  (NC/cacheable 분리)          │
                    │  sel: MEM_REQ_FLAG_IO          │
                    └───┬───────────────────┬───────┘
                        │ NC 경로           │ cacheable 경로
                        ▼                   ▼
               core_bus_in_nc_if     core_bus_out_if
                        │                   │
                        ▼                   │
               ┌────────────────┐           │
               │ core_bus_nc_arb│           │
               │ (NUM_REQS →   │           │
               │  MEM_PORTS)   │           │
               └───────┬────────┘           │
                       │                    │
                       ▼                    │
              ┌─────────────────┐           │
              │ Word→Line 변환  │           │
              │ (addr, byteen,  │           │
              │  data, tag)    │           │
              └───────┬─────────┘           │
                      │                     │
                      ▼                     ▼
              mem_bus_out_nc_if     mem_bus_in_if (캐시)
                      │                     │
                      ▼                     ▼
              ┌──────────────────────────────┐
              │     mem_bus_out_arb           │
              │     (NC + cache → MEM_PORTS) │
              └──────────────┬───────────────┘
                             ▼
                      mem_bus_out_if
```

## 5. 동작 상세

### 5.1 NC 주소 판별

```systemverilog
for (genvar i = 0; i < NUM_REQS; ++i) begin
    if (CACHE_ENABLE) begin
        // IO 영역이 아니면(=cacheable) cacheable 경로로
        assign core_req_nc_sel[i] = ~core_bus_in_if[i].req_data.flags[MEM_REQ_FLAG_IO];
    end else begin
        // 캐시 비활성: 모든 요청이 NC 경로
        assign core_req_nc_sel[i] = 1'b0;
    end
end
```

`VX_mem_switch`가 `core_req_nc_sel`에 따라 요청을 분리:
- `sel=0` → NC 경로 (`core_bus_nc_switch_if[0:NUM_REQS-1]`)
- `sel=1` → cacheable 경로 (`core_bus_nc_switch_if[NUM_REQS:2*NUM_REQS-1]`)

### 5.2 NC 경로: 워드 → 라인 변환

메모리는 라인 단위로 동작하지만, NC 요청은 워드 단위입니다. 변환이 필요합니다:

```systemverilog
if (WORDS_PER_LINE > 1) begin : g_multi_word_line
    wire [WSEL_BITS-1:0] req_wsel = core_req_nc_arb_addr[WSEL_BITS-1:0];

    // byteen: 해당 워드 위치에만 배치
    core_req_nc_arb_byteen_w = '0;
    core_req_nc_arb_byteen_w[req_wsel] = core_req_nc_arb_byteen;

    // data: 해당 워드 위치에만 배치
    core_req_nc_arb_data_w = '0;
    core_req_nc_arb_data_w[req_wsel] = core_req_nc_arb_data;

    // 주소: 워드 선택 비트 제거 (라인 주소로 변환)
    core_req_nc_arb_addr_w = core_req_nc_arb_addr[WSEL_BITS +: MEM_ADDR_WIDTH];

    // tag에 word select 삽입 (응답 시 올바른 워드 추출용)
    VX_bits_insert #(.N(MEM_TAG_NC1_WIDTH), .S(WSEL_BITS), .POS(TAG_SEL_IDX))
        wsel_insert (.data_in(tag), .ins_in(req_wsel), .data_out(tag_w));
end
```

**응답 시 역변환**:
```systemverilog
// tag에서 word select 추출
VX_bits_remove #(.N(MEM_TAG_NC2_WIDTH), .S(WSEL_BITS), .POS(TAG_SEL_IDX))
    wsel_remove (.data_in(rsp_tag), .sel_out(rsp_wsel), .data_out(core_tag));

// 라인 데이터에서 해당 워드 추출
core_rsp_nc_arb_data_w = mem_rsp_data[rsp_wsel * CORE_DATA_WIDTH +: CORE_DATA_WIDTH];
```

### 5.3 메모리 요청 병합

NC 경로와 캐시 경로의 메모리 요청을 하나의 출력으로 병합:

```systemverilog
// 태그 폭 통일 (더 넓은 쪽에 맞춤)
ASSIGN_VX_MEM_BUS_IF_EX(mem_bus_out_src_if[0], mem_bus_out_nc_if[i],
    MEM_TAG_OUT_WIDTH, MEM_TAG_NC2_WIDTH, UUID_WIDTH);  // NC

if (CACHE_ENABLE):
    ASSIGN_VX_MEM_BUS_IF_EX(mem_bus_out_src_if[1], mem_bus_in_if[i],
        MEM_TAG_OUT_WIDTH, MEM_TAG_IN_WIDTH, UUID_WIDTH);  // cache

// Round-robin 중재
VX_mem_arb #(
    .NUM_INPUTS  ((CACHE_ENABLE ? 2 : 1) * MEM_PORTS),
    .NUM_OUTPUTS (MEM_PORTS),
    .ARBITER     ("R")
) mem_bus_out_arb (...);
```

### 5.4 Direct Passthru 최적화

```systemverilog
localparam DIRECT_PASSTHRU = !CACHE_ENABLE && (CS_WORD_SEL_BITS == 0) && (NUM_REQS == MEM_PORTS);
```

워드 크기 = 라인 크기이고, 포트 수가 같으면 변환 없이 직접 연결 가능합니다. 이 경우 버퍼를 생략합니다.

## 6. 태그 폭 관리

```
MEM_TAG_NC1_WIDTH = UUID_WIDTH + CLOG2(NUM_REQS/MEM_PORTS) + CORE_TAG_ID_WIDTH
                    (UUID)       (arbiter selector)           (core tag)

MEM_TAG_NC2_WIDTH = MEM_TAG_NC1_WIDTH + WSEL_BITS
                    (+ word select bits)

MEM_TAG_OUT_WIDTH = CACHE_ENABLE ? MAX(MEM_TAG_IN_WIDTH, MEM_TAG_NC2_WIDTH)
                                 : MEM_TAG_NC2_WIDTH
```

NC 경로와 캐시 경로의 태그 폭이 다를 수 있으므로, 더 넓은 쪽에 맞추고 `ASSIGN_VX_MEM_BUS_IF_EX`로 폭을 변환합니다.

## 7. 설계 핵심 포인트

1. **IO 영역 분리**: `MEM_REQ_FLAG_IO` 플래그로 NC 주소를 판별합니다. 이는 주소 비교가 아닌 플래그 기반으로, 상위 모듈에서 주소 범위에 따라 플래그를 설정합니다.

2. **Word Select 인코딩**: NC 요청의 word select 정보를 메모리 태그에 인코딩하여, 응답이 돌아왔을 때 올바른 워드를 추출할 수 있습니다. `TAG_SEL_IDX`로 태그 내 삽입 위치를 제어합니다.

3. **Arbiter 선택**: NC 경로에서 `CACHE_ENABLE`이면 priority arbiter("P"), 아니면 round-robin("R"). 캐시 활성 시 NC 요청에 우선순위를 줘서 IO 레이턴시를 줄입니다.

4. **Static Assert**: `IO_BASE_ADDR`가 `MEM_BLOCK_SIZE`에 정렬되어 있는지 검증합니다.
