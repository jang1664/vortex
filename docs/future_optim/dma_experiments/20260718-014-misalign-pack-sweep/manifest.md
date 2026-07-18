# DMA OOC Experiment Manifest

| Field | Value |
| --- | --- |
| Experiment ID | `20260718-014-misalign-pack-sweep` |
| Purpose | Estimate the DMA-node misalignment PACK_BYTES area/timing/functional-cycle trade-off |
| Parent design | `20260718-013-misaligned-response-wrbuf1` |
| Fixed baseline | PACK_BYTES=16 in this experiment |
| Production RTL changes | None |
| Measurement harness changes | `ci/run_dma_ooc.sh`, new `hw/syn/xilinx/dut/VX_dma_unit_ooc.sv` |
| Config | `configs/improve_th16_tcol32_hwexp_dcache.sh` |
| Git commit | `498e81c196b9b500fb411f4262af2df7ebc9b738` |
| Git branch | `fpint` |
| Existing user changes | Preserved; see each OOC directory's `git_status.txt` |
| Vivado | 2025.1 |
| Device | `xcu55c-fsvh2892-2L-e` |
| OOC top | `VX_dma_unit_ooc` |
| Constraint | `hw/syn/xilinx/dut/project.xdc`, 100 MHz |
| Unittest | PASS 2,125/2,125 for PACK 4, 8, 16, 32, and 64 |
| xrt-vcs-sim | Not run; measurement-only sweep, required before production adoption |
| OOC synthesis | PASS for 8, 16, 32; TIMEOUT at 30 minutes for 4 and 64 |
| Conclusion | Recommend 8 for area; retain 16 when DMA throughput is the priority |

## Commands

The configured build directory was `build_dma_bram_phase1`.

```text
source configs/improve_th16_tcol32_hwexp_dcache.sh
make SIM_EXEC=vcs PARAMS='-pvalue+tb_VX_dma_mem_unit_misal.PACK_BYTES_P=N' run

source configs/improve_th16_tcol32_hwexp_dcache.sh
env PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python \
  ci/run_dma_ooc.sh --target node-backend --alias C4 \
  --misalign-pack-bytes N --jobs 8 --output-dir OUTPUT
```

The 4-byte and 64-byte synthesis runs were stopped at the experiment's
30-minute per-run limit while in Vivado timing optimization. Their partial
logs and source/config manifests are retained.
