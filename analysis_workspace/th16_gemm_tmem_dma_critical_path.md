# TH16 GEMM-to-TMEM DMA Critical-Path Analysis

## Conclusion

The failing TH16 path is not a direct consequence of using 16 threads. It is
a new cross-module combinational path introduced by the current GEMM, TMEM,
and DMA architecture:

```text
VX_gemm_compute_core.acc_launch_ctrl_q.is_load
  -> tagged compute completion
  -> VX_gemm_ctrl child-0 completion metadata
  -> effective synchronization update
  -> child-5 DMA dependency release
  -> TMEM DMA command acceptance and chaining arbitration
  -> aligned DMA descriptor decode
  -> VX_dma_unit_align.stride_bound_r D
```

The placed report records 73 logic levels and 25.271 ns of data-path delay for
a 10 ns clock. The setup WNS is -15.682 ns. Registering synchronization would
cut the path, but it would also delay completion-to-command release and reduce
the overlap this architecture was designed to provide. The preferred first
fix is therefore an owner-specific parallel synchronization reduction plus a
DMA-only selector for the four dependency RIDs that DMA actually consumes.

## Analyzed Build and Report

- Configuration: `improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem`
- Platform: Xilinx U55C
- Report:
  `build/hw/syn/xilinx/xrt/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_placed.rpt`
- Reported WNS: -15.682 ns
- Requirement: 10.000 ns
- Data-path delay: 25.271 ns
- Logic levels: 73
- Representative cell mix: 11 `CARRY8`, 56 LUT cells, four `MUXF7`, and two
  `MUXF8`

The path family repeatedly terminates at bits of
`stride_bound_r[0][*][*]`, with approximately the same 25.26 ns delay and
73-level depth. This is a structural cone, not an isolated endpoint bit.

## Report Endpoints and RTL Mapping

### Startpoint

The startpoint is a replicated copy of:

```text
u_compute_core/acc_launch_ctrl_q_reg[is_load]_rep/Q
```

In `VX_gemm_compute_core.sv`, the accepted compute packet carries its launch
control through the pipeline. The final writeback emits the command-completion
metadata used by `VX_gemm_ctrl` to retire child 0 and apply its synchronization
notification.

The startpoint is therefore not merely an accumulator data bit. It is a
control field that becomes part of the current-cycle compute-completion cone.

### Endpoint

The endpoint is a D pin such as:

```text
u_dma_unit/g_aligned/u_impl/stride_bound_r_reg[0][0][25]/D
```

In `VX_dma_unit_align.sv`, descriptor acceptance selects either a prepared
look-ahead value or the incoming descriptor value and writes the stride/bound
state. The endpoint is consequently the aligned DMA descriptor-load mux, not
the DMA payload datapath.

## Reconstructed Combinational Path

The placed report and RTL agree on the following four stages.

### 1. Compute completion reaches the GEMM controller

The final compute writeback produces a completion. `VX_gemm_ctrl` selects the
head metadata for child 0 and forms `child_completion_pop_v[0]`. That metadata
contains the synchronization RID, SET/PLUS mode, and value originally attached
to the command.

This stage explains why `acc_launch_ctrl_q.is_load` can influence scheduling
control even though the endpoint is inside DMA configuration state.

### 2. The legacy synchronization reducer serializes six children

The baseline controller initializes the full `effective_sync` array from
`sync_regs_q`, then applies each child completion through a dynamic RID
read-modify-write loop:

```systemverilog
for (int child = 0; child < N_CHILDREN; ++child) begin
    if (completion[child]) begin
        if (set_mode[child])
            effective_sync[reg_id[child]] = value[child];
        else
            effective_sync[reg_id[child]]
                = effective_sync[reg_id[child]] + value[child];
    end
end
```

Although legal children own different RIDs, source ordering over a dynamically
indexed unpacked array creates a six-stage dependency chain. Vivado maps the
chain through child queue/inflight selection and multiple carry structures.
The 11 reported `CARRY8` cells are consistent with chained 32-bit counter
updates.

The child-5 scheduler then performs a generic dynamic lookup into this array to
evaluate DMA dependencies. Thus a child-0 completion can pass through the
apparent child-1 through child-4 update cone before releasing child 5.

### 3. DMA acceptance changes same-cycle chaining arbitration

The released command drives `VX_tmem_dma_ctrl`. High-priority command
acceptance creates `accepted_high_now`, which participates in the same-cycle
choice between a new descriptor, a pending descriptor, and a chained fallback
candidate.

This behavior preserves immediate replacement and priority semantics, but it
extends the controller dependency cone into DMA chaining control.

### 4. Descriptor selection reaches aligned DMA state on the same edge

The selected command drives the DMA configuration interface. The aligned DMA
unit decodes the descriptor and selects the values written into local stride
and bound registers. The selected result reaches `stride_bound_r` D in the
same acceptance cycle.

Representative report arrival points were:

| Point | Approximate arrival |
|---|---:|
| Startpoint Q | 7.581 ns |
| New high-command visibility (`accepted_high_now`) | 28.037 ns |
| `stride_bound_r` D | 32.773 ns |

The reported 25.271 ns data-path delay includes approximately 0.079 ns of
clock-to-Q delay.

## Why Thread Count Is Not the Direct Cause

The compared TH32 build did not use the same generated RTL snapshot. Its
persistent XRT build directory reused older packaged sources that did not
contain `VX_gemm_compute_core.sv` and used a much smaller legacy
`VX_gemm_ctrl.sv`. At least 65 same-name generated source files also differed.

The XRT dependency chain regenerates `sources.txt` from Makefiles, platform
metadata, and the configuration fingerprint, but it does not list all RTL
sources as prerequisites. An unchanged configuration can therefore reuse stale
generated RTL and XO content after source changes.

TH16 does affect placement, replication, fanout, and congestion, so it can
determine which path becomes worst. It does not create the architectural path
described above. A valid TH16-versus-TH32 comparison requires both builds to be
freshly generated from the same Git revision.

The failed TH16 build also reached global congestion level 7. SLR0 CLB usage
was 94.03% even though whole-device CLB usage was 72.85%. Routing delay is
therefore substantial, but physical congestion alone cannot repair a
73-level cross-module combinational cone.

## Root Causes

1. The synchronization next-state implementation uses serialized dynamic RID
   writes even though ownership is statically partitioned.
2. DMA evaluates a generic multi-RID dependency array even though its issued
   commands use one wait slot and only four possible RIDs.
3. Same-cycle command acceptance continues through TMEM chaining arbitration
   and aligned DMA descriptor state.
4. Heavy SLR0 placement and global congestion amplify the route portion of the
   already deep logic cone.

## Candidate Fixes

### Preferred: owner-specific parallel synchronization

Compute each RID's next value from its sole legal owner using constant indices.
Keep independent G0/G1 adders, SET muxes for generation counters, and derive
SZ0/SZ1 from next SC/ZP values. For DMA, directly select only G0, G1,
ACC_FREE0, or ACC_FREE1.

Expected critical cone:

```text
child-0 completion
  -> one G0 or G1 adder
  -> four-source DMA selector
  -> target comparison
  -> DMA command valid
```

ACC_FREE release is shorter because it is a SET path rather than an add path.

### Rejected as the first fix: registered synchronization snapshot

A registered snapshot would provide a clean timing cut, but it would move
dependent command issue to the following cycle. That changes a deliberate
same-cycle handoff and can reduce performance at every dependency boundary.

### Follow-up if timing remains insufficient

1. Simplify or physically replicate the DMA four-way selector/comparator.
2. Remove `accepted_high_now` from same-cycle fallback selection with an
   explicitly analyzed arbitration policy.
3. Add a register boundary between TMEM command ingress and chain arbitration.
4. Separate aligned DMA descriptor acceptance from local state launch.
5. Apply physical optimization only after the RTL cone is structurally cut.

## Verification Requirements

### Functional simulation

- G0 and G1 completion release the matching DMA load in the same cycle.
- ACC_FREE0 and ACC_FREE1 SET release the matching DMA store in the same cycle.
- Independent child completions in one cycle retain every update.
- Concurrent SC/ZP completion derives SZ from both next values.
- Tagged out-of-order DMA completion selects the correct legal metadata.
- A simulation-only copy of the legacy reducer matches every optimized RID
  next value on every legal cycle.
- Existing controller/FSM command issue and completion behavior remains valid.

### Synthesis and implementation

The user will run this phase separately. The key checks are:

- the old child-0-through-child-5 carry/mux cascade is absent;
- the DMA dependency selector has four constant-index sources;
- the startpoint-to-`stride_bound_r` path no longer appears as the worst path
  family;
- BRAM and DSP usage do not increase;
- any LUT increase is small relative to the timing improvement;
- hold timing and CDC results do not regress.

## Selected Resolution

Use the owner-specific parallel reduction and DMA four-RID same-cycle selector.
Do not add a synchronization pipeline register. The implementation contract and
simulation results are recorded in
`agent-tasks/th16-parallel-sync-reduction/`.
