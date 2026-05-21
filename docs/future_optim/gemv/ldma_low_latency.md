# LDMA Low-Latency Optimization Plan

## Context

GEMV에서는 transfer payload가 작아 `VX_lmem_dma_misal`의 fixed prologue latency가 성능을 크게 잡아먹는다.

FSDB:

`build/logs/fpint_improve_m1_k256_n256/xrtsim_vcs/vcs_cosim.fsdb`

측정 기준:

- command accept: `cmd_start`
- first read issue: `src_req_fire`
- first read response: `src_rsp_fire`
- first write issue: `dst_req_fire`

현재 latency는 모든 LDMA stream에서 동일했다.

| stream | commands | cmd -> first rd req | rd req -> rd rsp | rd rsp -> first wr | cmd -> first wr |
| --- | ---: | ---: | ---: | ---: | ---: |
| input | 64 | 6 cycles | 1 cycle | 1 cycle | 8 cycles |
| weight | 64 | 6 cycles | 1 cycle | 1 cycle | 8 cycles |
| sz | 128 | 6 cycles | 1 cycle | 1 cycle | 8 cycles |
| output | 8 | 6 cycles | 1 cycle | 1 cycle | 8 cycles |

Dominant overhead는 `cmd_start -> first rd req` 6 cycles이다. `rd req -> rd rsp`와 `rd rsp -> first wr`는 각각 1 cycle이라 우선순위가 낮다.

## Current Root Cause

`VX_lmem_dma_misal.sv`는 command를 받으면 먼저 `TOP_PRECALC`에 들어간다.

- `cmd_start = ctrl_if.start && (top_state == TOP_IDLE)`
- `cmd_start`에서 command fields, strides, bounds를 register에 latch한다.
- `TOP_PRECALC`에서 `VX_mul_u32_pipe` 6개로 `stride * (bound - 1)` 값을 계산한다.
- `precalc_done` 이후에야 `TOP_RUN`, `RD_RUN`, `WR_RUN`으로 전환한다.
- 따라서 first segment의 first read도 precalc 완료 후에만 나간다.

하지만 first segment first read는 `src_base_addr`와 `seg_size`만 있으면 issue 가능하다. `stride_bound_r`는 다음 segment로 advance할 때 필요하다.

## Proposed Optimization

`VX_lmem_dma_misal`에 default-off parameter를 추가한다.

```systemverilog
parameter bit OPT_LOW_LATENCY = 1'b0
```

Backward compatibility 원칙:

- Default는 `0`으로 둔다.
- Existing instantiation이 parameter를 넘기지 않으면 기존 RTL 동작과 동일해야 한다.
- Opt-in instantiation만 low-latency path를 탄다.
- `VX_tmem_subsystem` 및 legacy `VX_gemm_ctrl_with_ldma` instantiation에는 필요 시 `.OPT_LOW_LATENCY(...)`를 명시적으로 넘긴다.

## Optimization 1: First-Segment Fast Path

목표:

- `cmd_start -> first rd req`를 6 cycles에서 1-2 cycles 수준으로 줄인다.

아이디어:

- `OPT_LOW_LATENCY=1`일 때 `cmd_start` 후 `TOP_PRECALC`에서 기다리지 않는다.
- Command latch와 동시에 first segment read/write state를 준비한다.
- 다음 cycle부터 `TOP_RUN && RD_RUN && WR_RUN` 조건이 참이 되어 first read request를 issue한다.
- Precalc는 first segment transfer와 parallel로 실행한다.

Expected state update on `cmd_start`:

```systemverilog
if (OPT_LOW_LATENCY) begin
  top_state <= TOP_RUN;
  rd_state  <= RD_RUN;
  wr_state  <= WR_RUN;
  rd_src_rd_ptr_r <= align_down(ctrl_if.src_base_addr);
  rd_src_rd_end_r <= align_up(ctrl_if.src_base_addr + 64'(ctrl_if.seg_size));
  precalc_pending_r <= need_precalc;
end else begin
  top_state <= TOP_PRECALC;
  rd_state  <= RD_IDLE;
  wr_state  <= WR_IDLE;
  precalc_pending_r <= 1'b1;
end
```

Required extra gating:

- Existing `precalc_issue = (top_state == TOP_PRECALC) && precalc_pending_r` must be generalized.
- Low-latency mode should issue precalc after the command fields are registered, while `TOP_RUN` is already active.
- Segment advance must not use `stride_bound_r` before precalc is valid.
- If first segment completes before precalc is done and more segments remain, RD/WR should stall at segment boundary until `precalc_done`.

Safe implementation shape:

- Keep legacy always block under `if (!OPT_LOW_LATENCY)`.
- Add a separate `if (OPT_LOW_LATENCY)` generate branch for the modified FSM.
- This avoids accidentally perturbing old mode.

## Optimization 2: GEMV/1D Precalc Bypass

목표:

- GEMV-like 1D DMA commands should not wait for stride-bound multipliers at all.

Safe bypass condition:

```systemverilog
wire is_1d_cmd = (ctrl_if.bounds[1] == 32'd1) && (ctrl_if.bounds[2] == 32'd1);
```

Why this is safe:

- For 1D traversal, `advance_segment()` only needs `stride_r[*][0]`.
- `stride_bound_r[*][0..2]` is only needed when wrapping dimension 0 into dimension 1 or dimension 1 into dimension 2.
- If `bounds[1] == 1 && bounds[2] == 1`, those higher-dimensional wraps never happen before the transfer is complete.

Expected behavior:

- `OPT_LOW_LATENCY=1 && is_1d_cmd`: skip precalc completely.
- `OPT_LOW_LATENCY=1 && !is_1d_cmd`: run first-segment fast path and do precalc in parallel.
- `OPT_LOW_LATENCY=0`: keep current behavior.

Expected latency for 1D/GEMV:

| path | current | expected |
| --- | ---: | ---: |
| cmd -> first rd req | 6 cycles | about 1 cycle |
| rd req -> rd rsp | 1 cycle | unchanged |
| rd rsp -> first wr | 1 cycle | unchanged |
| cmd -> first wr | 8 cycles | about 3 cycles |

Exact expected value depends on whether `cmd_start` is counted at the same cycle as command latch or the following sampled edge.

## Generate/Parameter Feasibility

This is implementable with a parameterized generate split.

Recommended style:

```systemverilog
generate
  if (OPT_LOW_LATENCY) begin : g_low_latency
    // Modified low-latency FSM.
  end else begin : g_legacy
    // Current FSM logic, kept behaviorally identical.
  end
endgenerate
```

A procedural `if (OPT_LOW_LATENCY)` inside the existing `always_ff` is also synthesizable because `OPT_LOW_LATENCY` is a parameter, but it is riskier for backward compatibility. A generate split makes review easier because the legacy branch can be kept nearly byte-for-byte identical.

Instantiation points to update:

- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`: add `OPT_LOW_LATENCY` parameter.
- `hw/rtl/mem/VX_tmem_subsystem.sv`: pass `.OPT_LOW_LATENCY(1'b0)` initially, or a new macro.
- `hw/rtl/core/gemm/VX_gemm_ctrl_with_ldma.sv`: pass the same parameter for legacy path consistency.

Optional macro:

```systemverilog
`ifndef LMEM_DMA_OPT_LOW_LATENCY
`define LMEM_DMA_OPT_LOW_LATENCY 0
`endif
```

Then instantiations can use:

```systemverilog
.OPT_LOW_LATENCY(`LMEM_DMA_OPT_LOW_LATENCY)
```

This keeps default builds backward compatible and allows targeted opt-in from config.

## Risks

- Boundary correctness: non-1D commands must not advance using invalid `stride_bound_r`.
- Done timing changes in low-latency mode; downstream sync logic must tolerate earlier `done`.
- If first segment is very short, low-latency mode may need a small boundary wait state until precalc completes.
- Keeping legacy and low-latency FSMs as separate generate branches duplicates logic, but reduces regression risk.
- If later optimizing `rd rsp -> first wr` to 0 cycles, timing may worsen because response data would feed write data/byte-enable combinationally.

## Validation Plan

1. Run the current FSDB latency script again and confirm low-latency mode reduces `cmd_start -> src_req_fire`.
2. Test 1D/GEMV commands with `bounds[1]=1`, `bounds[2]=1`.
3. Test multi-dimensional commands to confirm boundary wait/precalc behavior.
4. Compare output correctness against `OPT_LOW_LATENCY=0`.
5. Check `perf_src_rd_req_stall`, `perf_src_rd_data_stall`, and `perf_dst_wr_stall` do not regress.
6. Run xrt-vcs blackbox with both default and opt-in configs.

## Recommendation

Implement `OPT_LOW_LATENCY` in two stages.

Stage 1:

- Add parameter and macro plumbing with default `0`.
- Add 1D/GEMV fast path only.
- Keep non-1D behavior identical.

Stage 2:

- Add general first-segment fast path for non-1D commands.
- Add boundary wait until `precalc_done` if needed.

This sequence gives the GEMV benefit first while minimizing backward-compatibility risk.
