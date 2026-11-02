# Shared TMEM route directed verification request

- test_type: new_tb supplement
- test_path: hw/unittest/gemm_node_improve
- sim_tool: vcs
- configuration: source configs/c4_sram_fusion.sh, append -DXLEN_64, use configured build directory and /usr/bin/gcc plus /usr/bin/g++
- test_params: M=8 N=128 K=128 QBLK=32
- extra_sim_args: +SRAM_ROUTE
- changed_files: new sram_route_tests.svh, include/plusarg hook in tb_VX_gemm_node_improve.sv, and one explicit Makefile header dependency
- production RTL changes: none
- simulation status: not run by implementation agent

```sh
source configs/c4_sram_fusion.sh
export CONFIGS="$CONFIGS -DXLEN_64"
export CC=/usr/bin/gcc CXX=/usr/bin/g++
python3 tools/verify_rtl.py unittest \
  --path "$PWD/build_c4_sram_fusion/hw/unittest/gemm_node_improve" \
  --sim vcs --params "M=8 N=128 K=128 QBLK=32" \
  --extra-sim-args "+SRAM_ROUTE" --timeout 1800
```

Coordinate the existing build with the root/verifier before running; do not overwrite a live compile. Reconfigure if needed to refresh generated Makefiles. The new include is found through the existing source-directory include path and is listed as an explicit compile dependency. Existing resident and FP32 fixtures are unchanged.

## Case 1: pending GEMM behind final bridge response and physical commits

Preload a 32-byte distinct byte pattern into otherwise unused TMEM via the real bridge. Start its TMEM-to-LMEM copy and wait for the real registered final TMEM response. At a falling edge before consumption, hold both valid and ready at the DMA-facing response boundary. Both are masked because the DMA wait state normally always asserts ready and consumes on valid alone; forcing only its ready output would violate that local implementation contract rather than model a delayed response. The response remains in the existing return cut, and the supplement independently checks complete payload/tag stability and retained ownership during the hold. No production state or source is changed. On resume the fixture explicitly drives ready high for exactly one restored response handshake, then restores the DMA non-wait-state ready value before releasing its procedural force. This avoids simulator variable-release retention; assertions check the handshake and that the held response has left the cut.

Program and publish a real legacy GEMM while the response remains held. Require queued cfg.valid without cfg acceptance or child launch, reject a duplicate bridge doorbell with BUSY, then release the held response after at least 64 more cycles. The modeled LMEM endpoint already delays each physical write by seven cycles. Require the final store's pending interval to retain bridge ownership and block cfg acceptance. At actual GEMM cfg acceptance, all four 8-byte stores must have committed, both bridge request cuts must be empty, the final response must have been consumed exactly once, and bridge ownership must be gone.

Check byte identity in LMEM, exactly one accepted bridge command/request/response, exactly one GEMM cfg acceptance, and normal numerical GEMM output. Output memory is poisoned before each case so an old answer cannot satisfy the numerical check.

## Case 2: same-edge public DMA doorbell and pending GEMM cfg

Program the second GEMM through the normal MMIO helper while a separate driver waits for dispatcher cfg.valid. Publishing CONTROL at a rising edge makes cfg.valid visible afterward; the independent fusion helper asserts its doorbell on the intervening falling edge. On the next rising edge the monitor requires both offered operations, accepted DMA doorbell, blocked GEMM cfg.ready, and an idle bridge/controller before acquisition. This exercises the actual combinational arbitration through public MMIO; it does not force cfg.valid, cfg.ready, controller state, or owner.

The expected winner is the SRAM bridge. The GEMM remains pending and must start exactly once after physical copy drain, then pass the same numerical check. Missing the simultaneous collision is a fatal coverage failure, not an accepted alternate outcome. Verify copied bytes and the same final-commit ordering counters.

## Case 3: delayed GEMM input response before bridge acquisition

Run a third real legacy GEMM and hold its first offered input response at the input-DMA boundary, using the same complete valid/ready hold technique. The existing input reservation return cut retains the payload. Require the input accepted-request count and scheduler slot occupancy to remain positive, input-route quiescence false, and bridge ownership absent throughout the hold. A real bridge MMIO doorbell during this interval must report BUSY and launch no command.

After at least 64 hold cycles, resume the input response to its original GEMM owner, then require the GEMM numerical output to pass. Before retrying the bridge doorbell, require retired controller state, empty input accepted-request count, and zero slot occupancy. The retry must launch once and copy the expected bytes. This covers GEMM-to-bridge handoff with actual delayed response and pending reservations; it does not isolate each quiescence gate independently because an unfinished GEMM invocation is also a valid reason to reject acquisition.

## Required evidence and limits

Require all three `SRAM_ROUTE_CASE PASSED` markers and `SRAM ROUTE GEMM TEST PASSED`, with numerical checks and no assertion failures. Case1 must report held_response_cycles>=64 and final_commit_wait_cycles>0. Case2 must report same_edge=1. Case3 must report input_response_hold_cycles>=64, pending_and_slot_witness=1, rejected_busy_start=1, and bridge_launches=1. All commands and responses are real node traffic; Case1 and Case3 use force/release solely for artificial response delays.

This covers the current single-outstanding bridge, one TMEM response per 32-byte copy, deferred GEMM acceptance, deferred bridge acquisition with pending GEMM input reservations, and same-edge bridge-first arbitration. It does not claim concurrent GEMM/bridge execution, randomized arbitration coverage, or physical FPGA timing. No assertions are disabled or weakened; no synthesis is requested.

## Iteration note

The first run failed at 3635 ns because the initial Case1 fixture released a procedurally driven ready variable from forced zero while the DMA state was unchanged. Ready retained zero, while continuous response-valid immediately returned; the DMA advanced without the return cut consuming its response. The revised fixture explicitly restores a complete one-cycle valid/ready handshake and checks response removal. This is a fixture correction, not a production RTL change or an assertion relaxation. The failed log is preserved as sim_SRAM_SHARED_ROUTE.log until the verifier archives/reruns it.
