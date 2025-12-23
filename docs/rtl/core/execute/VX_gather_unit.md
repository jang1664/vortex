# `core/VX_gather_unit.sv` — Gather Unit

## 개요

VX_dispatch_unit의 역연산을 수행하는 유닛.
실행 유닛에서 NUM_LANES 크기로 분할된 결과 패킷을 SIMD_WIDTH 크기로 다시 병합하여 Commit Stage로 전달.

## 아키텍처

```
VX_dispatch_unit (분할)              VX_gather_unit (병합)
        │                                    │
        ▼                                    ▼
SIMD_WIDTH=16 ──→ NUM_LANES=4       NUM_LANES=4 ──→ SIMD_WIDTH=16
                  (4 packets)        (4 packets)

┌─────────────────────────────────────────────────────────────────┐
│                      VX_gather_unit                              │
│                                                                 │
│  result_if[BLOCK_SIZE]                                          │
│       │                                                         │
│       ▼                                                         │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                ISW (Issue Slot) 라우팅                    │  │
│  │                                                          │  │
│  │  result_in[0] ──→ ┌─────────────┐                        │  │
│  │  result_in[1] ──→ │ ISW 기반    │ ──→ result_out[0]      │  │
│  │       ...     ──→ │ 멀티플렉싱  │ ──→ result_out[1]      │  │
│  │                   └─────────────┘ ──→ ...                │  │
│  └──────────────────────────────────────────────────────────┘  │
│                         │                                       │
│                         ▼                                       │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              패킷 → SIMD 변환 (per issue slot)            │  │
│  │                                                          │  │
│  │  lpid 추출 ──→ tmask/data 위치 계산 ──→ SIMD_WIDTH 출력    │  │
│  │                                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                         │                                       │
│                         ▼                                       │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              VX_elastic_buffer (per issue slot)           │  │
│  └──────────────────────────────────────────────────────────┘  │
│                         │                                       │
└─────────────────────────┼───────────────────────────────────────┘
                          ▼
                   commit_if[ISSUE_WIDTH]
```

## 모듈 파라미터

| 파라미터 | 설명 |
|----------|------|
| `BLOCK_SIZE` | 입력 블록 수 (실행 유닛 블록 수) |
| `NUM_LANES` | 레인 수 (패킷 크기) |
| `OUT_BUF` | 출력 버퍼 타입 |

## 핵심 로직

### 1. ISW (Issue Slot Width) 라우팅

입력 블록을 원래 Issue Slot으로 라우팅:

```systemverilog
// 각 입력에서 ISW 추출
for (genvar i = 0; i < BLOCK_SIZE; ++i) begin
    if (BLOCK_SIZE != `ISSUE_WIDTH) begin
        if (BLOCK_SIZE != 1) begin
            // WID의 상위 비트 + 블록 인덱스
            assign result_in_isw[i] = {result_in_data[i][...], BLOCK_SIZE_W'(i)};
        end else begin
            assign result_in_isw[i] = result_in_data[i][DATA_WIS_OFF +: ISSUE_ISW_W];
        end
    end else begin
        assign result_in_isw[i] = BLOCK_SIZE_W'(i);
    end
end

// ISW에 따라 출력으로 라우팅
always @(*) begin
    result_out_valid = '0;
    for (integer i = 0; i < BLOCK_SIZE; ++i) begin
        result_out_valid[result_in_isw[i]] = result_in_valid[i];
        result_out_data[result_in_isw[i]] = result_in_data[i];
    end
end
```

### 2. 패킷 → SIMD 변환

NUM_LANES 크기 패킷을 SIMD_WIDTH 크기로 확장:

```systemverilog
if (LPID_BITS != 0) begin
    // lpid: 패킷 인덱스 (Local Packet ID)
    logic [LPID_WIDTH-1:0] lpid;
    if (SIMD_COUNT != 1) begin
        // pid = {sid, lpid}
        assign {commit_sid_w, lpid} = result_tmp_if.data.pid;
    end else begin
        assign lpid = result_tmp_if.data.pid;
    end

    // lpid 위치에 데이터 배치
    always @(*) begin
        commit_tmask_w = '0;
        commit_data_w  = 'x;
        for (integer j = 0; j < NUM_LANES; ++j) begin
            commit_tmask_w[lpid * NUM_LANES + j] = result_tmp_if.data.tmask[j];
            commit_data_w[lpid * NUM_LANES + j] = result_tmp_if.data.data[j];
        end
    end
end
```

**예시** (SIMD_WIDTH=16, NUM_LANES=4, lpid=2):
```
입력 (NUM_LANES=4):
  tmask = 4'b1101
  data  = [D0, D1, D2, D3]

출력 (SIMD_WIDTH=16, lpid=2이므로 [8:11] 위치):
  tmask = 16'b0000_1101_0000_0000
                    ↑
                 [11:8] 위치
  data  = [x, x, x, x, x, x, x, x, D0, D1, D2, D3, x, x, x, x]
```

### 3. 출력 버퍼

각 Issue Slot마다 elastic buffer:

```systemverilog
for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin
    VX_elastic_buffer #(
        .DATAW   (DATAW),
        .SIZE    (`TO_OUT_BUF_SIZE(OUT_BUF)),
        .OUT_REG (`TO_OUT_BUF_REG(OUT_BUF))
    ) out_buf (
        .clk        (clk),
        .reset      (reset),
        .valid_in   (result_out_valid[i]),
        .data_in    (result_out_data[i]),
        .data_out   (result_tmp_if.data),
        .valid_out  (result_tmp_if.valid),
        .ready_out  (result_tmp_if.ready)
    );
end
```

## 데이터 흐름

```
result_if[BLOCK_SIZE]
     │
     ├── result_if[0].data ──┬──→ ISW 추출 ──→ result_out[isw]
     ├── result_if[1].data ──┤
     └── ...                 │
                             │
                             ▼
              ┌──────────────────────────────┐
              │  Issue Slot별 처리            │
              │                              │
              │  lpid = pid & mask           │
              │  sid  = pid >> lpid_bits     │
              │                              │
              │  for j in NUM_LANES:         │
              │    out_tmask[lpid*NL+j] = in │
              │    out_data[lpid*NL+j] = in  │
              └──────────────────────────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │      VX_elastic_buffer       │
              └──────────────────────────────┘
                             │
                             ▼
                    commit_if[ISSUE_WIDTH]
                    (SIMD_WIDTH 크기)
```

## Dispatch ↔ Gather 관계

```
                  VX_dispatch_unit                    VX_gather_unit
                        │                                   │
SIMD_WIDTH ────────────→│                                   │←───────── SIMD_WIDTH
                        │                                   │
                        ▼                                   ▼
              ┌─────────────────┐                ┌─────────────────┐
              │   패킷 분할     │                │   패킷 병합     │
              │  (Split)        │                │  (Merge)        │
              └────────┬────────┘                └────────┬────────┘
                       │                                  │
              NUM_LANES│                         NUM_LANES│
                       ▼                                  ▼
              ┌─────────────────┐                ┌─────────────────┐
              │   실행 유닛     │ ──────────────→ │   결과 수신     │
              │  (Execute)      │                │  (Result)       │
              └─────────────────┘                └─────────────────┘

dispatch_if.data:                    result_if.data:
  - wis (Warp Issue Slot)              - wid (Warp ID)
  - sid (SIMD Index)                   - pid (Packet ID)
  - tmask[SIMD_WIDTH]                  - tmask[NUM_LANES]
  - rs*_data[SIMD_WIDTH]               - data[NUM_LANES]
  - sop, eop                           - sop, eop

commit_if.data:
  - sid (SIMD Index)
  - tmask[SIMD_WIDTH]  ← 복원
  - data[SIMD_WIDTH]   ← 복원
```

## 사용 위치

| 실행 유닛 | BLOCK_SIZE | NUM_LANES |
|-----------|------------|-----------|
| ALU | NUM_ALU_BLOCKS | NUM_ALU_LANES |
| LSU | NUM_LSU_BLOCKS | NUM_LSU_LANES |
| SFU | 1 | NUM_SFU_LANES |
| FPU | NUM_FPU_BLOCKS | NUM_FPU_LANES |

## 특수 케이스: SIMD_WIDTH == NUM_LANES

패킷 분할/병합이 불필요한 경우:

```systemverilog
if (LPID_BITS == 0) begin  // NUM_PACKETS = 1
    assign commit_sid_w   = result_tmp_if.data.pid;  // pid = sid
    assign commit_tmask_w = result_tmp_if.data.tmask; // 그대로 전달
    assign commit_data_w  = result_tmp_if.data.data;  // 그대로 전달
end
```

## 성능 특성

- **레이턴시**: OUT_BUF 설정에 따라 0~N 사이클
- **스루풋**: 패킷당 1 사이클
- **병렬 처리**: Issue Slot별 독립 처리

## 관련 파일

- [VX_dispatch_unit.md](VX_dispatch_unit.md) - 역연산 (분할)
- [VX_sfu_unit.md](VX_sfu_unit.md) - SFU에서 사용
- [VX_alu_unit.sv](../../../../hw/rtl/core/VX_alu_unit.sv) - ALU에서 사용
- [VX_lsu_unit.sv](../../../../hw/rtl/core/VX_lsu_unit.sv) - LSU에서 사용
