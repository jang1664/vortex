# GEMM Unit cmd-level Pipelining

목표: VX_gemm_unit이 cmd당 50+ cycle 직렬화하는 구조를 끊고 back-to-back cmd issue가
가능한 pipelined 구조로 전환. 특히 M=1 GEMV에서 cmd당 67 cyc → ~1 cyc throughput.

## 1. 동기 (Why)

### 측정 결과 (`-m 1 -k 1024 -n 1024` GEMV, FSDB 분석 기반)

- Total sim: 82,053 cyc (821 μs @ 100 MHz)
- GEMM-active window: 71,606 cyc (87%)
- 1024 GEMM cmd × inter-start 67 cyc/cmd ≈ 68,608 cyc
- MXU MAC active: 1 cyc/cmd × 1024 cmd = 1024 cyc → 실효 MXU utilization ≈ **1.5%**
- 나머지 ~98%는 pipeline drain 대기

### Per-cmd 56 cycle latency 분해 (input/GEMM child fire → done)

| 구간 | 사이클 | 설명 |
|---|---|---|
| cmd_start → input @ GEMM unit | 9 | TMEM → GEMM unit input fetch |
| input → MXU input_valid_i | 3 | prealigner |
| MXU input → MXU output emerge | 30 | systolic column propagation (MXU_COL=32) + adder tree |
| post-MXU pipe | 8 | merger, int2fp, scaler, accumulator |
| acc-stage → gemm_done | 6 | acc mem write + done handshake |

**핵심 원인**: 50+ cyc pipeline latency가 cmd마다 노출. 다음 cmd는 이전 cmd의 acc mem write 끝까지 대기.

## 2. 현재 구조 (As-Is)

### VX_gemm_unit.sv의 단일 cmd 모델

```
gemm_unit_if.start ──→ [Main FSM IDLE→COMPUTE] ──→ in_flight=1
                              │ next_gemm_unit_ctrl latch
                              ▼
                  ┌──────────────────────────────┐
                  │ gemm_unit_ctrl (1 reg only)  │ ← 모든 cmd가 통째로 들어감
                  │  acc_mem_base_addr           │
                  │  acc_cnt                     │
                  │  is_load                     │
                  │  quant_dir                   │
                  │  wreg/sreg/zreg_use_idx      │
                  └────┬─────────┬──────┬────────┘
                       │         │      │
                       ▼         ▼      ▼
                 input 단    중간    acc 단(가장 늦음)
                 (wreg sel)  (qdir)  (is_load, acc_addr)

gemm_done = ACCUM_WR_WRITE → IDLE 천이 (acc mem 마지막 write 후)
gemm_idle = Main FSM IDLE && acc rd FSM IDLE && acc wr FSM IDLE
in_flight = (Main FSM == COMPUTE)
```

핵심 코드 위치:
- Main FSM: `VX_gemm_unit.sv:451-478`
- `gemm_unit_ctrl` reg: `:118, 444-446`
- `acc_mem_accum_wr_addr` (acc 단 카운터): `:569-578`
- `acc_mem_accum_rd_addr` (prefetch 카운터): `:504-514`
- `gemm_done`: `:429-430`
- `in_flight`: `:452`
- bus.req_ready 게이팅 (in_flight 의존): `:384, 397-405, 408`

### Cmd 발행 경로 (FSM → Unit)

```
VX_gemm_fsm (cmd 생성)
   ↓ gemm_fsm_if (start + cmd payload)
VX_gemm_ctrl (parent FIFO + sync demux + child FIFOs[5])
   ↓ gemm_ctrl_if.{input_read, weight_read, quant_param_read, output_write, dma}_ctrl
VX_gemm_node (glue)
   ↓ gemm_unit_if (input_read 경로) → VX_gemm_unit
   ↓ weight/sz/output DMA control → VX_tmem_subsystem (LDMAs)

cmd_idle (FSM 측에서 본 idle) = gemm_unit_if.idle  (line 200 in gemm_node.sv)
cmd_done                     = gemm_unit_if.done   (line 201)
```

→ `gemm_unit_if.idle`/`done` 가 늦게 뜨면 FSM이 다음 cmd 못 발행. 이게 진짜 직렬화 원인.

## 3. 목표 구조 (To-Be)

```
gemm_unit_if.start ─→ ┌───────────────────────────┐
                      │ Input-stage CMD ctrl (NEW)│  매 input cycle마다 tag 발행
                      └─┬─────────────────────────┘
                        │
   ifmap data ─→ [prealign/preproc/MXU/post-pipe] ─→ acc-stage
                        │
   tag pipeline (data와 같은 depth)──→ acc-stage에서 acc_mem_addr/is_load 등 사용

gemm_done ← 마지막 input이 input-stage handshake 통과한 사이클 (input stage strobe)
in_flight ← OR(pipe stage valid signals)  ── output bus.req_ready 게이팅 전용
gemm_idle ← input-stage가 다음 cmd 받을 수 있는지 (각 hazard 게이트 종합)
```

Tag 내용 (cmd 단위로 input stage에서 발행, 데이터와 함께 pipeline됨):
```
{ acc_mem_addr,    // 매 input cycle stride 증가
  is_load,
  quant_dir,
  wreg_use_idx,
  sreg_use_idx,
  zreg_use_idx,
  is_last_of_cmd,  // gemm_done strobe용
  cmd_id           // debug
}
```

## 4. 결정 사항 (Resolved)

### R1. `gemm_done` 시점 변경
- 기존: acc mem 마지막 write 후 (line 429)
- 신규: cmd의 **마지막 input이 input-stage handshake 통과한 사이클**
- 결과: cmd_done이 50+ cyc 일찍 fire → 다음 cmd 즉시 issue 가능

### R2. ACC RAW hazard → forwarding network
- 같은 `acc_mem_addr`로 들어가는 같은-N-tile K-tile cmd들(특히 GEMV에서 K=1024 / MXU_ROW=32 = 32 cmd)이 acc_mem RMW로 직렬화되는 문제
- 해결: acc-stage 직전에 tag pipeline 스캔, in-flight write와 addr 충돌 시 acc_mem read 대신 in-flight write 데이터 bypass
- **K-running accumulator register 방식은 기각**: GEMM (M > 1) 케이스에서 MT × MXU_NT 만큼의 reg 필요 → 비현실적
- HW 비용: tag stage 각각에서 acc_mem_addr 비교 comparator + FP32 × MXU_NT 폭 forwarding mux. 비교 stage 수는 acc-stage 도착 직전 N개로 한정 가능.

### R3. Output read backpressure → pipe valid OR-tree
- `o_lmem_bus_if.req_ready` 게이팅에 쓰던 `in_flight`를 재정의:
  ```
  in_flight = | { prealigner_in_valid, prealigner_out_valid, prealigner_pipe_out_valid,
                  pre_proc_in_valid, pre_proc_out_valid,
                  |mxu_output_valid, |mxu_output_valid_dly,
                  merger_in_valid, merger_out_valid,
                  |int2fp_output_valid, |scaler_output_valid, final_scaler_output_valid,
                  |acc_in_data_valid, |acc_output_valid }
  ```
- output read는 빈번하지 않으므로 in_flight=1인 동안만 stall로 충분

### R4. Psum prefetch FSM 앞에 descriptor FIFO 추가
- 기존 prefetch FSM은 거의 그대로 유지 (line 480-562)
- 변경: prefetch FSM의 trigger를 `gemm_unit_if.start` 대신 `desc_fifo.pop`으로
- 새 cmd가 input stage에서 처리될 때 `is_load=0`이면 `{acc_mem_base_addr, acc_cnt, cmd_id}`를 desc FIFO에 enqueue
- desc FIFO full이면 input stage stall
- 깊이 4-8 정도 예상 (prefetch latency 짧음)
- 기존 `acc_rd_fifo` (psum data FIFO)는 그대로 작동, ordering 자연히 매치

### R5. Bus ready 게이팅 분리
- 기존: 모든 bus가 `in_flight`에 묶여있음 (`:384, 397, 408`)
- 신규: 자원별 분리
  - output bus: R3의 새 `in_flight` (OR-tree)
  - weight bus: weight buffer 충돌 인터록 (Problem #1 참조)
  - sz bus: scale/zp reg 충돌 인터록
  - input bus: input-stage가 새 cmd 받을 준비됐는지

## 5. 미해결 문제 (Open)

### P1. Ping-pong weight buffer 충돌 ⚠️ 현재 가장 곤란

#### 문제 정의 (요점)

- MXU는 **weight-stationary systolic** 구조: weight는 propagation 동안 "안 움직임"이지만, ifmap이 32개 column을 1 cyc씩 순차 통과하면서 매 cycle 해당 column 위치의 weight를 read해서 MAC
- 즉 한 cmd의 ifmap이 input stage에 진입한 시점 `T`부터 `T+31`까지 (총 32 cyc) **buffer `b`는 column-by-column으로 read in use**
- 그 32 cyc 동안 같은 buffer `b`에 새 weight를 write하면 column 도중부터 잘못된 weight 사용 → silent corruption
- ↳ **이건 LDMA write rate를 아무리 빨리 해도 dependency 자체로 인해 회피 불가**

#### 현재 인터록 (line 384)
```
w_lmem_bus_if.req_ready = ~in_flight | (gemm_unit_ctrl.wreg_use_idx != w_lmem_bus_if.req_data.addr[0]);
```
→ 단일 cmd 모델 가정. pipelined cmd에서 무효.

#### Pipelined cmd 발행 시 충돌 시나리오

GEMV M=1, K=1024, N=1024 케이스 (각 K-tile cmd마다 다른 weight 필요):

```
T=0  cmd0 ifmap 진입, wreg=0   → buffer0 read window T=0..31
T=1  cmd1 ifmap 진입, wreg=1   → buffer1 read window T=1..32
T=2  cmd2 ifmap 진입, wreg=0?  → buffer0 read window 충돌! T=0..31와 겹침
```

cmd2가 buffer0을 쓰려면 cmd0 read window 종료 후(T≥32)에 PE 진입 가능. 그 사이 buffer0
재로드(LDMA write)도 끝나있어야 함. LDMA write 자체는 read window가 끝난 직후(T=32) 시작 가능.

#### Throughput 모델 (dependency-bound)

핵심 식 — `VX_gemm_unit.sv:56`의 `MXU_OUT_DLY` 정의에서 column pipeline 부분:

```
D = MXU_COL / MXU_COL_TILE     (column propagation 깊이)
```

`B` = u_weight_regs buffer 수, `W` = LDMA write 1회 시간 = 14 cyc (wonce) / 19 cyc (w4):

- 같은 buffer 재사용 간격 ≥ `D + W` (read window + 새 write)
- `B` 개 buffer round-robin → cmd 간격 ≥ `max(1, (D + W) / B)` = `max(1, (MXU_COL/TILE_COL + W) / B)`

**이론치 (1 cmd/cyc) 달성 조건:**
```
W ≈ 0 인 경우:    B × MXU_COL_TILE ≥ MXU_COL (= 32)
W > 0 인 경우:    B ≥ MXU_COL/MXU_COL_TILE + W
```

#### (B, TILE_COL) 조합 trade-off (W ≈ 0 가정)

같은 throughput을 다양한 면적 trade-off로 달성 가능:

| B | TILE_COL | D | weight reg 메모리 | PE adder tree | first-output latency |
|---|---|---|---|---|---|
| 32 | 1 | 32 | 32× | 1× (현재) | 32 cyc |
| 8 | 4 | 8 | 8× | 4× | 8 cyc |
| 4 | 8 | 4 | 4× | 8× | 4 cyc |
| 2 | 16 | 2 | 2× (현재) | 16× | 2 cyc |
| 1 | 32 | 1 | 1× | 32× (fully parallel) | 1 cyc |

- weight reg 메모리 1× = 0.5 KB (32×32×4b)
- 모두 GEMV 이론치 ≈ 1024 cmd × 1 cyc + final drain 도착
- 현재 (B=2, TILE_COL=1)은 16x 부족 → 23 cyc/cmd

#### W > 0 보정

LDMA write 시간 W 가 무시 못할 때, TILE_COL 키울수록 buffer 더 필요 (cmd가 빨라지지만 LDMA write는 그대로). 예 (W=14):

| TILE_COL | 필요 B | B × TILE_COL |
|---|---|---|
| 1 | 46 | 46 |
| 4 | 22 | 88 |
| 8 | 18 | 144 |
| 16 | 16 | 256 |
| 32 | 15 | 480 |

→ **LDMA write 단축 (W↓) 도 병행해야 TILE_COL 증가가 효과적**.

#### 현재 (B=2, TILE_COL=1) 기준 점진 개선 시뮬레이션 (W=14 기준)

| B | TILE_COL | cmd 간격 | GEMV cyc | 현재 대비 |
|---|---|---|---|---|
| 2 | 1 | 23 | 23,552 | 1× |
| 4 | 1 | 11.5 | 11,776 | 2× |
| 8 | 1 | 5.75 | 5,888 | 4× |
| 4 | 4 | (8+14)/4=5.5 | 5,632 | 4.2× |
| 8 | 4 | (8+14)/8=2.75 | 2,816 | 8.4× |
| 4 | 8 | (4+14)/4=4.5 | 4,608 | 5.1× |
| 8 | 8 | (4+14)/8=2.25 | 2,304 | 10.2× |
| 16 | 8 | (4+14)/16=1.125 | 1,152 | 20.4× |
| 32 | 1 | (32+14)/32=1.4 | 1,440 | 16.4× |

(W 단축이 같이 되면 위 수치들 더 좋아짐)

#### HW 비용 (buffer 수 증가)

1 buffer = MXU_ROW × MXU_COL × W_BIT_WIDTH = 32 × 32 × 4 = 4096 bits = 512 B
- B=2 (현재): 1 KB (128 LUT-FF 등가 정도. 실제로는 reg array이므로 8192 FF)
- B=8: 4 KB (32K FF)
- B=16: 8 KB (64K FF)
- B=32: 16 KB (128K FF)

비용은 buffer 수에 선형. MXU PE array 자체 (32×32 PE × 곱셈기/덧셈기)보다 weight reg 면적이 더 클 수 있어 면적 영향 큼. 단 reg → BRAM/URAM 매핑 (FPGA) 또는 dense SRAM (ASIC) 으로 면적 감소 가능.

#### 추가 옵션: Follow-the-wave write (실험적)

- LDMA write가 read와 같은 column 순서로 따라가는 형태
- cmd0 ifmap이 column k에 있을 때, cmd0의 buffer는 column 0..k가 이미 read 완료 → buffer 의 column 0..k 영역에 새 weight write 안전
- 즉 32 cyc propagation 중에 buffer의 "이미 읽힌 column" 영역은 in-place로 새 cmd weight으로 덮어쓸 수 있음
- 효과: 32 cyc read window를 그대로 사용하면서, write도 32 cyc에 분산 (1 column/cyc write) → buffer 1개로 column-wise pipelined 사용 가능 (이론상 cmd 간격 ≥ 1 cyc)
- 비용: weight LDMA path에 column-by-column write 지원 추가, 시퀀스 보장 메커니즘. 데이터 path 큰 변경
- 단순 buffer 수 증가보다 복잡, 하지만 면적 효율 좋음

#### 시도된 아이디어 정리

| 옵션 | 효과 (GEMV cyc) | HW 비용 | 평가 |
|---|---|---|---|
| 1. MAX_IN_FLIGHT=2 단순 stall | ~23,000 | 매우 작음 | GEMV 성능 회복 부족 |
| 2. Buffer 수 증가 (2→8) | ~5,900 | 중간 (4KB regs) | 가성비 양호. **유력 후보** |
| 2. Buffer 수 증가 (2→16) | ~2,950 | 중대 (8KB regs) | 면적 추가, 이론치 근접. 후보 |
| 3. PE-internal stationary | (이미 그러함) | - | 효과 없음 (read window 32 cyc 그대로) |
| 4. Follow-the-wave write | ~1,100 (이론) | 큼 | 가능성 있지만 RTL 변경 큼 |
| 5. LDMA write 단축 단독 | buffer 적으면 효과 한계 | 중 | 보조 수단 (옵션 2와 조합) |

#### 미정 / 다음 분석

1. 현재 RTL의 u_weight_regs 정확한 buffer 구조 확인 (`VX_gemm_weight_regs_v1.sv` / `_v2.sv`)
   - `MXU_WLOAD_NUM` 차원이 무엇인지: ping-pong 외 추가 분할 차원 가능성
2. Buffer 수 4 또는 8로 늘릴 때 RTL 변경 범위 추정
   - `wreg_use_idx` 폭을 1-bit → log2(B)로 확장
   - `u_weight_regs` 내부 array depth 확장
   - Weight LDMA의 `addr[0]` (현재 idx) → 더 넓은 idx 필드
   - 합성/timing 영향 (MXU 주변 fanout 증가)
3. Option 4 (follow-the-wave) 의 RTL 변경 비용 추정 — 후순위

## 6. 제약 / 가정

- RTL 변경 범위: `VX_gemm_unit.sv`, `VX_gemm_unit_if.sv`, `VX_gemm_node.sv`, 필요 시 `VX_gemm_fsm.sv` (cmd struct에 flag 추가)
- 변경 불가: kernel, runtime, sim infra, testbench (CLAUDE.md 메모리 규칙)
- 타겟 케이스: -m 1 -k 1024 -n 1024 GEMV, 그리고 더 큰 M (M ≥ 32) GEMM도 망가지면 안 됨
- 합성 가능 (Vivado 100 MHz 마진 유지) — 너무 큰 forwarding mux는 timing closure 위험

## 7. 측정 인프라 (이미 추가됨)

`VX_gemm_fsm.sv`, `VX_gemm_ctrl.sv`, `VX_gemm_node.sv`에 `\`ifndef SYNTHESIS` 안에서 추가된
debug 신호들:

- `dbg_issue_pulse / _id_q / _cyc / _op / _state` (FSM)
- `dbg_child_start / _done / _start_cyc_q / _done_cyc_q / _lat_q / _fire_count_q` (per child queue)
- `dbg_input_notify_fire / _weight_notify_fire / _sz_notify_fire / _output_notify_fire`
- `dbg_weight_dma_start`, `dbg_cyc_q` (free-running)

→ 새 RTL 변경 검증할 때 cmd-level latency 측정 그대로 재사용 가능.

## 8. 다음 단계

1. **P1 해결**: weight buffer 충돌. MXU 내부 weight 사용 패턴부터 분석 (옵션 3 검증)
2. P1 해결 후: 전체 설계 문서화 (tag 폭, depth, forwarding mux 구조, hazard interlock 정확한 위치)
3. RTL 변경 → simv 컴파일 통과 → 같은 GEMV 케이스 재실행 → cmd-level perf 확인

## 9. 변경 이력

- 2026-05-14: 최초 작성 (R1-R5 결정, P1 open).
- 2026-05-14: P1 정정 — weight stationary가 read window를 줄이지 않음. Throughput 모델을 buffer 수 / LDMA write 시간 함수로 정리. 유력 후보: buffer 수 증가 (2→8 또는 16). 보조: follow-the-wave write.
- 2026-05-14: D = MXU_COL/MXU_COL_TILE 식 추가. 이론치 매칭 조건 `B × MXU_COL_TILE ≥ MXU_COL` 정리. (B, TILE_COL) 조합별 면적 trade-off 표 추가.
