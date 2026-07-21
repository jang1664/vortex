# Generalized misaligned DMA adoption comparison

## Decision

**Investigate; do not remove the legacy comparison path yet.** The generalized
datapath passes the functional, full-beat throughput, integration-cycle, and
100 MHz timing gates. The primary 64B/256B row is an OOC adoption pass, but the
512B/512B row uses 79,293 LUTs versus the predeclared 40,000-LUT HBW budget.
That R12 failure blocks U8 cleanup even though the 512B synthesis now completes
inside the locked 30-minute wall budget.

## Matched OOC results

| Row | RTL | LUT | FF | RAMB36 | RAMB18 | DSP | WNS | Unconstrained | Result |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 64B/256B runtime | pre-change | 53,049 | 7,961 | 33 | 2 | 16 | +0.725 ns | 0 | baseline |
| 64B/256B runtime | generalized | 21,020 | 13,038 | 33 | 2 | 16 | +3.663 ns | 0 | **keep: R11 pass** |
| 512B/512B runtime | pre-change | timeout during timing optimization | - | - | - | - | - | - | preserved baseline timeout |
| 512B/512B runtime | generalized direct realigner | 79,293 | 21,225 | 73 | 0 | 16 | +2.194 ns | 0 | **reject for adoption: R12 LUT budget fail** |

The primary row removes 32,029 LUTs (60.38%) from `u_dma_unit`. The HBW
candidate completes synthesis in 23 minutes 43 seconds with all constraints
met, but its equal-width direct realigner accounts for 68,540 LUTs; the nested
destination assembler alone accounts for 68,339 LUTs. This identifies the
remaining runtime byte-permutation network, not payload storage, as the HBW
bottleneck.

## Behavioral gates

| Gate | Result |
| --- | --- |
| 64B/256B runtime-direction matrix | 2,126/2,126 PASS |
| 512B/512B runtime-direction matrix | 2,126/2,126 PASS |
| 512B/512B throughput | 512B/cycle in both directions, PASS |
| Destination assembler component matrix | six configurations including 8x64B equal width, PASS |
| Fixed-direction LMEM DMA | PASS |
| Real HBW splitter active-lane test | 1/1 PASS |
| HBW xrt-vcs-sim | PASS, 7,425 instructions / 17,641 cycles |
| HBW cycle delta from old baseline | 0.00% |

## Preserved artifacts

- `ooc/64x256-final-selector/`: passing primary candidate reports.
- `ooc/512x512-final-selector/`: first 512B timeout.
- `ooc/512x512-equal-shared-selector/`: shared-assembler timeout after timing optimization.
- `ooc/512x512-bank-reused-selector/`: bank-reused timeout during timing optimization.
- `ooc/512x512-direct-realign-selector/`: completed direct-realigner reports and manifests.

The next admissible architecture must replace the 68k-LUT equal-width
assembler with a one-output-beat streaming window realigner (previous/current
source beats) or another structure that preserves 512B/cycle while avoiding
simultaneous current-and-spill permutation networks.
