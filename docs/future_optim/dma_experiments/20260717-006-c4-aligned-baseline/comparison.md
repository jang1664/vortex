# C4 DMA OOC Baseline

- Alias: `C4`
- OOC top: `VX_dma_engine_ooc`
- Device: `xcu55c-fsvh2892-2L-e`
- Config: `/home/jaeyongjang/project.local/vortex_fpint/configs/improve_th16_tcol32_hwexp_dcache.sh`
- Git commit: `502a49dbb52cb78858d481c8cde29728045551b2`
- OOC report: `post_synth_util.rpt`
- OOC DMA engine row: `ooc_dma_engine.csv`
- OOC drain buffer rows: `ooc_dma_buffers.csv`
- Historical reference: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/bin/hier_utilization.rpt`

## DMA Engine Utilization

The table compares the `u_dma_engine` child rather than the flat OOC wrapper.
The wrapper itself contributes 64 FF.

| Metric | OOC post-synthesis | Historical C4 post-route | Delta | Delta (%) |
| --- | ---: | ---: | ---: | ---: |
| LUT | 54,588 | 54,869 | -281 | -0.51% |
| FF | 47,586 | 48,320 | -734 | -1.52% |
| RAMB36 | 0 | 0 | 0 | n/a |
| RAMB18 | 8 | 8 | 0 | 0.00% |
| URAM | 0 | 0 | 0 | n/a |
| DSP | 128 | 128 | 0 | 0.00% |

The resource mix is close enough to confirm that the OOC wrapper preserved the
C4 improve DMA structure: eight channels, eight RAMB18 blocks, and 128 DSPs.
The absolute LUT/FF deltas are context only. The OOC report is post-synthesis,
while the historical C4 report is post-route inside the full design, so this
is not an optimization result or an apples-to-apples utilization comparison.

## Drain Buffer Baseline

The new OOC result is the fixed baseline for subsequent DMA drain experiments.
Totals below sum all eight channel instances from `ooc_dma_buffers.csv`.

| Buffer | OOC LUT | OOC FF | Historical LUT | Historical FF |
| --- | ---: | ---: | ---: | ---: |
| `dcache_req_buf` | 12,580 | 9,728 | 13,553 | 9,712 |
| `lmem_req_buf` | 1,586 | 9,728 | 872 | 9,408 |
| `wr_slot_buf` | 18,174 | 8,320 | 17,164 | 8,320 |
| Total | 32,340 | 27,776 | 31,589 | 27,440 |

The same post-synthesis versus post-route limitation applies to these buffer
rows. Future variants must be compared against the OOC columns using the same
top, config, part, constraints, Vivado version, and synthesis options.

## Timing Estimate

The 100 MHz OOC constraint passed with WNS `+3.853 ns` and TNS `0.000 ns`.
Vivado reports that all specified timing constraints are met. Because the OOC
clock has no implemented clock root, this is a synthesis estimate rather than
a substitute for full-design post-route timing.
