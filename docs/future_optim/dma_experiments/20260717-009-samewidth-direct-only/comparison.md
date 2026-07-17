# Same-Width Direct-Data-Only Comparison

Experiment 009 isolates optimization 1 from experiment 008's output broadcast.
All OOC results use the C4 config, `VX_dma_engine_ooc`, the U55C part, Vivado
2025.1, and a 100 MHz constraint.

## Implementation

The direct-only variant keeps these experiment 008 changes:

- Zero invalid trailing bytes once when a response is captured into RAM.
- Select zero for a padding-only destination beat with no response slot.
- Feed the registered same-width RAM result directly through the destination
  write-data assembler instead of rebuilding it with per-byte loops.

It removes the broadcast optimization:

- DCACHE and LMEM request data are direction-specific again.
- A source read drives zero data independently of the destination RAM output.
- Source-read backpressure no longer stalls the opposite destination or the
  response RAM read stage.

The unequal-width path is unchanged.

## OOC Utilization

| Metric | Baseline 006 | DPRAM 007 | Broadcast 008 | Direct-only 009 | 009 vs 007 |
| --- | ---: | ---: | ---: | ---: | ---: |
| LUT | 54,588 | 34,635 | 27,259 | 28,922 | -5,713 (-16.49%) |
| FF | 47,586 | 12,544 | 12,560 | 12,522 | -22 (-0.18%) |
| RAMB36 | 0 | 56 | 56 | 56 | 0 |
| RAMB18 | 8 | 16 | 16 | 16 | 0 |
| URAM | 0 | 0 | 0 | 0 | 0 |
| DSP | 128 | 128 | 128 | 128 | 0 |

Relative to baseline 006, direct-only removes 25,666 LUTs (47.02%) and 35,064
FFs (73.69%). Relative to broadcast 008, it uses 1,663 more LUTs (6.10%) but
removes the cross-direction stall coupling.

The eight aligned-channel parents total 28,402 LUTs, compared with 34,158 in
007 and 26,779 in 008. Child hierarchy totals are not additive attribution
because Vivado moves the padding and direction logic across RAM and elastic
buffer hierarchy boundaries.

## OOC Timing

| Metric | Baseline 006 | DPRAM 007 | Broadcast 008 | Direct-only 009 | 009 vs 007 |
| --- | ---: | ---: | ---: | ---: | ---: |
| WNS at 100 MHz | +3.853 ns | +4.342 ns | +4.721 ns | +4.495 ns | +0.153 ns |
| TNS | 0.000 ns | 0.000 ns | 0.000 ns | 0.000 ns | 0.000 ns |

The worst path runs from `seg_size_r` through request-control logic to an FSM
clock enable. The direct write-data path is not critical. Direct-only gives up
0.226 ns of the broadcast variant's margin but remains better than 007.

## Functional and Cycle Checks

| Check | DPRAM 007 | Broadcast 008 | Direct-only 009 |
| --- | ---: | ---: | ---: |
| VCS 32:32 backpressure suite | 13,585 ns | 14,935 ns | 13,585 ns |
| VCS 64:64 backpressure suite | 6,575 ns | 7,075 ns | 6,575 ns |
| VCS legacy 32:16 suite | 14,365 ns | 14,365 ns | 14,365 ns |

All unit tests pass. Direct-only exactly restores the 007 completion times,
showing that optimization 1 has no measured throughput cost in these suites and
that the 008 regression came from broadcast coupling.

The corrected C4 integration run also passes `fpint_gemm_ffn_hw` at M=N=K=128
through the socket-backed `vortex_xrtsim` runtime. It reports 6,993 instructions
and 12,252 cycles. The previously recorded 007/008 runs identified a physical
XRT device rather than `vortex_xrtsim`; their 17,265/17,355 cycle values are
cross-backend measurements and are not used in this comparison.

## Decision

Keep experiment 009 as the preferred Phase 1 RTL. It captures most of the LUT
benefit available from direct same-width data, improves timing over 007, and
does not introduce the backpressure throughput loss of the broadcast variant.
