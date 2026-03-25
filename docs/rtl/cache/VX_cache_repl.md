# `VX_cache_repl.sv` — 교체 정책 상세 분석

파일: `hw/rtl/cache/VX_cache_repl.sv`

## 1. 역할

`VX_cache_repl`은 캐시 miss 시 **어떤 way를 evict할지** 결정하는 교체 정책 모듈입니다. 3가지 정책을 지원합니다:
- `CS_REPL_PLRU` (2): Pseudo Least Recently Used
- `CS_REPL_FIFO` (1): First In First Out
- `CS_REPL_RANDOM` (0): Random

## 2. 인터페이스

### Lookup (hit 시 LRU 정보 업데이트)
```
lookup_valid — lookup 유효 (hit 시)
lookup_hit   — cache hit 여부
lookup_line  — 접근한 라인 인덱스
lookup_way   — hit한 way 인덱스
```

### Replacement (fill 시 victim way 선택)
```
repl_valid — replacement 유효 (fill 시)
repl_line  — fill 대상 라인 인덱스
repl_way   — (output) 선택된 victim way
```

### 기타
```
stall — 파이프라인 stall
init  — 초기화 모드
```

## 3. 교체 정책 상세

### 3.1 Pseudo-LRU (PLRU)

**원리**: tree-based PLRU 알고리즘. NUM_WAYS-1 비트의 LRU 상태를 트리 구조로 관리합니다.

```
4-way 캐시 예시 (3비트 LRU 상태):

         bit[0]
        /      \
    bit[1]    bit[2]
    /    \    /    \
  way0  way1 way2  way3

bit=0: 왼쪽이 최근 접근 → 오른쪽을 victim으로 선택
bit=1: 오른쪽이 최근 접근 → 왼쪽을 victim으로 선택
```

**구현**:

```systemverilog
// LRU 상태 저장 (라인당 하나)
VX_dp_ram #(
    .DATAW    (LRU_WIDTH),        // NUM_WAYS-1 비트
    .SIZE     (CS_LINES_PER_BANK),
    .WRENW    (LRU_WIDTH),        // 비트별 write enable
    .RADDR_REG(1)                 // 읽기 주소 레지스터
) plru_store (
    .read  (repl_valid),                           // fill 시 읽기
    .write (init || (lookup_valid && lookup_hit)),  // hit 시 업데이트
    .wren  (init ? '1 : plru_wmask),               // init: 전체 클리어, hit: 해당 비트만
    .waddr (lookup_line),                           // hit한 라인
    .raddr (repl_line),                             // fill할 라인
    .wdata (init ? '0 : plru_wdata)
);
```

**plru_decoder** (hit 시 → LRU 업데이트 데이터 생성):
```systemverilog
// way_idx를 기반으로 tree에서 "이 way를 가장 최근 접근"으로 마킹
// 루트에서 해당 way까지의 경로에 있는 비트들을 반대 방향으로 설정
module plru_decoder (
    input  way_idx,
    output lru_data,   // 쓸 데이터
    output lru_mask    // 어떤 비트를 업데이트할지
);
```

예시 (4-way, way2 접근 시):
```
         0 ← bit[0]을 0으로 (왼쪽이 최근)... 아니, way2는 오른쪽이므로 1로
        / \
      _    1 ← bit[2]를 1로 (way2는 왼쪽 자식이므로, 오른쪽을 가리킴)
           / \
         way2  way3

lru_data = {~way_idx[MSB], ~way_idx[MSB-1], ...}
lru_mask = tree에서 해당 way까지의 경로에 있는 비트들
```

**plru_encoder** (fill 시 → victim way 선택):
```systemverilog
// LRU 상태에서 가장 오래된 way를 찾음
// 루트에서 시작하여 각 비트가 가리키는 방향을 따라감
module plru_encoder (
    input  lru_in,
    output way_idx    // victim way
);
```

### 3.2 FIFO

**원리**: 각 라인에 대해 카운터를 유지하고, fill 시 현재 카운터가 가리키는 way를 victim으로 선택한 후 카운터를 증가시킵니다.

```systemverilog
wire [WAY_SEL_WIDTH-1:0] fifo_rdata;
wire [WAY_SEL_WIDTH-1:0] fifo_wdata = fifo_rdata + 1;  // 다음 victim

VX_sp_ram #(
    .DATAW    (WAY_SEL_WIDTH),
    .SIZE     (CS_LINES_PER_BANK),
    .RADDR_REG(1)
) fifo_store (
    .read  (repl_valid),              // fill 시 현재 victim 읽기
    .write (init || repl_valid),      // init: 0으로 초기화, fill: +1
    .addr  (repl_line),
    .wdata (init ? '0 : fifo_wdata),
    .rdata (fifo_rdata)
);

assign repl_way = fifo_rdata;  // 현재 카운터 값이 victim way
```

**특징**:
- lookup 정보(hit, way)를 사용하지 않음 → 더 단순
- 카운터 기반이므로 hit 패턴과 무관하게 순환적으로 way 교체

### 3.3 Random

**원리**: 매 사이클 카운터를 증가시키고, fill 시 현재 카운터 값을 victim으로 사용합니다.

```systemverilog
reg [WAY_SEL_WIDTH-1:0] victim_idx;
always @(posedge clk) begin
    if (reset) begin
        victim_idx <= 0;
    end else if (~stall) begin
        victim_idx <= victim_idx + 1;
    end
end
assign repl_way = victim_idx;
```

**특징**:
- 라인별 상태 저장 불필요 → SRAM 절약
- 매 사이클 증가하는 글로벌 카운터 → pseudo-random

## 4. 뱅크 파이프라인과의 타이밍

```
Stage 0: repl_valid (fill 시) → repl_way 읽기 (RADDR_REG=1이므로 다음 사이클에 결과)
         → 실제로는 repl_line이 Stage 0에서 제공되고,
           repl_way(victim_way_st0)가 같은 사이클에 사용됨

Stage 1: lookup_valid (hit 시) → LRU 업데이트 (PLRU만)
```

**주의**: `RADDR_REG=1`을 사용하므로, `repl_line`은 SRAM 읽기 주소 레지스터에 등록되고, 결과(`repl_way`)는 같은 사이클에 나옵니다 (주소 등록 후 읽기). 이는 BRAM의 출력 레지스터와 다른 개념입니다.

## 5. NUM_WAYS=1 (Direct-Mapped)

```systemverilog
if (NUM_WAYS > 1) begin : g_enable
    // ... 교체 정책 구현
end else begin : g_disable
    assign repl_way = 1'b0;  // 항상 way 0 (유일한 way)
end
```

## 6. 교체 정책 비교

| 정책 | 메모리 사용 | Hit Rate | 복잡도 |
|------|-------------|----------|--------|
| PLRU | (NUM_WAYS-1) × LINES_PER_BANK bits | 높음 | Tree 구조, encoder/decoder |
| FIFO | WAY_SEL_WIDTH × LINES_PER_BANK bits | 중간 | 카운터 기반 |
| Random | WAY_SEL_WIDTH bits (글로벌) | 낮음 | 매우 단순 |
