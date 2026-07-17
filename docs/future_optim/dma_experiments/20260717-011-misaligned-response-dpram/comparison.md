# C4 DMA OOC Result

- Alias: `C4`
- OOC top: `VX_dma_engine_ooc`
- Device: `xcu55c-fsvh2892-2L-e`
- Config: `/home/jaeyongjang/project.local/vortex_fpint/configs/improve_th16_tcol32_hwexp_dcache.sh`
- Git commit: `9960894ada773fcf3c8bb53001f6135ae877fbc9`
- OOC report: `post_synth_util.rpt`
- OOC DMA engine row: `ooc_dma_engine.csv`
- OOC drain buffer rows: `ooc_dma_buffers.csv`
- Historical reference: `/home/jaeyongjang/project.local/vortex_fpint/docs/future_optim/dma_experiments/20260717-010-misaligned-response-baseline/post_synth_util.rpt`

| Metric | OOC post-synthesis | Historical C4 post-route | Delta | Delta (%) |
| --- | ---: | ---: | ---: | ---: |
| LUT | 159797 | 158803 | 994 | +0.63% |
| FF | 31450 | 40264 | -8814 | -21.89% |
| RAMB36 | 184 | 128 | 56 | +43.75% |
| RAMB18 | 32 | 24 | 8 | +33.33% |
| URAM | 0 | 0 | 0 | n/a |
| DSP | 128 | 128 | 0 | +0.00% |

The OOC report is a post-synthesis result for `VX_dma_engine_ooc`. The historical C4
report is a post-route full-design report. Their absolute utilization values
are recorded for context but are not directly comparable. Compare DMA variants
against a fixed OOC baseline produced with the same top, config, part,
constraints, Vivado version, and synthesis options.
