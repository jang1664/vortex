# Full-core upstream publication stress request

- test_type: new_tb supplement, exercised through the existing blackbox harness
- sim_tool: vcs / xrt-vcs-sim
- changed_files: sim/xrtsim_vcs/sram_publish_stress.svh and a guarded include in sim/xrtsim_vcs/tb_vcs_xrtsim.sv
- production RTL changes: none
- application: flash_attn -r -f -m 1 -n 128
- additional configuration: -DSRAM_PUBLISH_STRESS
- compile/debug: --debug 1 enables VCS force/release visibility; no FSDB dump is needed

## Reproducer

Use a separate configured build directory to avoid overwriting another full-core simulation. Commands are for Bash, from the repository root:

```sh
source configs/c4_sram_fusion.sh
export CC=/usr/bin/gcc CXX=/usr/bin/g++
mkdir -p build_c4_publish_stress
cd build_c4_publish_stress
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
ci/run_black.sh xrt-vcs-sim --app flash_attn \
  --args "-r -f -m 1 -n 128" \
  --configs-extra "-DSRAM_PUBLISH_STRESS" --debug 1
```

Run via the project's verification role and standard run-bb-common procedure. No execution has been performed by the fixture implementation agent.

## Selected producer and ordering claim

The default selected address is LMEM_BASE_ADDR+0x1600. For this exact FP32 M1 case, padded rows=8 and KV tile=128. The score/PV workspace takes4096 bytes, the separate FP16 probability buffer begins at offset0x1000, and warp0's final initialization store begins at probability word192 (byte1536). Its address is therefore offset0x1600. This is a real kernel producer store immediately before the producer's publication phase; stack traffic is excluded.

The fixture records the producing warp when that store enters the actual LSU request FIFO. At the following memory-unit interface, it holds both request valid and request ready low for256 cycles, while leaving the real FIFO payload connected. Both directions must be paused: forcing only ready would allow downstream duplicate acceptance; forcing only valid would allow upstream loss. All hold/release actions occur on falling edges. The fixture asserts that the FIFO payload remains unchanged throughout the hold.

During the hold, the memory-unit accepted-store accounting must become empty at least once. This is the important coverage witness: the withheld store is still upstream and is not protected by that accounting alone. A later PUBLISH from the same producer is identified using the complete LSU core-side request tag, including warp and PC, and its actual response handshake must follow the selected store's memory-unit admission. Another warp's legitimate PUBLISH does not satisfy this check.

The fixture reports whether the producer's PUBLISH was already queued while the store was held. This observation is informational: the producer may itself stall on an intervening load before it can issue PUBLISH. The test does not claim every upstream queue was independently forced or that PUBLISH necessarily reached the FIFO during the hold. It proves that an actual producer store can remain upstream of the accounting while its own eventual publication response cannot precede its admission, and that the whole kernel still produces correct data after release.

The existing sram_lmem_publish unit test remains the evidence for delayed physical bank commit after memory-unit admission; this supplement does not duplicate that fixture or add memory ports.

## Required pass evidence

- `SRAM_PUBLISH_STRESS holding ...`
- `SRAM_PUBLISH_STRESS store admitted after 256 blocked cycles`
- `SRAM_PUBLISH_STRESS PASSED ... empty_accounting_witness=1`
- The normal flash_attn numerical/host checks pass.
- No assertion/fatal error. Ending the simulation without completing the selected producer publication is a fatal fixture failure.

A runtime override can use VCS_SIMV_FLAGS with `+publish_stress_addr=<hex byte address>` and `+publish_stress_cycles=<16..65536>`. Changing the workload requires recomputing the selected address; absence of the selected store fails coverage. The fixture is restricted to the C4 single-core, single-LSU, XLEN64 setup. With SRAM_PUBLISH_STRESS absent, the include and all force/monitor logic are absent.
