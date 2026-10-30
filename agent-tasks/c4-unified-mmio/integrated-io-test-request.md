# Integrated GEMM SRAM I/O verification request

Implementation: `hw/rtl/core/gemm/VX_gemm_sram_io.sv` and its node/core integration.
Unit target: configured-build `hw/unittest/gemm_node_improve`, VCS, named C4 SRAM config sourced first. Run through `tools/verify_rtl.py` under the verification agent.

Run `+SRAM_UNIFIED +M=4 +N=128 +K=128 +QBLK=32` with the existing test's WTRANS/QDIR argument names; repeat with `+SRAM_FP32`, then M=1 and M=128 as practical. The existing `+SRAM_RESIDENT` alias invokes the same new scenarios. Source Makefile includes the serializer and sequencer modules. Old sidecar-specific route/boundary/local-owner scenarios now explicitly reject obsolete arguments; they are not claimed as covered.

New scenarios reuse the existing independent numeric reference and delayed physical LMEM endpoint:
- Legacy HBM GEMM before and after extended descriptors.
- Capability 0x53465203 and global publication blocked while producer stores are unpublished.
- Copy-only LMEM-to-TMEM-to-LMEM byte roundtrip, with no HBM traffic.
- GEMM HBM input to LMEM output; implicit LMEM input transfer to LMEM output; TMEM input reuse to LMEM output.
- Poison HBM input for LMEM/TMEM jobs and check actual accepted HBM requests.
- FP32 output above FP16 finite range, both half-row beats/backpressure, then FP16 without reset.
- Invalid shape/options/address: ordinary completion with errors 1/2/3 and no memory activity.
- Completion cannot precede final physical LMEM commit; output padding retains initialized zeros.

Expected terminal message: `SRAM UNIFIED GEMM TEST PASSED`. Numeric and no-HBM-intermediate assertions must also pass. Full-core kernels are owned by the root agent. Feature-off legacy compile/run must retain the original 44-word descriptor and original issue/done interfaces.

Floorplan changes only classify the CPU serializer, require the one remaining GEMM MMIO transport, and recognize new sequencer endpoints. No synthesis or PnR was run by the implementation agent.
