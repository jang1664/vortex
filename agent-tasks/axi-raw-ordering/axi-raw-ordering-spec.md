# AXI RAW ordering protection

Status: confirmed by user instruction on 2026-10-04.

## Goal
Prevent a younger CPU/cache read from observing stale memory while an older write
is buffered in downstream AXI channels. Preserve throughput with low hardware cost.

## Confirmed implementation sequence
1. Implement pending-write counters per physical HBM port. Wait for B completion
   before admitting dependent read traffic on that port; preserve VALID stability.
2. Verify the known softmax VCS reproducer and compare cycles against the original
   adapter using the same config, kernel and memory settings. At >=3% degradation,
   replace broad serialization with inflight-write address tracking using VX_dp_ram.
3. Use actual VX_dp_ram for RAM-backed tracking, not a parallel flop-array imitation.

## Scope
VX_axi_adapter and narrowly scoped helper modules, existing or new adapter unit
coverage. No kernel changes, FPGA reruns, synthesis, pipeline restart or unrelated
RTL cleanup. Running rev3 FPGA pipeline and monitoring continue unchanged.

## Evidence / constraints
- Read docs/softmax_l2_vcs_debug_20261004 under analysis_workspace/latency_on_hw.
- First bad reload: PC 0x180000314, stack address 0x1ffbddec0, expected 2 but got 0.
- Kernel SHA256 fde8a343d616acffc607ade3d3d036a287021e1c83645ec0b07097561da5ec82.
- C4 v4, TH16/MXU16, Q=K=32, batch/head=1, mask=1, scale=.125,
  input seed 2986547050. Original normal cycles 164179; in-order stressed 286220;
  reordered stress 283695 (incorrect). Memory stress seed19 req50/10 rsp75/5.
- Use normal-memory PASS baseline for primary performance decision. Also report
  the matched in-order stressed PASS control and reordered correctness results.
- Handle AW/W independent handshakes, delayed/out-of-order B across IDs, ID reuse,
  simultaneous retire/acquire, finite-capacity backpressure, and held ARVALID.
- Register downstream admission decisions; do not drop asserted ARVALID under stall.
- All simulations from configured independent build directories with sourced configs.
- No production timing/synthesis conclusions from simulation-only diagnostics.

## Measurement decision (2026-10-04 03:15)
Primary normal-memory loss is only 0.07309%, but matched correct in-order stress
loses 6.355%. To meet the user's broader >=3% condition under measured pressure,
phase2 RAM-backed inflight-write tracking is now authorized and required.

## Depth sweep (confirmed user request, 2026-10-04)
Increase RAM-backed inflight-write depth and measure performance saturation.
Expose an RTL config define while preserving default16 until measurements justify
a change. Compare depths16/32/64/128 on the same TH16/MXU16 in-order stressed
softmax probe, then verify the selected depth under normal/reordered conditions.
Collect experiment-only occupancy/backpressure/query counters. Add a controlled
write-pressure microbenchmark sweeping through256/512 if useful, since a small
softmax kernel may not fill the table. Keep production instrumentation absent.
Distinguish logical address RAM capacity from synthesized physical BRAM usage;
ID/mask registers and combinational search cost also grow with depth.
