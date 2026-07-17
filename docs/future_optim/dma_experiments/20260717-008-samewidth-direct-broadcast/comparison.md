# Same-Width Direct Data and Broadcast Comparison

Experiment 008 is compared with the response-DPRAM result 007 and the fixed
aligned baseline 006. All synthesis results use the same C4 config, OOC top,
U55C part, Vivado 2025.1, and 100 MHz constraint.

## Implementation Result

An unconditional RAM-to-destination connection is not behaviorally equivalent
to the original DMA:

- Partial payload beats must write zero into trailing padding bytes. Experiment
  008 masks those bytes once before storing the response in RAM.
- Padding can occupy complete destination beats with no response slot. One
  shared `payload_needed ? ram_data : zero` selector handles those beats.
- Broadcasting the selected data to both request buses requires it to remain
  stable while a source read request is stalled. Response RAM reads and the
  opposite destination write are held during that stall.

The result removes duplicated output-side byte masking and direction-controlled
512-bit data muxes, but the last rule couples source and destination progress.

## OOC Utilization

| Metric | Baseline 006 | DPRAM 007 | Direct+broadcast 008 | 008 vs 007 |
| --- | ---: | ---: | ---: | ---: |
| LUT | 54,588 | 34,635 | 27,259 | -7,376 (-21.30%) |
| FF | 47,586 | 12,544 | 12,560 | +16 (+0.13%) |
| RAMB36 | 0 | 56 | 56 | 0 |
| RAMB18 | 8 | 16 | 16 | 0 |
| URAM | 0 | 0 | 0 | 0 |
| DSP | 128 | 128 | 128 | 0 |

Relative to fixed baseline 006, experiment 008 removes 27,329 LUTs (50.06%)
and 35,026 FFs (73.61%). BRAM usage is unchanged from experiment 007.

The eight aligned channel instances fall from 34,158 LUTs in 007 to 26,779
LUTs in 008. This accounts for essentially the entire DMA-engine reduction.
Named child hierarchy totals are not additive evidence for the optimization:
Vivado moves the new stall and broadcast logic across RAM and buffer hierarchy
boundaries. The `u_dma_engine` and aligned-channel parent totals are the stable
comparison points.

## OOC Timing

| Metric | Baseline 006 | DPRAM 007 | Direct+broadcast 008 | 008 vs 007 |
| --- | ---: | ---: | ---: | ---: |
| WNS at 100 MHz | +3.853 ns | +4.342 ns | +4.721 ns | +0.379 ns |
| TNS | 0.000 ns | 0.000 ns | 0.000 ns | 0.000 ns |

The added control gating is not the OOC critical path. The worst path remains
inside descriptor and request-control logic, and estimated WNS improves.

## Functional and Cycle Checks

| Check | DPRAM 007 | Direct+broadcast 008 | Delta |
| --- | ---: | ---: | ---: |
| VCS 32:32 backpressure suite | 13,585 ns | 14,935 ns | +9.94% |
| VCS 64:64 backpressure suite | 6,575 ns | 7,075 ns | +7.60% |
| VCS legacy 32:16 suite | 14,365 ns | 14,365 ns | 0.00% |
| Recorded physical-XRT GEMM cycles | 17,265 | 17,355 | +90 (+0.52%) |
| Recorded physical-XRT instructions | 7,041 | 7,035 | -6 |

All tests pass. A later runtime audit in experiment 009 showed that the recorded
GEMM process identified a physical XRT device instead of `vortex_xrtsim`; the
0.52% delta is therefore not a VCS-backend comparison. The unit tests apply
periodic request stalls and expose a controlled 7.6-9.9% same-width
transfer-time cost. The unequal-width path is unchanged, as shown by its
identical completion time.

## Decision

Do not accept the combined direct-data and broadcast variant as the final DMA
implementation yet. It provides a strong LUT and timing result, but output
broadcast requires source/destination coupling to preserve ready/valid payload
stability. The next controlled experiment should retain capture-time padding
masking and shared padding-only selection while restoring direction-specific
read data. That isolates the benefit of optimization 1 without the throughput
risk introduced by optimization 2.
