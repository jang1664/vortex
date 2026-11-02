# TMEM memory-side ownership correction: verification request

## Scope and rationale

The previous feature-enabled mux used the source-side descriptor owner directly
at the memory-side TMEM switch. Its source quiescence output also included the
memory-side reserved-request valid bit. Both dependencies bypassed the existing
registered SLR transport.

Only `hw/rtl/mem/VX_tmem_subsystem.sv` production RTL changed. All additions and
edits are inside `GEMM_SRAM_FUSION`; shared transport and the feature-disabled
branch are untouched. `fusion_tmem_owner` is now crossed bridge request valid OR
`fusion_tmem_pending_q`. The one-bit state sets on local request acceptance and
clears only on local response handshake into the return transport. All mux
selection, urgency, and priority use this local owner. Global descriptor
ownership still excludes GEMM until the complete copy drains.

Quiescence drops only `!input_reserved_to_switch.req_valid`. The source-side
accepted-input count already includes requests queued in the crossing and
retires only when their responses return to the local DMA. Its zero check,
zero scheduler occupancy, all-LDMA-idle check, and
`!ldma_to_switch[0].req_valid` are retained. Simulation assertions check source
count underflow, overlap, premature descriptor release, more than one bridge
request outstanding, response without pending request, and held response
ownership/payload stability.

## Test request

- test_type: new_tb supplement
- test_path: hw/unittest/gemm_node_improve
- sim_tool: vcs
- test_params: M=8 N=128 K=128 QBLK=32
- extra_sim_args: +SRAM_ROUTE +SRAM_LOCAL_OWNER
- configuration: source `configs/c4_sram_fusion.sh`, append `-DXLEN_64`, configured isolated build, `/usr/bin/gcc` and `/usr/bin/g++`
- changed_files: `hw/rtl/mem/VX_tmem_subsystem.sv`, new `hw/unittest/gemm_node_improve/sram_local_owner_tests.svh`, its include/plusarg hook in `tb_VX_gemm_node_improve.sv`, and explicit Makefile header dependency
- implementation-agent simulation status: not run; separate verification required

Run through `tools/verify_rtl.py`. Preserve all existing shared-route cases:
pending GEMM behind bridge response/LMEM physical commits, same-edge bridge
doorbell versus GEMM acceptance, and held GEMM input response before bridge
acquisition. Require their existing numerical/byte checks and all fatal
assertions. Do not reuse or rebuild the live full-decoder build directories.

The new `run_sram_local_owner` entrypoint reuses `fusion_copy`, public MMIO,
the existing modeled LMEM endpoint, and the shared-route scratch offset. It
tests 32-byte and 64-byte roundtrips, holding every memory-side response in both
directions for 64 cycles. At a negative edge after response offer, it masks both
`fusion_tmem.rsp_valid` and `.rsp_ready`, so the return transport captures nothing
and the memory producer receives no handshake. The original
`fusion_switch_in.rsp_valid` and full payload/tag must remain stable, the request
must already be withdrawn, and local pending/ownership and descriptor ownership
must remain asserted. Only bus controls are forced; ownership/state are not.

Resume forces ready to one and releases valid for exactly one sampled
handshake. The next negative edge must show exactly one consumed response,
cleared local pending/owner, an empty switch response, and retained descriptor
ownership. Ready is then released from one: this is the continuous credit-ready
of the depth-four return crossing, unlike the procedural DMA-side ready in the
older test. Counters require each expected request, local response, and DMA-side
response exactly once; a nonzero request-withdrawal/pending interval; and a
nonzero final-response-to-descriptor-drain interval. Existing `fusion_copy`
checks retain physical LMEM completion and zero HBM traffic. Both read results
are checked byte-for-byte, including distinct data in both words of the 64-byte
case. The test explicitly requires the C4 32-byte TMEM beat and SLR transport.

Require the original three `SRAM_ROUTE_CASE PASSED` markers, four new
`SRAM_LOCAL_OWNER_CASE PASSED` markers (both directions, lengths 32 and 64),
`SRAM ROUTE GEMM TEST PASSED`, `SRAM LOCAL OWNER TEST PASSED`, and exit zero.
`+SRAM_LOCAL_OWNER` alone selects the focused supplement for diagnosis; the
requested regression invocation includes both plusargs. The existing three
route cases are not modified. Refresh the isolated build's generated Makefile
or use the source Makefile so the new explicit dependency is present.

Verify selected/preprocessed feature-off identity before versus after this
patch. Include synthesis-mode selection to confirm `fusion_owner_i` is unused
by functional memory-side logic. The root owns floorplan Tcl and physical
crossing audits; no synthesis is requested from this verifier.

## Source and running-simulation provenance

Before source SHA-256:

`d3cfa6185ec3f575f85a7367de3445739887a6544aebc4233315e8aa9ff29b46`

After source SHA-256:

`e2d762f66eb69997df591333523e9505814e757b8853673136982ed2a199ed44`

The before file and machine-readable change record are preserved in
`logs/tmem_local_owner/VX_tmem_subsystem.before.sv` and `source_change.json`.
The live legacy session 5987 and live resident simulation are not restarted;
their compiled TMEM ownership is the before version. Feature-off selected-source
identity can link the legacy result to the new source. Feature-on live results
must not be relabeled as corrected-route execution; separate directed
verification and subsequent integration evidence remain required.
