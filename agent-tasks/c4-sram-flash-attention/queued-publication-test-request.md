# Queued publication with an unadmitted producer store

- test_type: testbench-only supplement
- test_path: hw/unittest/sram_lmem_publish
- sim_tool: vcs
- configuration: source configs/c4_sram_fusion.sh; append -DXLEN_64 -DSRAM_PUBLISH_UPSTREAM_TEST
- changed_files: sram_publish_upstream_tests.svh, guarded include in tb_VX_sram_lmem_publish.sv, source include directory in Makefile
- production RTL changes: none
- simulation status: not run by implementation agent

Use a configured build directory and system host compilers. Refresh its generated Makefile if it predates this supplement. Generate its hardware config before compilation. Coordinate the build directory with the root/verifier so no running job is overwritten.

```sh
source configs/c4_sram_fusion.sh
export CONFIGS="$CONFIGS -DXLEN_64 -DSRAM_PUBLISH_UPSTREAM_TEST"
export CC=/usr/bin/gcc CXX=/usr/bin/g++
python3 tools/verify_rtl.py unittest \
  --path "$PWD/build_c4_sram_fusion/hw/unittest/sram_lmem_publish" \
  --sim vcs --timeout 1800
```

The supplement reuses the existing real VX_mem_unit, VX_sram_fusion_ctrl, LMEM crossbar, and physical banks. It adds the production VX_lsu_slice and its real VX_mem_scheduler request FIFO. Adjacent execute handshakes issue SD then LWU of PUBLISH from the same warp. Both valid and ready are held at the LSU/memory-unit request boundary, while the physical destination bank is also blocked. No state, counters, queue contents, owner signals, or publication outputs are forced.

The required overlap witness is an actual PUBLISH handshake into the production scheduler while the request FIFO head remains the producer store with the expected address and data. During the input hold, the accepted-store counter must remain zero and published must remain true; no physical commit or PUBLISH result is permitted. This directly exercises the accounting gap without fabricating a pending-store count.

After restoring the input boundary, require PUBLISH to reach the real MMIO path while the one admitted store remains physically blocked. For at least 32 such cycles, published must be false and neither the MMIO request nor its result may complete. Release the physical bank, require exactly one CPU commit, PUBLISH result one through the real LSU load formatter, and exact 64-bit LD readback. Repeat sequentially for warp IDs 0 and 1 with different eight-byte patterns. Each phase has a bounded timeout and the existing global timeout remains active.

Require both `UPSTREAM PUBLISH CASE PASSED` markers, `SRAM LMEM UPSTREAM PUBLICATION PASSED`, and `OUTPUT CHECK PASSED`, with no fatal/assertion failures. Coverage must report:

- queued_during_hold=2
- counter_empty_held_cycles >= 64
- bank_blocked_publish_cycles >= 64
- cpu_commits=2
- publish_results=2
- readbacks=2
- bytes=16

Also rerun the original publication fixture without SRAM_PUBLISH_UPSTREAM_TEST, preserving its physical CPU-store and DMA-source-tag coverage. The supplement contains no reset-cancellation case and does not establish arbitrary concurrent producer interleavings or ordering through earlier core issue stages. The existing full-core stress remains complementary evidence; this test specifically closes the real-LSU queued-publication overlap gap.
