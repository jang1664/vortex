# `VX_cache_data.sv` — 데이터 저장소 상세 분석

파일: `hw/rtl/cache/VX_cache_data.sv`

## 1. 역할

`VX_cache_data`는 캐시 라인의 **실제 데이터**를 저장하는 SRAM 기반 모듈입니다. Fill(메모리 → 캐시), Read(캐시 → 코어), Write(코어 → 캐시) 연산을 수행하며, Writeback 모드에서는 eviction 시 데이터와 dirty byte 정보를 제공합니다.

## 2. 파라미터

| 파라미터 | 설명 |
|----------|------|
| `CACHE_SIZE`, `LINE_SIZE`, `NUM_BANKS`, `NUM_WAYS`, `WORD_SIZE` | 캐시 기하 |
| `WRITE_ENABLE` | 쓰기 가능 여부 (0이면 read-only 캐시) |
| `WRITEBACK` | writeback 모드 (eviction 시 데이터 readback 필요) |
| `DIRTY_BYTES` | dirty byte 단위 추적 (partial writeback 지원) |

## 3. 인터페이스

### 입력
```
init        — 초기화 (dirty bytes 클리어)
fill        — fill 데이터 쓰기 (전체 라인)
flush       — flush (dirty bytes 읽기 / 클리어)
read        — 데이터 읽기
write       — 워드 쓰기 (byte enable 기반)
line_idx    — 라인 인덱스
evict_way   — fill/flush 시 대상 way
tag_matches — [NUM_WAYS-1:0] hit한 way (write 시 해당 way에만 쓰기)
fill_data   — fill 데이터 (전체 라인: CS_WORDS_PER_LINE x CS_WORD_WIDTH)
write_word  — 쓰기 워드 데이터
write_byteen— 바이트 enable
word_idx    — 라인 내 워드 선택
way_idx_r   — 읽기 시 way 선택 (다음 스테이지에서 결정)
```

### 출력
```
read_data    — 읽기 결과 (전체 라인: CS_LINE_WIDTH)
evict_byteen — eviction 시 dirty bytes (DIRTY_BYTES 모드)
```

## 4. 내부 구현 상세

### 4.1 Write Mask 생성

워드 단위 바이트 enable을 라인 전체로 확장합니다:

```systemverilog
wire [CS_WORDS_PER_LINE-1:0][WORD_SIZE-1:0] write_mask;
for (genvar i = 0; i < CS_WORDS_PER_LINE; ++i) begin
    wire word_en = (CS_WORDS_PER_LINE == 1) || (word_idx == i);
    assign write_mask[i] = write_byteen & {WORD_SIZE{word_en}};
end
```

예시 (4 words/line, word_idx=2, byteen=4'b1100):
```
write_mask = {4'b0000, 4'b0000, 4'b1100, 4'b0000}
              word3    word2    word1    word0
                                ^^선택됨
```

### 4.2 Per-Way Data Store

각 way마다 독립적인 `VX_sp_ram`이 있습니다:

```systemverilog
for (genvar i = 0; i < NUM_WAYS; ++i) begin : g_data_store
    // 쓰기 데이터: fill이면 전체 라인, write면 워드 복제
    assign line_wdata = fill ? fill_data : {CS_WORDS_PER_LINE{write_word}};

    // 쓰기 enable: fill이면 전체 바이트, write면 해당 바이트만
    assign line_wren = {LINE_SIZE{fill}} | write_mask;

    // 쓰기 조건
    wire line_write = (fill && ((NUM_WAYS == 1) || (evict_way == i)))  // fill: 선택 way
                   || (write && tag_matches[i] && WRITE_ENABLE);       // write: hit way

    // 읽기 조건
    wire line_read = read || ((fill || flush) && WRITEBACK);
    // read: 일반 읽기
    // fill/flush + WRITEBACK: eviction 전 dirty 데이터 읽기

    VX_sp_ram #(
        .DATAW   (CS_LINE_WIDTH),
        .SIZE    (CS_LINES_PER_BANK),
        .WRENW   (WRENW),              // byte-level write enable
        .OUT_REG (1),                   // 1-cycle read latency
        .RDW_MODE ("R")                 // Read-First
    ) data_store (...);
end
```

### 4.3 Read 출력

```systemverilog
// way_idx_r은 다음 스테이지(Stage 2)에서 결정된 way를 사용
assign read_data = line_rdata[way_idx_r];
```

`way_idx_r`이 Stage 2에서 오고 데이터 SRAM 읽기는 Stage 1에서 시작되므로, 모든 way의 데이터를 동시에 읽고 Stage 2에서 way를 선택하는 **late-select** 방식입니다.

### 4.4 Dirty Bytes 추적 (DIRTY_BYTES 모드)

```systemverilog
if (DIRTY_BYTES != 0) begin : g_dirty_bytes
    for (genvar i = 0; i < NUM_WAYS; ++i) begin
        // 쓰기 데이터: write이면 1, fill/flush/init이면 0 (클리어)
        wire [LINE_SIZE-1:0] byteen_wdata = {LINE_SIZE{write}};

        // 쓰기 enable: init/fill/flush는 전체 클리어, write는 해당 바이트만 설정
        wire [LINE_SIZE-1:0] byteen_wren = {LINE_SIZE{init || fill || flush}} | write_mask;

        // 쓰기 조건
        wire byteen_write = ((fill || flush) && (evict_way == i))
                         || (write && tag_matches[i])
                         || init;

        // 읽기 조건: fill/flush 시 eviction 대상의 dirty bytes 확인
        wire byteen_read = fill || flush;

        VX_sp_ram #(
            .DATAW   (LINE_SIZE),     // 라인 크기만큼의 비트 (byte당 1비트)
            .WRENW   (LINE_SIZE),     // byte-level write enable
        ) byteen_store (...);
    end

    assign evict_byteen = byteen_rdata[way_idx_r];
end else begin
    assign evict_byteen = '1;  // dirty bytes 미추적 시 전체 라인 writeback
end
```

**Dirty Bytes 동작 원리**:
- Write 시: 해당 바이트 위치의 dirty bit을 1로 설정
- Fill/Flush 시: 모든 dirty bit을 0으로 클리어 (새 데이터이므로)
- Eviction 시: `evict_byteen`으로 어떤 바이트가 dirty인지 알려줌 → 해당 바이트만 writeback

### 4.5 Read-Only 모드 (WRITE_ENABLE=0)

```systemverilog
if (WRITE_ENABLE) begin : g_wren
    assign line_wdata = fill ? fill_data : {CS_WORDS_PER_LINE{write_word}};
    assign line_wren  = {LINE_SIZE{fill}} | write_mask;
end else begin : g_no_wren
    assign line_wdata = fill_data;    // fill만 가능
    assign line_wren  = 1'b1;         // 전체 쓰기 (fill만이므로)
end
```

## 5. 타이밍 관계 (뱅크 파이프라인과)

```
Stage 1 (뱅크):
  - fill/read/write 신호 생성
  - VX_cache_data에 입력 제공
  - SRAM 읽기 시작 (OUT_REG=1이므로 결과는 다음 사이클)

Stage 2 (뱅크):
  - read_data 사용 가능 (SRAM 출력)
  - way_idx_r로 해당 way 데이터 선택
  - core response 또는 writeback 데이터로 사용
```

## 6. 설계 핵심 포인트

1. **Late-Select 방식**: 모든 way의 데이터를 동시에 읽고, way 선택은 다음 스테이지에서 수행합니다. 이는 tag match 결과가 data read와 동시에 필요하지 않으므로 timing을 완화합니다.

2. **Byte-Level Write Enable**: `VX_sp_ram`의 `WRENW` 파라미터로 바이트 단위 쓰기를 지원합니다. Fill은 전체 라인 쓰기, Write는 특정 워드의 특정 바이트만 쓰기.

3. **Write 데이터 복제**: write 시 `{CS_WORDS_PER_LINE{write_word}}`로 워드를 라인 전체에 복제하지만, `write_mask`가 해당 워드 위치만 enable하므로 실제로는 해당 워드만 기록됩니다.

4. **Writeback 모드 읽기**: fill/flush 시에도 데이터를 읽어야 합니다 (eviction 대상의 dirty 데이터를 메모리에 기록하기 위해). 이는 `line_read = read || ((fill || flush) && WRITEBACK)`으로 구현됩니다.
