# DMA OOC Experiment Manifest

| Field | Value |
| --- | --- |
| Experiment ID | `20260718-013-misaligned-response-wrbuf1` |
| Purpose | Optimize misaligned DMA response and request payload storage under C4 |
| Comparison rule | Compare only with an OOC run using identical synthesis inputs |
| Changed production RTL | See `git_status.txt` and the parent experiment manifest |
| Config | `/home/jaeyongjang/project.local/vortex_fpint/configs/improve_th16_tcol32_hwexp_dcache.sh` |
| Git commit | `9960894ada773fcf3c8bb53001f6135ae877fbc9` |
| Git state | `git_status.txt` |
| Vivado | `v2025.1 (64-bit)` |
| Device | `xcu55c-fsvh2892-2L-e` |
| OOC top | `VX_dma_engine_ooc` |
| Constraint | `hw/syn/xilinx/dut/project.xdc` |
| Unittest | PASS, 2,125/2,125 for 64/128, 64/64, and 128/64 byte widths |
| xrt-vcs-sim | PASS, softmax opt, seqk=17, 39,077 cycles, max abs diff 0.000061 |
| OOC synthesis | PASS; see `post_synth_util.rpt` and `post_synth_timing_summary.rpt` |
| Checkpoint | `not-retained` |
| Conclusion | Retain response SRAM, control-only read queues, and 1-entry write holding buffers |

The synthesis script performs only the OOC stage. The unittest and xrt-vcs-sim
results above were run separately from the configured
`build_dma_bram_phase1` build directory.
