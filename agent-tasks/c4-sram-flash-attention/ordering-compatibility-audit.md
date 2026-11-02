# C4 SRAM fusion ordering and compatibility audit

## Scope and status

Read-only RTL audit on 2026-10-23. No RTL sources or running full-core build outputs were changed. The existing actual-memory publication fixture and resident node M1/M4/M16 cases pass. This audit establishes the source-level C4 producer ordering argument and identifies the remaining dynamic and structural evidence. It does not claim full-core, elaborated, or cycle identity.

## Producer publication before the memory-unit admission point

C4 selects NUM_WARPS=4, ISSUE_WIDTH=1, NUM_OPCS=1, NUM_LSU_BLOCKS=1, SIMD_WIDTH=NUM_LSU_LANES=16. There is no per-warp choice of LSU execution block in this configuration.

1. `VX_ibuffer.sv` has an instruction FIFO per warp. The scoreboard takes each warp's FIFO head. `VX_operands.sv` maps a warp to a fixed operand collector; C4 has one collector. `VX_opc_unit.sv` holds the current instruction until its operand fetch completes, then advances its ordered output pipeline.
2. `VX_dispatch_unit.sv` uses one LSU output elastic buffer. Its dispatch input is released only when all SIMD packets of that instruction have been accepted.
3. `VX_lsu_slice.sv` feeds `VX_mem_scheduler.sv` with equal CORE_REQS and MEM_CHANNELS and equal WORD_SIZE and LINE_SIZE. Thus COALESCE_ENABLE=0 and MEM_BATCHES=1. The request FIFO is popped only after its head is accepted by the memory unit. A later PUBLISH load cannot bypass an earlier store in this FIFO.
4. `VX_mem_unit.sv:280` counts active local-store lanes on the memory-unit input handshake, before the local output buffer, LSU lane adapter, lane DMA arbiter, and LMEM crossbar. MMIO address exclusion matches `VX_lmem_switch.sv` address priority.
5. `VX_local_mem.sv` decrements that accounting on actual CPU-origin bank writes. `fusion_lmem_published_o` also excludes stores admitted in the current cycle, so a same-cycle new admission cannot be mistaken for an empty domain.
6. A PUBLISH read is accepted by `VX_sram_fusion_ctrl` only while the accounting is empty. Software uses compiler memory barriers around the volatile read, and each producer calls it before joining. This does not rely on a control warp fence draining other producers.

This argument applies to the intended uniform LMEM store instructions followed by a separate uniform MMIO read. It is not a claim that an arbitrary heterogeneous per-lane mixed MMIO/local instruction has been tested. The current publication fixture starts at the memory-unit input; the issue, operand, dispatch, and LSU scheduling path above has been audited but not dynamically stressed by that fixture. The full-core resident test exercises the path functionally. A targeted backpressure test is still required to establish delayed upstream admission coverage.

## Shared TMEM route ownership

Acquisition requires controller FSM/scheduler quiescence, no live invocation or pending completion, all local DMA engines idle, input reservation occupancy zero, no accepted-but-unreturned input request, no live input request, and empty bridge request cuts. A same-edge command doorbell drives bridge_busy so GEMM cannot concurrently accept a new invocation.

The TMEM mux is downstream of the existing input reservation. `fusion_input_pending_q` begins at the input DMA-to-reservation handshake and ends at the returned response handshake, so registered reservation and return paths are included. The active-owner assertion checks that pending input work and the reserved request interface are empty.

Bridge ownership is held by launch_q OR DMA busy. The single-outstanding bridge waits for every TMEM read/write response and every physical LMEM write commit. Its final state still asserts busy; only the following idle state releases ownership. Consuming the final response also drains its packet from the return cut. The node's release assertion directly checks both request cuts. It does not independently count responses in the return cuts; response-drain correctness currently follows from the single-outstanding DMA state machine and is covered indirectly by completion testing.

No correctness change was identified in this read-only pass. Remaining directed coverage should delay the final TMEM response and physical LMEM write, attempt a GEMM doorbell while the bridge owns the route, and verify owner never changes before the delayed event. Include a bridge doorbell on the same cycle as a pending GEMM configuration handshake. Adding a simulation-only accepted/returned bridge-response counter would strengthen the release assertion without widening the hardware interface, but is not needed to repair an observed failure.

## Feature-off selected source evidence

`logs/feature_off_identity/manifest.json` records all eight touched tracked RTL files and their source hashes. After preprocessing with the base rev8 C4 configuration and XLEN64, all nonblank lines are byte-identical to Git HEAD. Removing only line directives leaves blank-line differences. The source hashes still match at this audit. New feature modules are unreachable when GEMM_SRAM_FUSION is absent. This is selected-source evidence, not an elaborated-netlist comparison.

## Attempted elaboration evidence

Reproducer, exact commands, source hashes, and logs are under `logs/elaborated_identity/`. Run from the repository using Bash:

```sh
source configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh
python3 agent-tasks/c4-sram-flash-attention/logs/elaborated_identity/audit.py
```

The script uses the already configured build directory only as its working directory and writes all artifacts into its isolated audit directory. It copies the eight original modules from Git HEAD to a baseline search overlay and runs Verilator XML elaboration of VX_core_top for both versions. It performs no simulation or synthesis. The planned comparison retains the complete XML netlist and removes only source-location attributes.

Both elaborations fail identically in the unchanged `VX_slr_mem_bus.sv:22`, `:23`, and `:47`: installed Verilator 5.028 rejects interface-field `$bits` expressions as parameter-resolved constants, then reports an internal width error. The manifest status is `elaboration_failed` and identity is null. No selected configuration, shared primitive, or RTL source was changed to bypass this error. This failure cannot be interpreted as a structural mismatch or structural pass.

## Concrete remaining verification request

- test_type: unittest plus blackbox
- sim_tool: vcs
- test_path: hw/unittest/gemm_node_improve, followed by the existing legacy decoder regression
- configurations: identical base C4 with GEMM_SRAM_FUSION absent, in isolated baseline-HEAD and current-source configured build directories; separately current-source feature-on with resident flags zero and bridge unused
- test_params: reuse exactly the same established legacy GEMM shapes, seeds, AXI stalls, and padded short-row cases in all runs; maintain the 44-word descriptor ABI
- required evidence: numerical pass, descriptor progress/retirement match, identical GEMM and core cycle counts for the feature-off baseline/current pair; record the feature-on legacy pair separately rather than conflating it with feature-off identity
- structural request: use the supported VCS elaboration/debug database flow to enumerate reachable core/GEMM/TMEM/LMEM modules, instance connectivity, port/type widths, array extents, parameter values, and storage declarations for both feature-off builds. Compare normalized hierarchy and type records after removing source locations and build paths. No fusion control/DMA instance may be present. Preserve raw dumps and source/config/tool hashes. This is required because the attempted Verilator XML path cannot elaborate the existing SLR primitive.
- upstream publication stress request: run actual producer instructions with a prior store delayed before the memory-unit handshake, then with LMEM bank commit delayed after admission; require the same producer's PUBLISH response to remain blocked through both intervals and verify the copied bytes after producer join.
- do not reuse or reconfigure the actively running build_c4_sram_fusion for baseline comparison; do not run synthesis.

Until those requests complete, feature-off elaborated identity, measured zero-cycle delta, and full upstream publication stress remain unproven.

## Evidence update after revision2 full-core runs

The original read-only audit above is historical; these later artifacts resolve
some of its open requests without broadening their claims:

- `compatibility-verification.md` and `logs/compatibility_vcs/summary_fp32.json`
  establish feature-off whole-core VCS structural identity (167440 normalized
  records) and the named legacy GEMM cycle checks (8406 full-core cycles).
  `logs/feature_off_identity_fp32/postfix_snapshot_linkage.json` links the later
  feature-only ACC flattening correction to that compiled snapshot. The failed
  Verilator XML attempt is not used as evidence.
- `logs/simv_publish_fp32_m1_n128.log` records a real producer's LMEM store held
  for 256 cycles before memory-unit admission, including a witness of empty
  accepted-store accounting. Its later PUBLISH response and final numerical
  output pass. The monitor reports `publish_queued_during_hold=0`; it does not
  claim that a PUBLISH already offered to the controller was held during that
  interval. The in-order LSU argument and actual-bank delayed-commit fixture
  remain part of the combined ordering evidence.
- `shared-route-test-request.md` tracks the directed handoff supplement. Its
  first run failed because the fixture released a forced procedural ready
  signal without restoring its value, leaving a stale response in the return
  cut. No production RTL defect has been established by this failure. The repaired
  iteration2 now passes all three cases: final bridge response held157cycles,
  same-edge bridge/GEMM collision, and GEMM input response held70cycles with
  pending-request/slot witnesses before a rejected bridge launch. Each GEMM
  output and the copied bytes pass. See `logs/shared_route_iter2_pass.log`
  and `logs/shared_route_iter2_provenance.json`. Combined quiescence is checked;
  individual acquisition gates are not isolated independently.
- A full legacy decoder run is still in progress. Neither its successful
  compilation nor the isolated legacy GEMM checks establish decoder correctness.

The original requirements for destination commit, upstream publication,
exclusive ownership, and no intermediate tensor HBM access remain unchanged.
