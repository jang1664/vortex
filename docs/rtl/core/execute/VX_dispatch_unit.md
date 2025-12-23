# `core/VX_dispatch_unit.sv` — Dispatch Unit

## 개요

Issue Stage에서 전달된 명령어 패킷을 실행 유닛(ALU, LSU, SFU, FPU, TCU)으로 분배하는 모듈.
큰 SIMD 패킷을 실행 유닛의 레인 수에 맞게 분할하고, 여러 issue slot의 요청을 중재한다.

## 파이프라인 위치

```
Schedule → Fetch → Decode → Issue → [DISPATCH] → Execute Units → Commit
                              ↓
                      VX_dispatch_unit
                              ↓
                    ┌─────────┴─────────┐
                    ↓         ↓         ↓
                   ALU       LSU       SFU ...
```

## 모듈 파라미터

| 파라미터 | 설명 |
|----------|------|
| `BLOCK_SIZE` | 실행 유닛의 인스턴스 수 (예: `NUM_ALU_BLOCKS`) |
| `NUM_LANES` | 실행 유닛당 레인 수 (예: `NUM_ALU_LANES`) |
| `OUT_BUF` | 출력 버퍼 타입 |

---

## NUM_THREADS vs SIMD_WIDTH vs NUM_LANES

### 왜 3단계로 나누는가?

기본값으로는 모두 같지만, 독립적으로 설정할 수 있다:

```systemverilog
// VX_config.vh 기본값
`define NUM_THREADS     4                    // warp당 전체 스레드 수
`define SIMD_WIDTH      `NUM_THREADS         // 기본: NUM_THREADS와 동일
`define NUM_ALU_LANES   `SIMD_WIDTH          // 기본: SIMD_WIDTH와 동일
`define NUM_FPU_LANES   `SIMD_WIDTH          // 기본: SIMD_WIDTH와 동일
`define NUM_LSU_LANES   `SIMD_WIDTH          // 기본: SIMD_WIDTH와 동일
```

### 각 파라미터의 역할

| 파라미터 | 의미 | 설정 기준 |
|----------|------|----------|
| `NUM_THREADS` | Warp당 논리적 스레드 수 | **프로그래밍 모델** - SW가 보는 warp 크기 |
| `SIMD_WIDTH` | Issue 단위 스레드 수 | **Issue 대역폭** - 한 번에 발행하는 스레드 수 |
| `NUM_*_LANES` | 실행 유닛 폭 | **하드웨어 비용** - 실제 ALU/FPU 개수 |

### 분리의 장점

```
NUM_THREADS=32 (SW 관점: 32-thread warp)
       │
       ▼
SIMD_WIDTH=16 (Issue 관점: 16 스레드씩 2번 발행)
       │
       ▼
NUM_ALU_LANES=4 (HW 관점: 4 ALU로 4 사이클에 처리)
```

**실제 사용 예시** (ci/regression.sh.in):
```bash
# SIMD_WIDTH만 줄여서 테스트
CONFIGS="-DSIMD_WIDTH=1" ./ci/blackbox.sh --app=dogfood
CONFIGS="-DSIMD_WIDTH=2" ./ci/blackbox.sh --app=dogfood

# 실행 유닛 레인만 줄여서 테스트 (면적/전력 절약)
CONFIGS="-DNUM_ALU_LANES=2" ./ci/blackbox.sh --app=diverge
CONFIGS="-DNUM_FPU_LANES=2" ./ci/blackbox.sh --app=vecadd
CONFIGS="-DNUM_LSU_LANES=2" ./ci/blackbox.sh --app=vecadd
```

**장점**:
1. **면적 절약**: FPU는 비싸므로 `NUM_FPU_LANES=2`로 줄임
2. **전력 절약**: 저전력 모드에서 레인 수 감소
3. **유연성**: 워크로드 특성에 맞게 튜닝 가능

### 계층 구조

```
NUM_THREADS = 32 (전체 스레드)
├── SIMD 그룹 0 (sid=0): 스레드 0~15
│   ├── 패킷 0: 스레드 0~3
│   ├── 패킷 1: 스레드 4~7
│   ├── 패킷 2: 스레드 8~11
│   └── 패킷 3: 스레드 12~15
└── SIMD 그룹 1 (sid=1): 스레드 16~31
    ├── 패킷 4: 스레드 16~19
    ├── 패킷 5: 스레드 20~23
    ├── 패킷 6: 스레드 24~27
    └── 패킷 7: 스레드 28~31

SIMD_COUNT = NUM_THREADS / SIMD_WIDTH = 32/16 = 2
NUM_PACKETS = SIMD_WIDTH / NUM_LANES = 16/4 = 4
총 패킷 수 = NUM_THREADS / NUM_LANES = 32/4 = 8
```

---

## 핵심 구조: 패킷 분할

### 문제 상황

```
Issue Stage 출력: SIMD_WIDTH = 16 threads
ALU Unit 입력:    NUM_ALU_LANES = 4 lanes
```

16개 스레드를 한 번에 처리할 수 없으므로 4개씩 4번에 나눠서 전달해야 함.

### 해결 방법: Batch 분할

```
NUM_PACKETS = SIMD_WIDTH / NUM_LANES  (예: 16/4 = 4 packets)

원본 SIMD 그룹 (16 threads):
┌────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┐
│ T0 │ T1 │ T2 │ T3 │ T4 │ T5 │ T6 │ T7 │ T8 │ T9 │T10 │T11 │T12 │T13 │T14 │T15 │
└────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘
                                    ↓
분할된 패킷 (4 lanes × 4 packets):
Pkt 0: ┌────┬────┬────┬────┐
       │ T0 │ T1 │ T2 │ T3 │  ← sop=1 (Start of Packet)
       └────┴────┴────┴────┘
Pkt 1: ┌────┬────┬────┬────┐
       │ T4 │ T5 │ T6 │ T7 │
       └────┴────┴────┴────┘
Pkt 2: ┌────┬────┬────┬────┐
       │ T8 │ T9 │T10 │T11 │
       └────┴────┴────┴────┘
Pkt 3: ┌────┬────┬────┬────┐
       │T12 │T13 │T14 │T15 │  ← eop=1 (End of Packet)
       └────┴────┴────┴────┘
```

---

## warp_pid 계산

### 관련 상수

```systemverilog
localparam NUM_PACKETS  = `SIMD_WIDTH / NUM_LANES;      // SIMD당 패킷 수
localparam GPID_BITS    = `CLOG2(`NUM_THREADS / NUM_LANES); // 전체 패킷 인덱스 비트
```

### 계산 공식

```systemverilog
wire [GPID_WIDTH-1:0] warp_pid = GPID_WIDTH'(block_pid[block_idx])
                                + GPID_WIDTH'(dispatch_sid * NUM_PACKETS);
```

### 의미

- `block_pid`: SIMD 그룹 **내**에서의 패킷 인덱스 (0 ~ NUM_PACKETS-1)
- `dispatch_sid`: SIMD 그룹 인덱스 (0 ~ SIMD_COUNT-1)
- `dispatch_sid * NUM_PACKETS`: SIMD 그룹 시작 오프셋
- `warp_pid`: Warp **전체**에서의 고유 패킷 인덱스 (0 ~ NUM_THREADS/NUM_LANES-1)

### 예시 (NUM_THREADS=32, SIMD_WIDTH=16, NUM_LANES=4)

```
SIMD_COUNT = 2, NUM_PACKETS = 4

Warp 내 스레드 배치:
┌─────────────────────────────────────────────────────────────────┐
│                        NUM_THREADS = 32                          │
├─────────────────────────────────┬───────────────────────────────┤
│   SIMD 그룹 0 (sid=0)           │   SIMD 그룹 1 (sid=1)         │
│   SIMD_WIDTH = 16               │   SIMD_WIDTH = 16             │
├────────┬────────┬────────┬──────┼────────┬────────┬────────┬────┤
│Pkt 0   │Pkt 1   │Pkt 2   │Pkt 3 │Pkt 4   │Pkt 5   │Pkt 6   │Pkt 7│
│T0-T3   │T4-T7   │T8-T11  │T12-15│T16-T19 │T20-T23 │T24-T27 │T28-31│
└────────┴────────┴────────┴──────┴────────┴────────┴────────┴────┘
  ↑                                 ↑
  block_pid = 0~3                   block_pid = 0~3
  dispatch_sid = 0                  dispatch_sid = 1
```

**warp_pid 계산 예시**:
```
dispatch_sid=0, block_pid=2:
  warp_pid = 2 + (0 × 4) = 2    → 패킷 2 (T8-T11)

dispatch_sid=1, block_pid=2:
  warp_pid = 2 + (1 × 4) = 6    → 패킷 6 (T24-T27)
```

### 시각화

```
                    ┌──────────────────────────────────────┐
                    │            warp_pid 공간             │
                    │    (0 ~ NUM_THREADS/NUM_LANES-1)     │
                    └──────────────────────────────────────┘
                             ↑
    warp_pid = block_pid + dispatch_sid × NUM_PACKETS
                    │                    │
         ┌──────────┴──────────┐  ┌──────┴──────┐
         │  SIMD 그룹 내 오프셋  │  │ 그룹 시작점  │
         │    (block_pid)      │  │ (sid×PKT)   │
         └─────────────────────┘  └─────────────┘
```

### 용도

실행 유닛은 `warp_pid`를 사용해 warp 내 정확한 스레드 위치를 계산:
- 레지스터 파일 접근: `thread_offset = warp_pid * NUM_LANES`
- 결과 저장 위치 결정
- 디버깅/트레이싱

---

## 주요 로직

### 1. Non-Zero Iterator

모든 스레드가 비활성화된 패킷은 건너뛴다:

```systemverilog
VX_nz_iterator #(
    .DATAW   ($bits(packet_t)),
    .KEYW    (NUM_LANES),
    .N       (NUM_PACKETS)
) packet_iter (
    .clk     (clk),
    .reset   (reset),
    .valid_in(dispatch_valid[issue_idx]),
    .data_in (packets),
    .next    (fire_p),
    .valid_out(valid_p),
    .data_out(block_packet),
    .pid     (start_p),      // → block_pid
    .sop     (is_first_p),
    .eop     (is_last_p)
);
```

예시:
```
packet_masks = 4'b1101  (패킷 1은 모든 스레드 비활성)
               ↓
순회 순서: 0 → 2 → 3 (패킷 1 건너뜀)
```

### 2. SOP/EOP 플래그

```systemverilog
// warp 전체 관점의 SOP/EOP
wire warp_sop = block_sop[block_idx] && dispatch_sop;
wire warp_eop = block_eop[block_idx] && dispatch_eop;
```

- `block_sop/eop`: SIMD 그룹 내 첫/마지막 패킷
- `dispatch_sop/eop`: warp 내 첫/마지막 SIMD 그룹
- `warp_sop/eop`: warp 전체에서 첫/마지막 패킷

| 조합 | 의미 |
|------|------|
| `warp_sop=1` | Scoreboard에 새 명령어 등록 |
| `warp_eop=1` | Commit 카운터 증가 |

### 3. WIS → WID 변환

```systemverilog
wire [NW_WIDTH-1:0] block_wid = wis_to_wid(dispatch_wis, isw);
```

| WIS (Warp Issue Slot) | WID (Warp ID) |
|-----------------------|---------------|
| 스케줄러 관점의 warp 식별자 | 실행 유닛 관점의 warp 식별자 |
| SIMD_WIDTH 단위 | NUM_LANES 단위 |

---

## 데이터 흐름

```
dispatch_if[ISSUE_WIDTH]
         │
         ▼
┌─────────────────────────────────────────────────────┐
│               VX_dispatch_unit                       │
│                                                     │
│  ┌───────────────┐    ┌───────────────┐            │
│  │ Packet Split  │───→│ NZ Iterator   │            │
│  │ (NUM_PACKETS) │    │ (skip empty)  │            │
│  └───────────────┘    └───────┬───────┘            │
│                               │                     │
│  ┌───────────────┐            ▼                     │
│  │ Issue Slot    │    ┌───────────────┐            │
│  │ Arbiter       │───→│ warp_pid Calc │            │
│  └───────────────┘    └───────┬───────┘            │
│                               │                     │
│                       ┌───────▼───────┐            │
│                       │ SOP/EOP Gen   │            │
│                       └───────┬───────┘            │
└───────────────────────────────┼─────────────────────┘
                                │
                                ▼
                    execute_if[BLOCK_SIZE]
```

---

## 인터페이스

### 입력

| 인터페이스 | 타입 | 설명 |
|-----------|------|------|
| `dispatch_if[ISSUE_WIDTH]` | `VX_dispatch_if.slave` | Issue Stage에서 명령어 수신 |

### 출력

| 인터페이스 | 타입 | 설명 |
|-----------|------|------|
| `execute_if[BLOCK_SIZE]` | `VX_execute_if.master` | 실행 유닛으로 명령어 전달 |

## 출력 데이터 구조

```systemverilog
execute_if.data = {
    uuid,           // 디버깅용 고유 ID
    block_wid,      // Warp ID (변환됨)
    block_tmask,    // Thread Mask (NUM_LANES 크기로 축소)
    op_type,        // 연산 타입
    op_args,        // 연산 인자
    wb,             // Writeback 필요 여부
    PC,             // Program Counter
    rd,             // 목적지 레지스터
    rs1_data,       // 소스 레지스터 1 데이터 (NUM_LANES 크기)
    rs2_data,       // 소스 레지스터 2 데이터 (NUM_LANES 크기)
    rs3_data,       // 소스 레지스터 3 데이터 (NUM_LANES 크기)
    warp_pid,       // Warp 내 패킷 ID (전역)
    warp_sop,       // Start of Packet (warp 전체)
    warp_eop        // End of Packet (warp 전체)
};
```

---

## 사용 예시

### VX_execute.sv에서의 인스턴스화

```systemverilog
VX_dispatch_unit #(
    .BLOCK_SIZE (`NUM_ALU_BLOCKS),
    .NUM_LANES  (`NUM_ALU_LANES),
    .OUT_BUF    (1)
) alu_dispatch (
    .clk         (clk),
    .reset       (reset),
    .dispatch_if (dispatch_if[`EX_ALU * `ISSUE_WIDTH +: `ISSUE_WIDTH]),
    .execute_if  (alu_execute_if)
);
```

---

## 관련 파일

- [VX_execute.sv](../../../../hw/rtl/core/VX_execute.sv) - 상위 모듈
- [VX_dispatch_if.sv](../../../../hw/rtl/interfaces/VX_dispatch_if.sv) - dispatch 인터페이스 정의
- [VX_execute_if.sv](../../../../hw/rtl/interfaces/VX_execute_if.sv) - execute 인터페이스 정의
- [VX_nz_iterator.sv](../../../../hw/rtl/libs/VX_nz_iterator.sv) - 비활성 패킷 스킵
- [VX_generic_arbiter.sv](../../../../hw/rtl/libs/VX_generic_arbiter.sv) - 중재 로직

---

## 성능 특성

- **레이턴시**: 출력 버퍼 설정에 따라 0~1 사이클
- **스루풋**:
  - 패킷 수(NUM_PACKETS)에 따라 한 SIMD 그룹 처리에 여러 사이클 소요
  - SIMD 그룹 수(SIMD_COUNT)에 따라 warp 처리에 추가 사이클 소요
- **최적화**:
  - 비활성 패킷 자동 스킵 (VX_nz_iterator)
  - Divergence가 심할수록 스킵되는 패킷이 많아 효율 향상
