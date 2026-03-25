# `VX_cache_define.vh` — 캐시 공통 매크로 정의

파일: `hw/rtl/cache/VX_cache_define.vh`

## 1. 역할

캐시 시스템 전체에서 사용되는 공통 매크로를 정의합니다. 주소 분해, 크기 계산, 성능 카운터, 교체 정책 상수 등을 포함합니다.

## 2. 크기/폭 매크로

| 매크로 | 계산식 | 설명 |
|--------|--------|------|
| `CS_WORD_WIDTH` | `8 * WORD_SIZE` | 워드 비트 폭 |
| `CS_LINE_WIDTH` | `8 * LINE_SIZE` | 라인 비트 폭 |
| `CS_BANK_SIZE` | `CACHE_SIZE / NUM_BANKS` | 뱅크당 크기 (바이트) |
| `CS_LINES_PER_BANK` | `CS_BANK_SIZE / (LINE_SIZE * NUM_WAYS)` | 뱅크당 라인 수 (= set 수) |
| `CS_WORDS_PER_LINE` | `LINE_SIZE / WORD_SIZE` | 라인당 워드 수 |
| `CS_WAY_SEL_BITS` | `CLOG2(NUM_WAYS)` | way 선택 비트 수 |
| `CS_WAY_SEL_WIDTH` | `UP(CS_WAY_SEL_BITS)` | way 선택 비트 폭 (최소 1) |

## 3. 주소 분해 매크로

### 주소 폭
| 매크로 | 계산식 | 설명 |
|--------|--------|------|
| `CS_WORD_ADDR_WIDTH` | `MEM_ADDR_WIDTH - CLOG2(WORD_SIZE)` | 워드 주소 폭 |
| `CS_MEM_ADDR_WIDTH` | `MEM_ADDR_WIDTH - CLOG2(LINE_SIZE)` | 메모리(라인) 주소 폭 |
| `CS_LINE_ADDR_WIDTH` | `CS_MEM_ADDR_WIDTH - CLOG2(NUM_BANKS)` | 뱅크 내 라인 주소 폭 |

### 주소 필드 비트 범위

워드 주소를 다음과 같이 분해합니다:

```
CS_WORD_ADDR_WIDTH-1                                              0
  ┌──────────────┬───────────────────┬──────────────┬──────────────┐
  │   TAG_SEL    │    LINE_SEL       │  BANK_SEL    │  WORD_SEL    │
  └──────────────┴───────────────────┴──────────────┴──────────────┘
```

| 필드 | 비트 수 | 시작 비트 | 끝 비트 |
|------|---------|-----------|---------|
| `CS_WORD_SEL_BITS` | `CLOG2(CS_WORDS_PER_LINE)` | 0 | `WORD_SEL_BITS-1` |
| `CS_BANK_SEL_BITS` | `CLOG2(NUM_BANKS)` | `WORD_SEL_END+1` | `BANK_SEL_END` |
| `CS_LINE_SEL_BITS` | `CLOG2(CS_LINES_PER_BANK)` | `BANK_SEL_END+1` | `LINE_SEL_END` |
| `CS_TAG_SEL_BITS` | 나머지 | `LINE_SEL_END+1` | `WORD_ADDR_WIDTH-1` |

### 주소 변환 매크로

```systemverilog
// 뱅크 내 주소 + 뱅크 ID → 전체 주소 (디버그용)
`CS_BANK_TO_FULL_ADDR(x, b)  =  {x, (XLEN-bits(x))'(b << offset)}

// 메모리 주소 → 전체 주소
`CS_MEM_TO_FULL_ADDR(x)  =  {x, 0...0}

// 라인 주소에서 태그 추출
`CS_LINE_ADDR_TAG(x)  =  x[CS_LINE_ADDR_WIDTH-1 : CS_LINE_SEL_BITS]
```

## 4. 교체 정책 상수

```systemverilog
`CS_REPL_RANDOM  = 0   // Random 교체
`CS_REPL_FIFO    = 1   // FIFO 교체
`CS_REPL_PLRU    = 2   // Pseudo-LRU 교체
```

## 5. 성능 카운터 집계 매크로

```systemverilog
`PERF_CACHE_ADD(dst, src, count)
```

`count`개의 `src` 배열에서 다음 필드를 합산하여 `dst`에 저장:
- `reads`, `writes` — 요청 수
- `read_misses`, `write_misses` — miss 수
- `bank_stalls` — 뱅크 충돌 stall
- `mshr_stalls` — MSHR full stall
- `mem_stalls` — 메모리 backpressure stall
- `crsp_stalls` — core response backpressure stall

## 6. 계산 예시

CACHE_SIZE=32768, LINE_SIZE=64, NUM_BANKS=4, NUM_WAYS=4, WORD_SIZE=4 일 때:

```
CS_BANK_SIZE       = 32768 / 4 = 8192 bytes
CS_LINES_PER_BANK  = 8192 / (64 * 4) = 32 lines
CS_WORDS_PER_LINE  = 64 / 4 = 16 words

CS_WORD_SEL_BITS   = log2(16) = 4 bits   [3:0]
CS_BANK_SEL_BITS   = log2(4)  = 2 bits   [5:4]
CS_LINE_SEL_BITS   = log2(32) = 5 bits   [10:6]
CS_TAG_SEL_BITS    = 나머지                [WORD_ADDR_WIDTH-1:11]
```
