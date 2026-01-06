# VX_elastic_buffer의 OUT_REG 파라미터 분석

## 📌 개요

`VX_elastic_buffer`는 valid-ready 기반의 탄성 버퍼로, **버퍼 크기(SIZE)**와 **출력 레지스터 설정(OUT_REG)**에 따라 다양한 구조로 동작합니다.

OUT_REG 값은 **출력단에 몇 단계의 파이프라인 레지스터를 추가할지** 결정하며, 이는 타이밍 최적화와 레이턴시 사이의 트레이드오프를 조절합니다.

---

## 🔢 OUT_REG 값의 인코딩

OUT_REG는 비트 인코딩 방식을 사용합니다:

```c
// VX_platform.vh의 매크로 정의
TO_OUT_BUF_SIZE(s)   = MIN(s & 7, 2)      // 하위 3비트로 SIZE 결정
TO_OUT_BUF_REG(s)    = (s & 7) < 2 ? (s & 7) : ((s & 7) - 2)  // 레지스터 단수
TO_OUT_BUF_LUTRAM(s) = (s & 8) != 0        // 비트3이 LUTRAM 플래그
```

### 비트 구조
```
OUT_REG = [bit3: LUTRAM | bit2-0: 설정값]
```

| Bit 3 | Bit 2-0 | LUTRAM | SIZE | REG_DEPTH | 설명 |
|-------|---------|--------|------|-----------|------|
| 0     | 000 (0) | No     | 0    | 0         | Pass-through |
| 0     | 001 (1) | No     | 1    | 1         | 1-stage register |
| 0     | 010 (2) | No     | 2    | 0         | 2-entry FIFO |
| 0     | 011 (3) | No     | 2    | 1         | 2-entry FIFO + 1 reg |
| 0     | 100 (4) | No     | 2    | 2         | 2-entry FIFO + 2 reg |
| 0     | 101 (5) | No     | 2    | 3         | 2-entry FIFO + 3 reg |
| 0     | 110 (6) | No     | 2    | 4         | 2-entry FIFO + 4 reg |
| 0     | 111 (7) | No     | 2    | 5         | 2-entry FIFO + 5 reg |
| 1     | xxx     | Yes    | 2    | x-2       | LUTRAM 기반 FIFO |

---

## 🏗️ 내부 구조별 동작

### 1. SIZE = 0 (OUT_REG = 0)
**완전 Pass-through 모드**

```systemverilog
assign valid_out = valid_in;
assign data_out  = data_in;
assign ready_in  = ready_out;
```

**특징:**
- ✅ 레이턴시 0
- ✅ 면적 최소
- ❌ 타이밍 경로 직통 (combinational path)
- ❌ 버퍼링 없음

**사용 시나리오:**
- 타이밍 여유가 충분할 때
- 레이턴시가 critical할 때

---

### 2. SIZE = 1 (OUT_REG = 1)
**Single Pipeline Register**

```systemverilog
VX_pipe_buffer #(
    .DATAW (DATAW),
    .DEPTH (MAX(OUT_REG, 1))  // = 1
) pipe_buffer (...);
```

**특징:**
- ✅ 레이턴시 1 사이클
- ✅ 타이밍 경로 차단
- ⚠️ Backpressure 전파 (ready 신호는 combinational)
- 💾 플립플롭 사용: `DATAW` 비트

**사용 시나리오:**
- 긴 조합 경로를 끊고 싶을 때
- 최소한의 버퍼링만 필요할 때

---

### 3. SIZE = 2, LUTRAM = 0 (OUT_REG = 2~7)
**2-Entry FIFO + Optional Output Registers**

```systemverilog
VX_stream_buffer #(
    .DATAW   (DATAW),
    .OUT_REG (OUT_REG == 1)  // false for OUT_REG >= 2
) stream_buffer (...);

VX_pipe_buffer #(
    .DATAW (DATAW),
    .DEPTH ((OUT_REG > 1) ? (OUT_REG-1) : 0)
) out_buf (...);
```

#### OUT_REG별 세부 구조

**OUT_REG = 2:**
```
Input → [2-Entry Stream Buffer] → Output
        (내부 레지스터 없음)
```
- 레이턴시: 0~2 사이클 (버퍼 상태에 따라)
- Backpressure 버퍼링: 2 entries

**OUT_REG = 3:**
```
Input → [2-Entry Stream Buffer (OUT_REG=1)] → [1-stage pipe] → Output
```
- 레이턴시: 1~3 사이클
- 출력단 레지스터 1개 추가

**OUT_REG = 4:**
```
Input → [2-Entry Stream Buffer] → [2-stage pipe] → Output
```
- 레이턴시: 2~4 사이클
- 출력단 레지스터 2개 추가

**OUT_REG = 5:**
```
Input → [2-Entry Stream Buffer] → [3-stage pipe] → Output
```
- 레이턴시: 3~5 사이클
- 출력단 레지스터 3개 추가

**특징:**
- ✅ 2-entry 버퍼링으로 burst 처리
- ✅ OUT_REG 값에 따라 출력단 파이프라인 깊이 조절
- 💾 플립플롭 사용: 약 `2 * DATAW + (OUT_REG-2) * DATAW` 비트

**사용 시나리오:**
- 짧은 버스트 트래픽 처리
- 출력단 타이밍 최적화 필요 시

---

### 4. SIZE ≥ 3 또는 LUTRAM = 1 (OUT_REG ≥ 3 or bit3=1)
**N-Entry FIFO Queue + Optional Output Registers**

```systemverilog
VX_fifo_queue #(
    .DATAW   (DATAW),
    .DEPTH   (SIZE),
    .OUT_REG (OUT_REG == 1),
    .LUTRAM  (LUTRAM)
) fifo_queue (...);

VX_pipe_buffer #(
    .DATAW (DATAW),
    .DEPTH ((OUT_REG > 1) ? (OUT_REG-1) : 0)
) out_buf (...);
```

#### LUTRAM = 0 (일반 FIFO)
```
Input → [N-Entry FIFO] → [Pipeline Stages] → Output
        (플립플롭 기반)   (OUT_REG-1 stages)
```

#### LUTRAM = 1 (LUTRAM 기반 FIFO)
```
Input → [N-Entry FIFO] → [Pipeline Stages] → Output
        (LUTRAM 기반)     (OUT_REG-1 stages)
```

**특징:**
- ✅ 큰 버퍼 용량 (SIZE entries)
- ✅ LUTRAM 옵션으로 면적 효율 향상
- ✅ OUT_REG로 출력단 파이프라인 조절
- 💾 리소스:
  - LUTRAM=0: `SIZE * DATAW` 플립플롭
  - LUTRAM=1: `SIZE * DATAW` LUTRAM + 제어 로직

**사용 시나리오:**
- 긴 버스트 트래픽
- 소스-싱크 간 처리 속도 차이가 클 때
- 큰 버퍼가 필요하지만 플립플롭 절약이 필요할 때 (LUTRAM)

---

## 📊 OUT_REG 값에 따른 비교표

| OUT_REG | SIZE | REG_DEPTH | 구조 | 레이턴시 | 버퍼 Depth | FF 사용량 | 타이밍 |
|---------|------|-----------|------|----------|------------|-----------|--------|
| 0       | 0    | 0         | Passthru | 0 | 0 | 0 | ❌ Poor |
| 1       | 1    | 1         | Pipe | 1 | 0 | 1x | ⚠️ Medium |
| 2       | 2    | 0         | Stream | 0~2 | 2 | 2x | ✅ Good |
| 3       | 2    | 1         | Stream+Pipe | 1~3 | 2 | 3x | ✅ Good |
| 4       | 2    | 2         | Stream+Pipe | 2~4 | 2 | 4x | ✅✅ Better |
| 5       | 2    | 3         | Stream+Pipe | 3~5 | 2 | 5x | ✅✅ Better |
| ≥3      | ≥3   | variable  | FIFO+Pipe | var | N | Nx+REG | ✅ Good |
| +8      | 2    | variable  | LUTRAM FIFO | var | N | LUTRAM | ✅ Good |

**범례:**
- FF 사용량: `x = DATAW` (데이터 폭)
- 레이턴시: 최소~최대 사이클

---

## 💡 사용 예시 (VX_mem_data_adapter)

```systemverilog
VX_elastic_buffer #(
    .DATAW    (1 + DST_DATA_SIZE + DST_ADDR_WIDTH + DST_DATA_WIDTH + DST_TAG_WIDTH),
    .SIZE     (`TO_OUT_BUF_SIZE(REQ_OUT_BUF)),    // 0, 1, or 2
    .OUT_REG  (`TO_OUT_BUF_REG(REQ_OUT_BUF))      // 0~5+
) req_out_buf (...);
```

### REQ_OUT_BUF = 0
```
SIZE = 0, OUT_REG = 0
→ 완전 pass-through
```

### REQ_OUT_BUF = 1
```
SIZE = 1, OUT_REG = 1
→ 1-stage pipeline register
```

### REQ_OUT_BUF = 2
```
SIZE = 2, OUT_REG = 0
→ 2-entry stream buffer, 출력 레지스터 없음
```

### REQ_OUT_BUF = 3
```
SIZE = 2, OUT_REG = 1
→ 2-entry stream buffer + 1-stage output register
```

### REQ_OUT_BUF = 4
```
SIZE = 2, OUT_REG = 2
→ 2-entry stream buffer + 2-stage output pipeline
```

---

## 🎯 설계 가이드라인

### 1. **Combinational Path가 긴 경우**
```systemverilog
OUT_REG = 1  // 최소 1-stage register로 경로 차단
```

### 2. **짧은 버스트 트래픽 처리**
```systemverilog
OUT_REG = 2  // 2-entry FIFO로 충분
```

### 3. **출력단 타이밍이 critical**
```systemverilog
OUT_REG = 3~5  // 2-entry FIFO + 추가 파이프라인 레지스터
```

### 4. **긴 버스트, 큰 버퍼 필요**
```systemverilog
SIZE = 큰 값 (4, 8, 16...)
OUT_REG = 필요한 출력 파이프라인 단수 + 2
```

### 5. **면적 최적화 (큰 버퍼)**
```systemverilog
SIZE = 큰 값
OUT_REG = 필요값 + 8  // bit3=1로 LUTRAM 활성화
```

---

## 🔍 주요 트레이드오프

### 레이턴시 vs 타이밍
- **OUT_REG ↑** → 레이턴시 ↑, 타이밍 ✅
- **OUT_REG ↓** → 레이턴시 ↓, 타이밍 ❌

### 버퍼 크기 vs 면적
- **SIZE ↑** → 버퍼링 ↑, 플립플롭 ↑
- **LUTRAM=1** → 면적 효율 ↑, 추가 로직 ↑

### 처리량 vs 리소스
- **2-entry FIFO (SIZE=2)**: 작은 면적, 짧은 버스트
- **N-entry FIFO (SIZE>2)**: 큰 면적, 긴 버스트

---

## 📐 공식 요약

```c
// OUT_REG 값 분해
LUTRAM_FLAG  = (OUT_REG & 8) != 0
CONFIG_VALUE = OUT_REG & 7

// 실제 버퍼 설정
SIZE = MIN(CONFIG_VALUE, 2)
REG_DEPTH = (CONFIG_VALUE < 2) ? CONFIG_VALUE : (CONFIG_VALUE - 2)

// 총 레지스터 단수 (FIFO 제외)
Total_Pipeline_Stages = REG_DEPTH

// 최대 레이턴시
Max_Latency = SIZE + REG_DEPTH
```

---

## 🛠️ 디버깅 팁

### OUT_REG 값 확인하기
```systemverilog
// 컴파일 타임 체크
localparam CHECK_SIZE = `TO_OUT_BUF_SIZE(REQ_OUT_BUF);
localparam CHECK_REG  = `TO_OUT_BUF_REG(REQ_OUT_BUF);

initial begin
    $display("OUT_REG=%0d → SIZE=%0d, REG=%0d", 
             REQ_OUT_BUF, CHECK_SIZE, CHECK_REG);
end
```

### 레이턴시 측정
```systemverilog
// 시뮬레이션에서 확인
initial begin
    @(posedge clk);
    valid_in = 1;
    @(posedge clk);
    valid_in = 0;
    // valid_out이 언제 1이 되는지 측정
end
```

### 버퍼 오버플로우 체크
```systemverilog
// SIZE가 충분한지 확인
// 연속 valid_in이 SIZE를 초과하면 ready_in이 0이 됨
assert property (@(posedge clk) 
    disable iff (reset)
    $rose(~ready_in) |-> $past(valid_in, SIZE)
);
```

---

## 결론

**OUT_REG 선택 원칙:**

1. **타이밍만 개선**: `OUT_REG = 1` (1-stage register)
2. **작은 버퍼 필요**: `OUT_REG = 2` (2-entry FIFO)
3. **타이밍 + 작은 버퍼**: `OUT_REG = 3~5` (FIFO + pipeline)
4. **큰 버퍼 필요**: `SIZE 파라미터 증가` + `OUT_REG = 원하는 출력 단수 + 2`
5. **면적 최적화**: `OUT_REG에 +8` (LUTRAM 활성화)

핵심은 **레이턴시, 처리량, 타이밍, 면적 간의 균형**을 맞추는 것입니다!
