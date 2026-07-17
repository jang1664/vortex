# C4 DMA OOC Result

- Alias: `C4`
- OOC top: `VX_dma_engine_ooc`
- Device: `xcu55c-fsvh2892-2L-e`
- Config: `/home/jaeyongjang/project.local/vortex_fpint/configs/improve_th16_tcol32_hwexp_dcache.sh`
- Git commit: `502a49dbb52cb78858d481c8cde29728045551b2`
- OOC report: `post_synth_util.rpt`
- OOC DMA engine row: `ooc_dma_engine.csv`
- OOC drain buffer rows: `ooc_dma_buffers.csv`
- Historical reference: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/bin/hier_utilization.rpt`

| Metric | OOC post-synthesis | Historical C4 post-route | Delta | Delta (%) |
| --- | ---: | ---: | ---: | ---: |
| LUT | 27259 | 54869 | -27610 | -50.32% |
| FF | 12560 | 48320 | -35760 | -74.01% |
| RAMB36 | 56 | 0 | 56 | n/a |
| RAMB18 | 16 | 8 | 8 | +100.00% |
| URAM | 0 | 0 | 0 | n/a |
| DSP | 128 | 128 | 0 | +0.00% |

The OOC report is a post-synthesis result for `VX_dma_engine_ooc`. The historical C4
report is a post-route full-design report. Their absolute utilization values
are recorded for context but are not directly comparable. Compare DMA variants
against a fixed OOC baseline produced with the same top, config, part,
constraints, Vivado version, and synthesis options.
