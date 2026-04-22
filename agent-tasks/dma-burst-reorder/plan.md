# DMA Burst Reorder Elimination

## Context

`hw/rtl/mem/VX_dma_engine.sv`는 `VX_gemm_tmem_dma_ctrl`이 발행한 descriptor를 그대로 받아, upstream(`VX_dma_unit_misal`)이 HBM-logical 주소 순서로 던지는 16 bus-word (= 8 banks/ch의 HBM 물리 배치에서 bank-interleaved) 요청을 **engine 안에서 reorder** 한 뒤 AXI INCR burst 4개 × 4 beat로 발사한다. 이 reorder 때문에 채널당 다음 레지스터들이 flip-flop으로 합성되어 막대한 area를 차지한다:

- `burst_wr_window_data_r` [16×512b=8KB/ch] — FF (ram_style 없음)
- `burst_wr_window_byteen_r` [16×64b=1KB/ch] — FF
- `burst_window_data_r` [16×512b=8KB/ch] — `(* ram_style = "block" *)` 속성에도 **BRAM inference 실패**, FF로 남음 (사용자 확인)
- 부수 state: `burst_group_count_r`, `burst_group_base_addr_r`, `burst_group_tag_r`, 대응 write-side pair, `burst_window_valid_r` 등

8채널 전체로 환산하면 수십 KB FF. FSM도 `RD_BURST_CAPTURE/ACTIVE`, 5-state write FSM 등 과다 복잡.

**근본 원인**: ctrl이 내보내는 descriptor가 HBM-logical 공간에서 `stride=HBM_BUS_STRIDE(512)`로 linear하게 걸어서, 채널당 4개 HBM bank를 bank-interleaved 순서로 치게 됨. 같은 bank의 연속 beat를 한 burst로 묶으려면 16-word window를 전부 모아야 한다.

**해결**: ctrl이 descriptor 시점부터 bank × beat **2D loop** 순서로 발행한다. Upstream은 같은 bank의 4~N beat를 연속 발사하게 되고, engine은 reorder 없이 첫 beat의 remap 주소로 AR/AW 발사 + `len = BND0 - 1`만 찍으면 AXI INCR burst 하나가 완성된다. TMEM side는 address-based `mem_bus_if`라 순서 무관.

**목표 결과**:
- `burst_*_window_*_r`, `burst_*_group_*_r` 전원 제거 (채널당 ~17KB FF 절감 → 8채널 ~136KB FF)
- FSM 단순화 (채널당 한 자리 수 beat counter + small skid + rsp_tag FIFO)
- `fpint_gemm_ffn_hw_improve` 회귀 동일 결과, 기존 unit tests 동일 결과

## Scope & Assumptions

- **Interleave 전용** (`PLATFORM_MEMORY_INTERLEAVE=1`). Non-interleave 경로는 `VX_mem_remap.sv`가 identity bypass가 없어 이미 broken, 동일하게 `$fatal`로 가드만 추가.
- Kernel `cmd.bound` 항상 1 (현 `tests/regression/fpint_gemm_ffn_hw_improve/kernel.cpp` 전수 확인). `DMA_R_BND1`에 kernel bnd0를 전달하던 dead path는 **제거**. 향후 확장은 아래 문서로.
- 2D 형식만 지원. burst가 4KB(=64 beats)를 넘는 descriptor는 SVA로 `$fatal`. 3D 확장은 아래 문서로.

## Critical Files

- **수정**
  - `hw/rtl/mem/VX_dma_engine.sv` — reorder buffer 삭제, `BND0→burst_len` latch 기반 passthrough FSM으로 재작성
  - `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv` — ch별 descriptor를 2D (bank × beat) 형식으로 계산
  - `hw/rtl/VX_config.vh` — (선택) `NUM_HBM_BANKS_PER_CH` 매크로 추가
- **확인만 (변경 불필요)**
  - `hw/rtl/core/VX_dma_unit_misal.sv` — 이미 3D strided FSM, descriptor만 바뀌면 새 순서로 발행됨
  - `hw/rtl/core/VX_mem_remap.sv` — interleave 공식 검증 완료, 그대로 사용
  - `hw/rtl/mem/VX_tmem_subsystem.sv` — `VX_dma_engine`의 유일한 instantiator, 포트 시그니처 불변이면 수정 없음
- **신규**
  - `agent-tasks/dma-burst-reorder/STATUS.yaml` — FSM + pitfalls
  - `agent-tasks/dma-burst-reorder/extension-3d-when-burst-exceeds-4kb.md` — 3D 확장 및 bound>1 재도입 노트

## Design

### 3D descriptor (ctrl 출력, LD 방향 기준)

> **주의 (Phase 3 보정)**: 초안은 2D 였으나 `bank_offset` 가 4KB 페이지 중간에 떨어지면 AXI INCR burst가 4KB 경계를 넘어 SVA가 점화함. 이를 해결하기 위해 bank 내 sub-burst 차원을 추가한 **3D** 형태로 확정.
>
> `bank_offset_within_4KB = ((logical_addr >> 11) & 0x3F) × 64` — logical-4KB aligned base 도 remap 후 bank 내에서 임의 위치에 떨어질 수 있음.

```
localparam int NUM_BURST_GROUPS   = `PLATFORM_MEMORY_NUM_BANKS / NUM_CHANNELS;     // 4
localparam int BEAT_STRIDE_HBM_B  = `PLATFORM_MEMORY_INTERLEAVE
                                    ? (`PLATFORM_MEMORY_NUM_BANKS * `MEM_BLOCK_SIZE)  // 2048
                                    : `MEM_BLOCK_SIZE;                                // 64
localparam int BANK_STRIDE_HBM_B  = `HBM_BUS_STRIDE;                                 // 512
localparam int BEAT_STRIDE_TMEM_B = NUM_BURST_GROUPS * `MEM_BLOCK_SIZE;              // 256
localparam int BANK_STRIDE_TMEM_B = `MEM_BLOCK_SIZE;                                 // 64
localparam int MAX_BEATS_PER_BURST = 4096 / `MEM_BLOCK_SIZE;                         // 64

// Sub-burst size S = largest power-of-2 dividing:
//   (1) bank_off_beats = (hbm_side_base >> 11) & 0x3F   (0 이면 unconstrained, 64로 간주)
//   (2) total_beats_per_bank = ch_words / NUM_BURST_GROUPS
//   (3) MAX_BEATS_PER_BURST = 64
// power-of-2 divisor trick: v & -v (v != 0)
bank_off_beats       = (ch_hbm_base >> 11) & 0x3F;
total_beats_per_bank = ch_words / NUM_BURST_GROUPS;
s_bob  = (bank_off_beats == 0) ? 64 : (bank_off_beats & -bank_off_beats);
s_tbpb = total_beats_per_bank & -total_beats_per_bank;
S      = min(s_bob, s_tbpb);                     // 64 cap implicit (s_bob ≤ 64, s_tbpb ≤ tbpb)

// 분기 (burst_mode 조건에서 "≤ MAX_BEATS_PER_BURST" 제약은 S 계산에 흡수됨)
burst_mode = (ch_words >= NUM_BURST_GROUPS)
          && ((ch_words % NUM_BURST_GROUPS) == 0);

if (burst_mode) {
    // 3D: i0=beat within sub-burst, i1=sub-burst within bank, i2=bank within channel
    BND0    = S;                                 // beats per AXI burst (≤ 64)
    BND1    = total_beats_per_bank / S;          // sub-bursts per bank
    BND2    = NUM_BURST_GROUPS;                  // banks per channel
    SRC_ST0 = BEAT_STRIDE_HBM_B;                 // beat within sub-burst: 2048 (interleave)
    SRC_ST1 = S * BEAT_STRIDE_HBM_B;             // next sub-burst, same bank
    SRC_ST2 = BANK_STRIDE_HBM_B;                 // next bank
    DST_ST0 = BEAT_STRIDE_TMEM_B;                // 256 = NUM_BURST_GROUPS * MEM_BLOCK_SIZE
    DST_ST1 = S * BEAT_STRIDE_TMEM_B;
    DST_ST2 = BANK_STRIDE_TMEM_B;                // 64
} else {
    // Fallback (Q1=B): ch_words < NUM_BURST_GROUPS 또는 non-divisible.
    // Non-divisible ≥ NUM_BURST_GROUPS 케이스는 본 refactor 범위 외 (extension doc Option B).
    BND0    = 1;
    BND1    = ch_words;
    BND2    = 1;
    SRC_ST0 = 0;                                 // unused (BND0=1)
    SRC_ST1 = `HBM_BUS_STRIDE;
    SRC_ST2 = 0;
    DST_ST0 = 0;
    DST_ST1 = `MEM_BLOCK_SIZE;
    DST_ST2 = 0;
}
SEG_SIZE = `MEM_BLOCK_SIZE; PAD = 0;
```

ST 방향은 SRC/DST 스왑만 적용하여 그대로 (기존 ctrl의 `dir_is_st` 분기 유지). `ch_hbm_base` 는 LD 시 `ch_src_base`, ST 시 `ch_dst_base`.

**채널별 S**: `ch_hbm_base = dst/src_base + logical_ch × 64` → 채널마다 `bank_off_beats` 가 다를 수 있으므로 S는 per-channel 계산.

Kernel 호출별 예상 (dst_base/src_base 별로 다름):
- input, weight, output (ch_words=64/16/16, divisible): **3D burst_mode**, S 는 bank_off_beats 에 따라 [1, min(total_bpb, 64)] 값
- scale / zp (ch_words=2, < NBG): **fallback** (single-beat × 2 banks)

### `VX_dma_engine` passthrough FSM (채널당)

제거: `burst_window_*_r`, `burst_group_*_r`, `burst_wr_window_*_r`, `burst_wr_group_*_r`, `read_state_t`, `write_state_t` (현 형태), 관련 `burst_service_word`/`calc_group_words`/`calc_remap_byte_addr` 호출.

신규 state (채널별):

```
burst_len_r  [$clog2(MAX_BEATS_PER_BURST+1)-1:0]   // from cfg_reg_if on cfg_fire
beat_cnt_r   [$clog2(MAX_BEATS_PER_BURST+1)-1:0]   // 0..burst_len_r-1

// Read
rsp_tag_fifo (depth = AXI AR outstanding, 예: 8)    // push: req_fire, pop: axi_r_fire
// Write
wr_skid_r  {addr, data, byteen, tag}                // 1-beat skid (AW/W handshake 분리)
aw_issued_r / w_last_sent_r counters                // outstanding B 개수 추적
```

Read path:
1. `cfg_fire`: `burst_len_r ← cfg_reg_if.regs[DMA_R_BND0]`, `beat_cnt_r ← 0`, FIFO/pointer reset.
2. 첫 req (`beat_cnt_r==0`): `axi.ar_addr ← VX_mem_remap(byte_addr)`, `axi.ar_len ← burst_len_r-1`. AR fire 되면 다음 cycle부터 beat 수신.
3. 매 req_fire: push `req_tag` to `rsp_tag_fifo`, `beat_cnt_r++`. `beat_cnt_r == burst_len_r` → 0 복귀 (다음 AR 준비).
4. 매 `axi.r_fire`: pop tag, `hbm_bus_if.rsp_valid=1` with matching tag. Upstream `rsp_ready`와 직결 (매 R beat가 곧바로 upstream rsp).
5. Backpressure: `rsp_tag_fifo` almost_full → `hbm_req_ready=0` (신규 burst 시작 전).

Write path:
1. `cfg_fire`: 동일 latch + `aw_issued_r=0`, `b_drained_r=0`.
2. 첫 req (`beat_cnt_r==0`): `axi.aw_addr ← remap(byte_addr)`, `axi.aw_len ← burst_len_r-1`. AW 발사와 W beat 0 구동을 병행 (AW/W handshake 독립).
3. 매 req_fire: W beat 구동 (`w_data`, `w_strb=byteen`, `w_last = (beat_cnt_r == burst_len_r-1)`).
4. `w_last` fire → `aw_issued_r++`. 다음 req는 새 burst.
5. `axi.b_fire`: `b_drained_r++`.
6. Done 게이팅: `internal_done_if.valid & (aw_issued_r == b_drained_r)` → `done_if[ch].valid`.

### SVA (SIMULATION-only)

```systemverilog
// Descriptor 형상 체크 (BND2 ∈ {1, NUM_BURST_GROUPS} 허용, stride 세부 체크는 완화 —
// runtime 4KB boundary SVA 가 실제 위반을 잡는다)
assert (SEG_SIZE == MEM_BLOCK_SIZE
     && PAD      == 0
     && BND0 != 0 && BND0 <= MAX_BEATS_PER_BURST
     && BND1 != 0
     && (BND2 == 1 || BND2 == NUM_BURST_GROUPS)
     && SRC_BASE_LO[BLOCK_SHIFT-1:0] == 0
     && DST_BASE_LO[BLOCK_SHIFT-1:0] == 0)

// 추가: AXI 4KB boundary (AR/AW 양쪽)
always_ff @(posedge clk) begin
  if (!reset && axi_m[ch].ar_valid && axi_m[ch].ar_ready) begin
    logic [AXI_ADDR_WIDTH-1:0] ar_last = axi_m[ch].ar_addr
                             + (AXI_ADDR_WIDTH'(axi_m[ch].ar_len) << LOG2_DATA_SIZE);
    assert (axi_m[ch].ar_addr[AXI_ADDR_WIDTH-1:12] == ar_last[AXI_ADDR_WIDTH-1:12])
      else $fatal(1, "%m: ch=%0d AR crosses 4KB (addr=0x%0h len=%0d)",
                  ch, axi_m[ch].ar_addr, axi_m[ch].ar_len);
  end
  // 동일 로직을 AW에도
end

// Non-interleave 가드
initial if (!`PLATFORM_MEMORY_INTERLEAVE)
  $fatal(1, "VX_dma_engine: PLATFORM_MEMORY_INTERLEAVE=0 not supported");
```

## Implementation Phases

1. **Phase 0 — STATUS/doc setup**
   - `agent-tasks/dma-burst-reorder/STATUS.yaml` (FSM init)
   - `agent-tasks/dma-burst-reorder/extension-3d-when-burst-exceeds-4kb.md` (3D 확장 + bound>1 재도입 노트 기록)
   - Baseline 로그: 현 회귀 PASS 수, AR/AW 발행 수, 합성 FF/BRAM (if 가능)

2. **Phase 1 — ctrl 수정** (`VX_gemm_tmem_dma_ctrl.sv`)
   - localparam 계산 (NUM_BURST_GROUPS, BEAT/BANK strides, MAX_BEATS_PER_BURST)
   - ch별 `burst_mode` 판정 + descriptor 분기
   - `DMA_R_BND1 ← kernel bnd0` 연결 제거 (bnd0는 `BND2=1`로 대체, Q2 문서에 TODO)
   - 기존 assertion 테이블/추적 로그 업데이트

3. **Phase 2 — engine 완전 교체** (`VX_dma_engine.sv`)
   - 위에 나열한 register/FSM/function 삭제
   - 새 passthrough FSM 구현 (read/write)
   - 새 assertion (descriptor 형상 + 4KB boundary + interleave)
   - `DBG_TRACE_GEMM` 추적은 새 state/counter에 맞춰 재작성

4. **Phase 3 — 검증** (각 단계 회귀 PASS 필수)
   - `hw/unittest/dma_engine/` (`tb_VX_dma_engine.sv`): 가장 먼저 깨질 가능성 — 기존 descriptor 형상 기대. 새 형상에 맞게 stimulus 갱신 필요.
   - `hw/unittest/gemm_tmem_dma_ctrl/` (`tb_VX_gemm_tmem_dma_ctrl.sv` + misalign variant): ctrl 출력 비교 회귀 — expected register 값 재생성.
   - `hw/unittest/dma_mem_unit_misal/`: unit 자체는 무변경이라 동일 PASS 기대.
   - End-to-end: `tests/regression/fpint_gemm_ffn_hw_improve` (driver=rtlsim, shapes × qblk × wtrans × qdir sweep).
   - FSDB: `FSDB_DUMP=1` 로 AR/AW `addr/len`, `w_last`, B 드레인 타이밍을 기존 로그와 비교.

5. **Phase 4 — area 확인**
   - 가능한 합성 target (xrt 또는 unittest synth) 에서 FF/BRAM 변화 report. 목표: 채널당 `burst_*_window_*_r` 완전 제거, skid + FIFO만 남음.

## Verification

**Unit tests**
```
cd hw/unittest/dma_engine && make run
cd hw/unittest/gemm_tmem_dma_ctrl && make run
cd hw/unittest/dma_mem_unit_misal && make run
```

**End-to-end (hw_emu)** — 기본 회귀
```
cd build
python ci/test_fpint_hw.py hw_emu "-m 32 -n 32 -k 32 -q 32 -t 0 -d 0" --debug-always
```

- shape `(M,N,K) = (32,32,32)`, `qblk=32`, `wtrans=0`, `qdir=0` (QCOL) — scale/zp DMA가 fallback 경로로 가는 케이스 포함.
- `--debug-always` 로 FSDB dump / trace 자동 수집.
- 통과 후 다른 shape (예: `-m 128 -n 128 -k 128`), 다른 `qdir=1` (QROW), `wtrans=1` 로 sweep 하여 양쪽 burst_mode + fallback 모두 커버.

**Waveform 검증 (hang 또는 mismatch 시)**
```
# FSDB 경로는 hw_emu 실행 후 build/ 하위 산출물 참고
python tools/fsdb_cli/fsdb_cli.py <fsdb> --signal axi_m[0].ar_addr --signal axi_m[0].ar_len
```

**기대치**:
- `ch_words=64` 입력 DMA: 채널당 4개 AR fire, 각 `ar_len=15` (16 beats), 각 `ar_addr`이 remap된 bank 0/8/16/24 slot의 offset 0.
- `ch_words=2` scale/zp DMA: 채널당 2개 AR fire, 각 `ar_len=0`, bank 0과 8 slot.
- AXI 4KB boundary assertion never fires.
- FF count (e.g. synth에서): `VX_dma_engine` 전체 FF ≳ 70% 감소.

## Out of Scope (Q2 문서에 기록)

- `kernel.cmd.bound > 1` 재도입 — 필요 시 `BND2` 활용 또는 상위 FSM 에서 desc 연속 발행
- AXI burst가 4KB 넘는 경우 3D (sub-burst × bank × beat) 확장
- `PLATFORM_MEMORY_INTERLEAVE=0` 경로 — `VX_mem_remap`까지 동시 수정 필요
