# MXU16 DMA launch buffer cycle analysis

## Change

`hw/rtl/core/gemm/VX_gemm_node.sv` now contains a one-entry registered
`VX_elastic_buffer` between the GEMM controller's normal DMA command output and
the TMEM DMA controller. The buffer captures `cmd`, `cmd_tag`, and valid as one
ready/valid transaction. The separate prepare/lookahead path is unchanged.

## Verification setup

- Configuration: `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`
- Fresh configured build: `build_mxu16_dma_launch_buffer`
- Mode: `xrt-vcs-sim`
- Application: `fpint_gemm_ffn_hw`
- Arguments: `-m 4 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1`
- Five measured runs for both the preserved pre-change binary and the freshly
  compiled buffered binary; every run passed.

The first attempted post-change measurement reused a stale pre-change `simv`.
It was rejected after checking timestamps. All buffered measurements below use
the fresh build whose `simv` was compiled after the RTL modification.

## Results

| Metric | Baseline | Buffered | Delta |
|---|---:|---:|---:|
| Input-packet first-to-last span | 1530 | 1533-1534 | +3 to +4 |
| Compute-fire first-to-last span | 1529 | 1532-1533 | +3 to +4 |
| Final eight store-accept span | 196 | 203 | +7 |
| First DMA accept to last logical completion | 1839 | 1849-1863 | +10 to +24 |
| Host PERF cycles, five-run range | 7525-7533 | 7526-7532 | overlapping |
| Host PERF cycles, median | 7529 | 7528 | no measurable regression |

Four of five buffered runs showed exactly three additional input/compute span
cycles; one showed four. The two 128-column compute phases themselves retained
their original spans. The additional three cycles occur entirely in the phase
transition: the packet boundary gap grows from 127 to 130 cycles.

The final eight output stores are serialized. Their seven launch-to-launch
gaps each grow by exactly one cycle, so the final store command-accept span
grows from 196 to 203 cycles. This is the expected visible cost of registering
a dependency-released DMA command when there is no following work available to
hide its one-cycle launch latency.

The overall program performance counter has run-to-run jitter larger than the
new latency. Its old and new distributions overlap completely, so the buffer
does not cause a measurable end-to-end program slowdown for this case. The
repeatable internal GEMM scheduling cost is approximately three cycles, or
0.20% of the 1529-cycle compute-fire span; the DMA/output tail cost is visible
as the separate seven-cycle final store-launch expansion.
