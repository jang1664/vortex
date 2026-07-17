# C4 DMA OOC Result

- Alias: `C4`
- OOC top: `VX_dma_engine_ooc`
- Device: `xcu55c-fsvh2892-2L-e`
- Config: `/home/jaeyongjang/project.local/vortex_fpint/configs/improve_th16_tcol32_hwexp_dcache.sh`
- Git commit: `9960894ada773fcf3c8bb53001f6135ae877fbc9`
- OOC report: `post_synth_util.rpt`
- OOC DMA engine row: `ooc_dma_engine.csv`
- OOC drain buffer rows: `ooc_dma_buffers.csv`
- Reference report: `/home/jaeyongjang/project.local/vortex_fpint/docs/future_optim/dma_experiments/20260717-010-misaligned-response-baseline/post_synth_util.rpt`

| Metric | OOC post-synthesis | Reference report | Delta | Delta (%) |
| --- | ---: | ---: | ---: | ---: |
| LUT | 155937 | 158803 | -2866 | -1.80% |
| FF | 32419 | 40264 | -7845 | -19.48% |
| RAMB36 | 56 | 128 | -72 | -56.25% |
| RAMB18 | 32 | 24 | 8 | +33.33% |
| URAM | 0 | 0 | 0 | n/a |
| DSP | 128 | 128 | 0 | +0.00% |

Both reports are C4 post-synthesis results for `VX_dma_engine_ooc` produced
with the same config, part, constraints, Vivado version, and synthesis options.
The deltas are directly comparable.

## Variant comparison

| Variant | LUT | FF | RAMB36 | RAMB18 | WNS (ns) | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 010 baseline | 158,803 | 40,264 | 128 | 24 | +0.350 | Reference |
| 011 response SRAM only | 159,797 | 31,450 | 184 | 32 | +0.888 | Reject: LUT and BRAM increase |
| 012 response SRAM + direct write | 160,453 | 22,624 | 56 | 32 | +0.687 | Reject: LUT increase and backpressure loss |
| 013 response SRAM + 1-entry write buffer | 155,937 | 32,419 | 56 | 32 | +0.915 | Retain |

Counting one RAMB18 as half a RAMB36, 013 reduces equivalent BRAM from 140 to
72 (-48.6%). It also reduces LUT by 1.8% and FF by 19.5%, while improving WNS
by 0.565 ns.

## Functional and cycle checks

The configured-build VCS unittest passed 2,125 of 2,125 cases for every final
width configuration. It includes misaligned source/destination offsets,
padding, partial beats, periodic read/write backpressure, and request stability
while stalled.

| Configuration | Final simulation time |
| --- | ---: |
| DCache 64 B / LMEM 128 B / pack 16 B | 2,854,775 ns |
| DCache 64 B / LMEM 64 B / pack 16 B | 2,946,325 ns |
| DCache 128 B / LMEM 64 B / pack 16 B | 2,790,565 ns |

The 64/128 baseline completed at 2,739,165 ns. The retained version is 4.2%
slower under the unittest's aggressive two-ready/three-blocked request pattern.
The rejected direct-write version was 14.6% slower, which is why the 1-entry
write holding stage is retained.

The final xrt-vcs-sim softmax `opt` run with `seqk=17` passed with a maximum
absolute difference of 0.000061 at 39,077 cycles. The response-SRAM-only run
used 39,069 cycles, so the write holding stage changes this workload by 8
cycles (0.02%). FSDB generation was disabled with `DISABLE_FSDB`.
