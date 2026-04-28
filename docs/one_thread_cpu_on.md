# Per-Warp CPU Mode (`cpu_on`) — Implementation Plan

A small RTL feature that lets SW mark a specific warp as "this warp will run
single-threaded; please reduce its per-instruction issue latency so its
`ready` signal stays HIGH between scheduler picks." Other warps continue
SIMT-as-usual; the warp scheduler is not modified.

Targets the dispatcher pattern in
`tests/regression/fpint_gemm_ffn_hw_improve/kernel.cpp` and the helper-warp
DAE design in `docs/gemm-dispatcher-optimizations.md`.

## 1. Design Principle

The bottleneck for a single-thread warp is not "losing scheduler cycles to
other warps" — it is **arriving at the issue slot already not-ready**:
fetch is still waiting on the icache, the previous branch hasn't resolved,
or the operand is still a cycle away from writeback.

So this feature does **not** touch warp scheduling priority. Other warps
should still be free to interleave (this matters for warp specialisation
and helper-warp DAE, where two warps need to round-robin). Instead, every
change here aims at one goal:

> **Keep the cpu_on warp's `ready` signal == 1 every cycle.**

When the scheduler picks the cpu_on warp it should always have an
instruction ready to issue.

## 2. What `cpu_on` Actually Simplifies (and What It Doesn't)

This is important to nail down before designing the optimisations: the
`cpu_on` bit only carries the SW guarantee that **`tmask = 0x01`** for
that warp from the moment it is set. Everything below is a consequence
of that single contract.

### 2.1 Branch divergence vs branch resolution latency

These are two different things and `cpu_on` only neutralises the first.

**Branch divergence (SIMT-specific).** With `tmask = 0x01` only one lane
is ever live. Vortex's LLVM pass *does* emit `SPLIT` / `JOIN` around
every conditional branch — they cannot be assumed away by SW contract.
But under `tmask = 0x01` they always degrade to no-op semantics:

- `VX_wctl_unit.sv:122` `split.is_dvg = has_then && has_else`. With
  `tmask = 0x01`, exactly one of `has_then` / `has_else` is true, so
  `is_dvg` is **always false**.
- `VX_split_join.sv:50` `ipdom_push = split_valid && split.is_dvg` →
  no IPDOM stack push.
- `VX_schedule.sv:145-150` SPLIT handling: `is_dvg=0` skips the
  `thread_masks_n` update; only the `stalled_warps_n[wid] = 0` unlock
  fires.
- JOIN: `sjoin_is_dvg = (sjoin.stack_ptr != ipdom_wr_ptr[wid])`. With
  no prior SPLIT push, these match → no IPDOM pop, no `thread_masks_n`
  update, just unlock.
- `VX_alu_int.sv:121-141` vote ops collapse: `vote_true/false` single-
  bit, `vote_all/any/uni` trivially equal to the predicate.
- `VX_alu_int.sv:144-200` SHFL ops have no other lanes to read from →
  no-op semantics.
- `VX_ipdom_stack.sv` is never pushed and `thread_masks_n` after the
  initial `vx_tmc_one()` stays constant.

These outputs are correct for free; the *cost* of executing
SPLIT/JOIN/PRED, however, is **not** free — see "Branch resolution
latency" below.

(Asserted in simulation; see §8.)

**Branch resolution latency (in-order pipeline-specific).** This is the
dominant per-warp stall. `VX_decode.sv:264, 275, 287, 304, 319, 472`
set `is_wstall = 1` for every:

- `JAL`, `JALR`, conditional `B*`
- `SYS` (ECALL/EBREAK)
- FPU CSR writes
- SFU ops including `WSPAWN`, `BAR`, `TMC`, `PRED`, `SPLIT`, `JOIN`

`VX_decode.sv:569` then forwards `~is_wstall` as
`decode_sched_if.unlock`, and `VX_schedule.sv:202-204` locks every
fetched warp:

```systemverilog
// schedule.sv: unconditional lock at every fetch
if (schedule_fire) stalled_warps_n[schedule_wid] = 1;
// schedule.sv:116-117: only non-wstall instructions unlock at decode
if (decode_sched_if.valid && decode_sched_if.unlock)
    stalled_warps_n[decode_sched_if.wid] = 0;
```

Branches stay locked until execute resolves them at
`VX_schedule.sv:193-198`. For a dispatcher loop with a branch every few
instructions — and the LLVM pass adds `SPLIT` *before* and `JOIN`
*after* each conditional branch, so the per-branch overhead is actually
**3 lock-and-resolve round-trips** (SPLIT + B/JAL/JALR + JOIN), not one.

**`cpu_on` enables two distinct fixes here.**

1. **For B / JAL / JALR (real control transfer):** the small BTB
   (§4.3) — predict at fetch, unlock at decode if predicted; only
   mispredictions pay the resolve-time stall. cpu_on serves as the
   *enable gate* that makes adding a small per-warp BTB safe (no
   divergence races to worry about).

2. **For SPLIT / JOIN / PRED (SIMT control instructions whose result
   is provably no-op under tmask=0x01):** decode-stage `is_wstall`
   override — when `cpu_on[wid]` is set and the instruction is one of
   these three, force `is_wstall = 0` so the warp is *not* locked at
   fetch. The instruction still dispatches to SFU and writes back its
   `rd` (stack pointer) for compiler compatibility, but the warp is
   free to fetch its next instruction immediately. See §4.4 for the
   exact decode change.

   This is unique to cpu_on: it relies on `tmask = 0x01` to guarantee
   `split.is_dvg = 0` and `sjoin_is_dvg = 0`, which is precisely what
   the "Branch divergence" half of this section establishes.

### 2.2 What does collapse under `cpu_on`

| Path | File:line | Behaviour today | Under cpu_on |
|---|---|---|---|
| Regfile read width | `VX_opc_unit.sv:67-150` | 8-lane read, SIMD iterator picks lane 0 | lane 0 read only (logically; HW can keep 8-lane and ignore) |
| ALU/FPU per-lane datapath | `VX_alu_int.sv` (genvar `i<NUM_LANES`) | 8-lane operate, mask discards lanes 1-7 | only lane 0 result used |
| LSU per-lane addr/data | `gemm_ctrl_if.req_data.{mask, addr[8], data[8]}` | mask = `tmask`, lanes 1-7 ignored | mask = `0x01`, single addr/data |
| Commit per-lane writeback | `VX_commit.sv` `per_issue_commit_tmask[i]` | per-lane gate by tmask | lane 0 only |
| Vote ops (`VX_alu_int.sv:121-141`) | 8-lane reduce-OR over predicate | trivial single-bit |
| SHFL ops (`VX_alu_int.sv:144-200`) | inter-lane permute | no-op semantics |
| SPLIT/JOIN divergence (`VX_wctl_unit.sv`) | always-on hardware | dead code (SW contract) |
| IPDOM stack (`VX_ipdom_stack.sv`) | push/pop on SPLIT/JOIN | never written |
| `thread_masks_n` updates (`VX_schedule.sv:138-160`) | TMC/SPLIT/JOIN modify | constant `0x01` after init |

**Practical use of these simplifications.** None of them are required to
gain performance — the existing 8-lane datapath produces correct results
under `tmask=0x01` already. The value of recognising them is:

1. **Safety / verification:** simulation assertions (§8) confirm the
   `tmask = 0x01` invariant; once asserted, all the dead-path concerns
   above evaporate. This lets us reason about and freely modify
   fetch/branch logic for cpu_on warps without worrying about SIMT-mode
   interactions (divergence races, lane mismatches).
2. **Optional power gating:** lane 1-7 datapath could be clock-gated
   on `cpu_on` (cheap, automated by synthesis), no functional change.
3. **Future work:** a deeper restructure could shrink the regfile read
   port to 1 lane on `cpu_on` paths, removing critical-path muxes; not
   in scope here.

The performance optimisations in §4 (icache prefetch, BTB) are **not**
consequences of these simplifications — they are independent
fetch/branch micro-architectural changes that we are gating on `cpu_on`
purely to bound their scope (per-warp resources, smaller BTB area, no
interaction with multi-lane warps).

## 3. Activation Mechanism — MMIO Write

A new tiny MMIO peripheral exposes one register per warp.

```c
// SW
static constexpr uint64_t CPU_MODE_ADDR = 0x10C0;   // single shared address
*(volatile uint32_t*)CPU_MODE_ADDR = 1;             // turn ON  for THIS warp
*(volatile uint32_t*)CPU_MODE_ADDR = 0;             // turn OFF for THIS warp
```

The peripheral extracts the writing warp's `wid` from the LSU store's
`req_data.tag` (Vortex's LSU request already carries wid for response
routing) and sets/clears `cpu_on[wid]`. The `cpu_on[NUM_WARPS-1:0]`
register is then broadcast to fetch / branch / issue stages.

### Why MMIO instead of tmask popcount auto-detect

| | MMIO write | tmask popcount auto |
|---|---|---|
| SW change | one MMIO write at start of region | none |
| HW change | new small peripheral, broadcast wire | scheduler tmask state must fan out to fetch + new popcount logic |
| Couples to tmask transients | no | yes (could flicker on tmc transitions) |
| SW intent visible in source | yes | no |
| Critical path | none (peripheral only on store path) | tmask is in scheduler timing path |

MMIO is cleaner: scheduler is not touched; SW intent is explicit; cpu_on
can be toggled independently of `tmask` (useful for debug).

### Lane-0 assumption — no dynamic detection

When `cpu_on[wid] == 1`, the hardware **assumes the only active thread is
lane 0**. SW must call `vx_tmc_one()` (which sets `tmask = 0x01`) before
or together with the `cpu_on` write. The HW does **not** check `tmask`
at every cycle — all "use lane 0" decisions are gated solely by
`cpu_on[wid]`.

Rationale:
- `vx_tmc_one()` always activates lane 0 (lowest-numbered lane), so this
  is consistent with how SW already writes single-thread code.
- Removing runtime detection collapses several mux/popcount paths.
- The SW contract is trivial to follow and trivial to violate visibly.

Behaviour outside the contract (`cpu_on[wid] == 1` while `tmask != 0x01`)
is **undefined**. We surface this as SV assertions for debug only — no
silicon cost.

```systemverilog
// In VX_schedule.sv (or wherever tmask is held), once per warp
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (cpu_on[wid] && active_warps[wid] && (thread_masks[wid] != 'b1)) begin
      $error("cpu_on[%0d]=1 but tmask=0x%0h (must be 0x1)",
             wid, thread_masks[wid]);
    end
  end
`endif
```

## 4. RTL Changes

Total ~260 lines across 3 modules. Scheduler is **not** modified.

### 4.1 New Peripheral — `VX_cpu_mode_ctrl.sv` (~50 lines)

- Decode store address against `CPU_MODE_BASE` in `VX_lmem_switch.sv`
  (mirror the existing GEMM/DMA routing pattern at lines 72-86).
- Capture `wid` from `req_data.tag`, capture write data lsb.
- One register: `cpu_on[NUM_WARPS-1:0]`.
- Broadcast: `output logic [NUM_WARPS-1:0] cpu_on_o` to fetch / branch /
  issue.
- Response: posted write semantics (1-cycle ack), no waiting.

`VX_lmem_switch.sv` change: add a `is_addr_cpu_mode_mask` decode similar
to the existing `is_addr_gemm_mask` (lines 76-80) and route to the new
peripheral via an elastic buffer (~20 lines patterned after the existing
`req_gemm_buf`).

### 4.2 iCache Sequential Prefetch — `VX_fetch.sv` (~80 lines + ~20 arbiter)

**Problem.** Today fetch issues an icache request, waits 3-5 cycles for
the response, then requests the next PC. During the wait the warp's
`ready` is 0.

**Fix.** For `cpu_on[wid]==1`, while a demand fetch for PC is outstanding,
speculatively issue a prefetch for `PC+4` (or BTB-predicted target — see
3.3). Hold the prefetched instruction in a small per-warp prefetch buffer
(1-2 entries). On the next demand fetch, hit the prefetch buffer and skip
the icache round-trip.

Hooks:
- New per-warp `prefetch_buf[NUM_WARPS]` 2-entry FIFO holding `{PC,
  inst}`.
- Prefetch FSM gated by `cpu_on[wid]`.
- icache port arbitration: demand fetches always win; prefetches only fire
  in idle cycles.

Notes:
- Per-warp scope keeps the prefetch buffer area small.
- A wrong-path prefetch (after a mispredicted branch) is just dropped; no
  correctness issue.

### 4.3 Small Per-Warp BTB — `VX_fetch.sv` + branch unit (~90 lines)

**Problem.** Vortex resolves branches in execute → 5-7 cycle bubble per
taken branch. Dispatcher loops branch every few iterations.

**Fix.** 8-entry direct-mapped BTB **per cpu_on warp** (or one shared
8-entry BTB tagged by wid). Each entry: `{valid, tag(PC bits), target,
2-bit saturating counter}`. Total storage ~16 entries × ~32 bits = 64 B.

- Fetch: if `cpu_on[wid]` and BTB hit and counter predicts taken, redirect
  next-PC to BTB target; mark instruction speculative.
- Execute (branch unit): on resolved branch, update BTB entry. On
  mispredict, redirect fetch and squash speculative instructions in
  flight.
- Mispredict on cpu_on warp costs the same as today's unconditional
  flush; correctly-predicted branches are now zero-bubble.

Limit to cpu_on warps to bound the area/critical-path impact and keep
the change contained.

### 4.4 SPLIT/JOIN/PRED `is_wstall` Override — `VX_decode.sv` (~10 lines)

**Problem.** Vortex's LLVM pass emits `SPLIT` before each conditional
branch and `JOIN` at the corresponding reconvergence point. Under
`tmask = 0x01` these always degrade to no-op semantics (`split.is_dvg =
0`, `sjoin_is_dvg = 0`; see §2.1), but their cost is *not* zero:
`VX_decode.sv:472` sets `is_wstall = 1` for every EXT1 funct7=0x00
op, so each SPLIT/JOIN locks the warp until the SFU pipeline retires it
at `VX_schedule.sv:147-150`. For a dispatcher loop, every conditional
branch costs **3** lock-and-resolve round-trips (SPLIT + branch + JOIN)
instead of one.

**Fix.** When `cpu_on[wid] = 1` and the instruction is `SPLIT`, `JOIN`,
or `PRED`, set `is_wstall = 0`. The instruction still dispatches to SFU
and writes back `rd` (stack pointer for compiler compat), but the warp
is not locked — the next instruction can be fetched immediately and
overlap with the SFU round-trip.

```systemverilog
// VX_decode.sv near line 472, in the EXT1 funct7=0x00 case:
//   is_wstall = 1;                           // before
is_wstall = ~(cpu_on[fetch_if.data.wid]
            && (funct3 == 3'h2     // SPLIT
             || funct3 == 3'h3     // JOIN
             || funct3 == 3'h5));  // PRED
```

Notes:
- TMC, WSPAWN, BAR keep `is_wstall = 1` even under cpu_on. TMC changes
  `tmask` so it must serialise with the rest of the pipeline; BAR and
  WSPAWN have global state effects that should not race ahead.
- Correctness rests on `split.is_dvg = 0` / `sjoin_is_dvg = 0` under
  `tmask = 0x01`, which holds *only* with the cpu_on contract. See
  §8 for the SV assertion that enforces this.
- The SFU pipe still runs (writes `rd`), so RAW dependencies on the
  stack-ptr output are tracked correctly by the existing scoreboard.

### 4.5 Summary Table

| # | Module | Change | Lines | cpu_on-gated? |
|---|---|---|---:|---|
| 1 | new `VX_cpu_mode_ctrl.sv` + `VX_lmem_switch.sv` | MMIO peripheral, broadcast `cpu_on` | ~70 | n/a (creates the signal) |
| 2 | `VX_fetch.sv` | sequential prefetch + buffer | ~100 | yes |
| 3 | `VX_fetch.sv` + branch unit | small BTB | ~90 | yes |
| 4 | `VX_decode.sv` | SPLIT/JOIN/PRED `is_wstall=0` override | ~10 | yes |
| **Total** | | | **~270** | |

Plus SV assertions in `VX_schedule.sv` (~10 lines, simulation-only).

**Already in current branch — do not redo:** scoreboard same-cycle
dep-bit clear (`VX_scoreboard.sv:130-159`).

**Deferred to future work (see §9):** RAW forwarding (writeback →
operand-buffer bypass in opc_unit) and any scoreboard restructuring.

## 5. Scope of the Optimisation

What this **does** improve:
- The cpu_on warp's `ready` signal stays 1 most cycles → when the
  scheduler picks it (under whatever policy), an instruction issues.
- Sequential code: prefetch eliminates fetch bubbles entirely.
- Predictable branches: BTB makes loop branches zero-bubble.

What this **does not** change:
- **1 IPC per warp ceiling.** Same-warp dual-issue would require dual
  regfile ports + dual scoreboard + dual collision detection, which is
  effectively two mini in-order cores per warp. Out of scope.
- **RAW dependent-instruction bubble.** Currently ~4 cycles (registered
  `operands_ready_r` + opc_unit pipe stages + GPR `OUT_REG` + output
  buffer). Deferred to future work (see §9).
- **Cache miss latency.** A miss still stalls; prefetch only helps when
  PC+4 (or a predicted target) is known.
- **MMIO backpressure.** Already 0 % per FSDB measurement
  (`tools/mmio_analysis/RESULTS.md`); nothing to fix here.

## 6. Interaction With Other Optimisations

### Helper-warp DAE (`docs/gemm-dispatcher-optimizations.md` Opt 1)

Both producer and consumer warps set `cpu_on=1` at start. Each gets:
- prefetch + BTB benefits independently.
- The scheduler still round-robins naturally between them (Vortex
  scheduler picks lowest-id ready warp; both are ready most cycles, so
  they alternate).

This is exactly why we deliberately did **not** add per-warp priority:
priority would starve the consumer warp.

### 8-Thread MMIO Burst (`docs/gemm-dispatcher-optimizations.md` Opt 2)

The consumer warp in helper-warp DAE wants `tmc(0xFF)` to drive 8 lanes
into 8 distinct stream addresses in one cycle. That warp must therefore
**not** set `cpu_on` (because `cpu_on` assumes lane 0 only).

Combination pattern:
- Producer warp (single thread): `vx_tmc_one(); *CPU_MODE_ADDR = 1;` →
  benefits from cpu_on.
- Consumer warp (8 threads): `vx_tmc(0xFF);` (no cpu_on write) →
  benefits from 8-lane MMIO burst.

The two optimisations cover disjoint warp populations and compose cleanly.

## 7. Activation Latency

The MMIO write takes ~5-10 cycles to traverse LSU → peripheral → broadcast
before `cpu_on[wid]` is visible to fetch/branch/issue. Instructions
fetched during this window run in normal SIMT mode; this is fine because:
- Dispatcher kernels turn `cpu_on` ON once at start and leave it ON.
- The lost cycles at start are negligible against the 100k+ cycles of
  dispatcher work.

If the kernel ever needs to *clear* `cpu_on` synchronously (e.g., before
divergent code), a `fence` after the MMIO write is sufficient — the LSU
will not reorder the fence past the MMIO write.

## 8. Verification

### Functional regression
- Existing `tests/regression/fpint_gemm_ffn_hw_improve` must still pass
  bit-exact at every step.
- Add a small unit test that toggles `cpu_on` and checks reads of a
  status MMIO mirror.

### Performance regression
- Re-run `tools/mmio_analysis/analyze_mmio_stall.py` after each step.
  Headline metric to watch: GEMM accept-to-accept gap distribution
  shifts left from the current 7/10/16-cycle modes toward 4-7 cycles.

### SV assertions (simulation only)
```systemverilog
// 1. cpu_on requires tmask == 0x1 (the contract that lets us assume
//    SPLIT/JOIN/divergence paths stay dead — see §2.1).
assert property (@(posedge clk) disable iff (reset)
  (cpu_on[wid] && active_warps[wid]) |-> (thread_masks[wid] == 'b1))
  else $error("cpu_on contract violated for warp %0d", wid);

// 2. cpu_on warps DO execute SPLIT/JOIN/PRED (LLVM emits them around
//    every conditional branch). The contract is that they never
//    diverge: split.is_dvg must be 0, sjoin_is_dvg must be 0.
assert property (@(posedge clk) disable iff (reset)
  (warp_ctl_if.valid && cpu_on[warp_ctl_if.wid]
   && warp_ctl_if.split.valid) |-> (warp_ctl_if.split.is_dvg == 1'b0))
  else $error("cpu_on warp %0d SPLIT diverged", warp_ctl_if.wid);
assert property (@(posedge clk) disable iff (reset)
  (join_valid && cpu_on[join_wid]) |-> (join_is_dvg == 1'b0))
  else $error("cpu_on warp %0d JOIN diverged", join_wid);

// 3. prefetch buffer never holds stale PC after BTB redirect.
assert property (@(posedge clk) disable iff (reset)
  (btb_redirect && cpu_on[wid]) |-> ##1 (prefetch_buf_valid[wid] == 0))
  else $error("stale prefetch in warp %0d after BTB redirect", wid);
```

## 9. Future Work

### 9.1 RAW Writeback → Operand Bypass

A separate (independent) optimisation that targets the RAW dependent-
instruction bubble. Investigated; details retained for future
implementation:

**Where the 4-cycle bubble comes from** (verified in current branch):

| Source | File:line | Cost |
|---|---|---:|
| `operands_ready_r` register | `VX_scoreboard.sv:177-189` | +1 cyc |
| opc_unit `pipe_reg1` | `VX_opc_unit.sv:185-194` | +1 cyc |
| GPR `OUT_REG=1` (RDW_MODE="R") | `VX_opc_unit.sv:279-298` | +1 cyc |
| opc_unit `pipe_reg2` + `out_buf` | `VX_opc_unit.sv:204-219, 302-...` | +1 cyc |

The scoreboard already does same-cycle dep-bit clear at
`VX_scoreboard.sv:130-159` (do not redo).

**Practical fix (~35 lines, save 1-2 cyc):** writeback → opc_unit
operand-buffer bypass mux. When in-flight read source matches a same-
cycle writeback, mux writeback data into `opd_buffer_n_st2` instead of
`gpr_rd_data_st2`.

```systemverilog
// VX_opc_unit.sv: track in-flight rs idx + wis for st1/st2 stages
// (~10 lines from pipe_mdata_st1/st2)
for (int b = 0; b < NUM_BANKS; b++) begin
    if (gpr_rd_valid_st2[b]) begin
        opd_buffer_n_st2[gpr_rd_opd_st2[b]] =
            wb_match_st2[gpr_rd_opd_st2[b]]
                ? writeback_if.data.data         // forward
                : gpr_rd_data_st2[b];            // GPR
    end
end
```
With `wb_match_st2[i]` =
`(writeback_if.valid && writeback_if.data.wis==stN_wis &&
writeback_if.data.rd==stN_rs[i])`.

Apply generally (not gated by `cpu_on`); benefits multi-thread warps
equally.

**Rejected sub-option — un-register `operands_ready[w]`:** creates two
combinational loops in `VX_scoreboard.sv` (via `ibuffer_fire` lookahead
on `regs_mask` line 163, and via `staging_fire` rd-reserve on
`inuse_regs_n` line 154). Breaking either requires giving up the
same-cycle dep-bit clear or restructuring `inuse_regs_n` reserve-rd —
not worth the 1-cycle gain.

**Rejected sub-option — RDW_MODE "R"→"W":** under the current scoreboard
there is no same-cycle read+write to the same address (registered
`operands_ready_r` ensures B fires ≥1 cycle after A's writeback), so
RDW change alone has no effect. (`upstream/develop`'s `VX_operands.sv`
uses `RDW_MODE="W"` + `NO_RWCHECK(1)` by default; not load-bearing for
our gain.)

### 9.2 Lane-1-7 Datapath Power Gate (cpu_on)

Clock-gate the lane 1-7 ALU/FPU/regfile read paths when `cpu_on[wid]`
is the issuing warp. Pure power optimisation, zero functional change.
Synthesis can largely automate this.

### 9.3 Single-Lane Regfile Read Port

When `cpu_on[wid]`, route `VX_opc_unit.sv:67` GPR reads through a
1-lane port instead of the 8-lane SIMD-width path. Removes SIMD
iterator and lane mux from the cpu_on critical path. Larger rework.

## 10. Implementation Order

1. **Peripheral + signal** (item 4.1). Bring up `cpu_on` register and
   broadcast it. Validate by reading back via a status mirror; no
   pipeline behaviour change yet. Assertions from §8 active from this
   step on.
2. **SPLIT/JOIN/PRED is_wstall override** (item 4.4). 10-line decode
   change. Smallest meaningful win — eliminates 2/3 of the per-branch
   warp-lock cost in dispatcher loops with no other change. Verify
   with the `is_dvg=0` assertions before measuring.
3. **iCache prefetch** (item 4.2). Gated by `cpu_on`. Verify no impact
   on non-cpu_on warps. Measure dispatcher gap distribution.
4. **Small BTB** (item 4.3). Highest-risk module (mispredict path).
   Add last and verify with branch-heavy microbenchmarks before
   integrating.

Each step is independently mergeable and gives measurable improvement.
RAW work (§9.1) is deferred and can be picked up in parallel as a
separate track once the core feature is in.
