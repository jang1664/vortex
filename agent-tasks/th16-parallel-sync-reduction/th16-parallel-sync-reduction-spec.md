# TH16 Parallel GEMM Sync Reduction Specification

Status: confirmed

## Goal

Remove the serialized dynamic-index synchronization reduction and the generic
DMA dependency lookup from the TH16 critical command path without adding a
pipeline stage or changing command issue/completion timing.

The motivating timing analysis and detailed implementation plan are:

- `analysis_workspace/th16_gemm_tmem_dma_critical_path.md`
- `analysis_workspace/th16_parallel_sync_reduction_plan.md`

## RTL Scope

- `hw/rtl/VX_gpu_pkg.sv`
- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`

Testbench-only changes may be made under `hw/unittest/` when necessary to
prove the contract. Synthesis, implementation, placement, and routing are out
of scope for this run.

## Confirmed Design

1. Preserve all existing synchronization RID numeric encodings. Add package
   constants for the currently local IDs T0=0, G0=3, O=4, T1=5, and G1=8,
   then use named package constants in the FSM and controller.
2. Decode each child completion into an event and update every synchronization
   register through an owner-specific, constant-index expression:
   - child 0 adds G0/G1;
   - child 1 sets W0/W1;
   - child 2 sets SC0/SC1;
   - child 3 sets ZP0/ZP1;
   - child 4 sets ACC_FREE0/ACC_FREE1;
   - child 5 sets T0/T1 or adds O;
   - external nodes 1, 2, and 3 add their corresponding W, SC, and ZP consume
     counters.
3. Derive SZ0/SZ1 from the current-cycle next values of SC0/ZP0 and SC1/ZP1.
4. Keep same-cycle dependency release. Do not register the reduction or insert
   a scheduler pipeline stage.
5. For the DMA child, replace the generic five-dependency dynamic lookup with
   a selector for waits[0] over the four legal RIDs G0, G1, ACC_FREE0, and
   ACC_FREE1. Keep the general dependency logic for non-DMA children.
6. Under simulation-only guards, retain a reference implementation of the old
   serialized reduction and assert exact equality with the optimized next
   state. Add assertions for completion owner, operation mode/value, and DMA
   wait-slot/RID legality.

## Behavioral Constraints

- Command valid/ready behavior and done timing remain cycle-identical.
- Multiple independent completions in one cycle must all be retained.
- No legal same-RID completion collision exists; assertions must flag any
  violation of this ownership contract.
- Counter width, wrap behavior, SET semantics, and PLUS semantics are
  unchanged.
- No registered synchronization stage is permitted.

## Simulation Acceptance

- The GEMM controller focused simulation passes and exercises same-cycle sync
  release, DMA waits for G0/G1 and ACC_FREE0/1, concurrent independent
  completion updates, and exact optimized/reference reduction equality.
- The GEMM FSM simulation passes with unchanged RID encodings and command
  metadata.
- Existing relevant GEMM unit or node regression simulations pass if selected
  by the verification role as proportionate coverage.
- No synthesis or implementation tool is run.
