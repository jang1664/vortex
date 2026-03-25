# `VX_cache_tags.sv` — 태그 저장소 상세 분석

파일: `hw/rtl/cache/VX_cache_tags.sv`

## 1. 역할

`VX_cache_tags`는 각 캐시 라인의 **tag, valid, dirty** 비트를 관리하는 모듈입니다. 요청이 캐시에 있는지(hit/miss) 판정하고, eviction 시 dirty 상태와 evict 대상의 태그를 제공합니다.

## 2. 파라미터

| 파라미터 | 설명 |
|----------|------|
| `CACHE_SIZE` | 캐시 총 크기 |
| `LINE_SIZE` | 캐시 라인 크기 |
| `NUM_BANKS` | 뱅크 수 (bank당 라인 수 계산에 사용) |
| `NUM_WAYS` | set-associativity |
| `WORD_SIZE` | 워드 크기 |
| `WRITEBACK` | writeback 모드 시 dirty 비트 관리 |

## 3. 인터페이스

### 입력
```
stall      — 파이프라인 stall (읽기 억제)
init       — 초기화 모드 (모든 라인 invalidate)
flush      — flush 모드 (라인 invalidate)
fill       — fill 모드 (새 태그 기록, valid 설정)
read       — 읽기 요청
write      — 쓰기 요청 (writeback 모드에서 dirty 설정)
line_idx   — 현재 접근할 라인 인덱스
line_idx_n — 다음 사이클에 접근할 라인 인덱스 (read-first RAM 최적화)
line_tag   — 비교할 태그 값
evict_way  — eviction 대상 way (fill/flush 시)
```

### 출력
```
tag_matches [NUM_WAYS-1:0] — 각 way별 tag match 결과 (one-hot)
evict_dirty                — evict 대상 way가 dirty인지
evict_tag                  — evict 대상 way의 태그 값
```

## 4. 태그 엔트리 구조

### Write-Through 모드 (`WRITEBACK=0`)
```
TAG_WIDTH = 1 + CS_TAG_SEL_BITS
┌───────┬──────────────┐
│ valid │    tag        │
│ (1b)  │ (TAG_BITS)   │
└───────┴──────────────┘
```

### Writeback 모드 (`WRITEBACK=1`)
```
TAG_WIDTH = 1 + 1 + CS_TAG_SEL_BITS
┌───────┬───────┬──────────────┐
│ valid │ dirty │    tag        │
│ (1b)  │ (1b)  │ (TAG_BITS)   │
└───────┴───────┴──────────────┘
```

## 5. 내부 구현 상세

### 5.1 Per-Way Tag Store

각 way마다 독립적인 `VX_dp_ram`이 있습니다:

```systemverilog
for (genvar i = 0; i < NUM_WAYS; ++i) begin : g_tag_store
    VX_dp_ram #(
        .DATAW    (TAG_WIDTH),
        .SIZE     (CS_LINES_PER_BANK),    // 뱅크당 라인 수
        .OUT_REG  (1),                     // 출력 레지스터 (read latency = 1)
        .RDW_MODE ("R")                    // Read-First 모드
    ) tag_store (
        .clk   (clk),
        .reset (reset),
        .read  (~stall),           // stall 시 읽기 억제
        .write (line_write),       // init/fill/flush/write 시 쓰기
        .wren  (1'b1),
        .waddr (line_idx),         // 현재 쓰기 주소
        .raddr (line_idx_n),       // 다음 사이클 읽기 주소 (read-first 최적화)
        .wdata (line_wdata),
        .rdata (line_rdata)
    );
end
```

### 5.2 쓰기 조건 (각 way)

```systemverilog
wire way_en   = (NUM_WAYS == 1) || (evict_way == i);  // 이 way가 선택되었는지

wire do_init  = init;                    // 모든 way 초기화
wire do_fill  = fill && way_en;          // 선택된 way에만 fill
wire do_flush = flush && (!WRITEBACK || way_en);  // WT: 모든 way flush, WB: 선택된 way만
wire do_write = WRITEBACK && write && tag_matches[i];  // WB: hit한 way의 dirty만 설정

wire line_write = do_init || do_fill || do_flush || do_write;
wire line_valid = fill || write;  // fill이나 write는 valid 유지, init/flush는 invalid
```

### 5.3 쓰기 데이터

**Writeback 모드**:
```systemverilog
line_wdata = {line_valid, write, line_tag};
// fill: {1(valid), 0(clean), new_tag}
// write(hit): {1(valid), 1(dirty), existing_tag}
// init/flush: {0(invalid), 0(clean), tag}
```

**Write-Through 모드**:
```systemverilog
line_wdata = {line_valid, line_tag};
// fill: {1(valid), new_tag}
// init/flush: {0(invalid), tag}
```

### 5.4 읽기 및 Tag Match

```systemverilog
// Writeback 모드
read_tag[i]   = line_rdata[0 +: CS_TAG_SEL_BITS];
read_dirty[i] = line_rdata[CS_TAG_SEL_BITS] || rdw_write;  // RDW hazard 보상
read_valid[i] = line_rdata[CS_TAG_SEL_BITS + 1];

// Tag match 판정
tag_matches[i] = (read_valid[i] && (line_tag == read_tag[i])) || rdw_fill;
```

### 5.5 Read-During-Write (RDW) Hazard 처리

`VX_dp_ram`은 **Read-First** 모드를 사용하므로, 같은 사이클에 같은 주소에 read와 write가 동시에 발생하면 **이전 값**이 읽힙니다. 이는 다음 상황에서 문제가 됩니다:

1. **Fill 직후 Replay**: fill이 태그를 기록하고, 바로 다음 사이클에 replay가 같은 라인을 읽으면 새 태그가 아직 읽히지 않음
   ```systemverilog
   `BUFFER(rdw_fill, do_fill);  // fill 다음 사이클에 강제 match
   tag_matches[i] = (...) || rdw_fill;  // fill 직후는 무조건 match
   ```

2. **Write 직후 Fill/Flush**: write로 dirty를 설정한 직후, 같은 라인에 fill/flush가 dirty 비트를 읽으면 이전 값이 읽힘
   ```systemverilog
   `BUFFER(rdw_write, do_write && (line_idx == line_idx_n));
   read_dirty[i] = line_rdata[CS_TAG_SEL_BITS] || rdw_write;  // 강제 dirty
   ```

## 6. Eviction 정보

```systemverilog
// Writeback 모드: 선택된 evict way의 dirty/tag 정보 제공
evict_dirty = read_dirty[evict_way];
evict_tag   = read_tag[evict_way];

// Write-Through 모드: dirty가 없으므로 항상 clean
evict_dirty = 1'b0;
evict_tag   = '0;
```

## 7. 설계 핵심 포인트

1. **Read-First RAM + RDW Hazard Bypass**: BRAM의 Read-First 특성을 활용하면서, 1-cycle hazard는 별도 bypass 로직(`rdw_fill`, `rdw_write`)으로 해결합니다.

2. **line_idx vs line_idx_n**: 쓰기는 현재 인덱스(`line_idx`)에, 읽기는 다음 사이클 인덱스(`line_idx_n`)에 수행합니다. 이는 BRAM의 output register(OUT_REG=1)와 결합하여, 읽기 결과가 다음 파이프라인 스테이지에서 바로 사용 가능하도록 합니다.

3. **Per-Way 독립 BRAM**: 각 way가 별도 BRAM을 사용하여, 모든 way의 태그를 동시에 읽을 수 있습니다 (병렬 태그 비교).

4. **Flush 동작 차이**:
   - Write-Through: 모든 way를 한번에 flush (way_en 무관하게 전체 invalidate)
   - Writeback: 선택된 way만 flush (dirty 라인의 데이터를 먼저 writeback 해야 하므로)
