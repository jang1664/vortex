# Same-Width Response DPRAM Comparison

This experiment compares the Phase 1 result directly with
`20260717-006-c4-aligned-baseline`. Both results use `VX_dma_engine_ooc`, alias
`C4`, Vivado 2025.1, `xcu55c-fsvh2892-2L-e`, and the same 100 MHz constraint.
The comparison is post-synthesis and does not predict full-design placement or
routing congestion.

## DMA Engine Utilization

The table reports the `u_dma_engine` hierarchy row. The OOC wrapper itself is
excluded.

| Metric | Baseline 006 | Response DPRAM | Delta | Delta (%) |
| --- | ---: | ---: | ---: | ---: |
| LUT | 54,588 | 34,635 | -19,953 | -36.55% |
| FF | 47,586 | 12,544 | -35,042 | -73.64% |
| RAMB36 | 0 | 56 | +56 | n/a |
| RAMB18 | 8 | 16 | +8 | +100.00% |
| RAMB18 equivalents | 8 | 128 | +120 | +1500.00% |
| RAMB36 equivalents | 4 | 64 | +60 | +1500.00% |
| URAM | 0 | 0 | 0 | n/a |
| DSP | 128 | 128 | 0 | 0.00% |

Each of the eight response payload RAM instances maps to seven RAMB36 and one
RAMB18. The remaining eight RAMB18 blocks already existed in the baseline.
For C4, `RD_OUTSTANDING` is two, so each response RAM stores two 512-bit beats.
This shallow, wide shape explains why the BRAM increase is large relative to
the number of stored bits.

## Targeted Structures

Totals below sum the eight aligned DMA channels. The named rows isolate the
buffers directly changed by this phase.

| Structure | Baseline LUT | Current LUT | Baseline FF | Current FF | Current BRAM |
| --- | ---: | ---: | ---: | ---: | ---: |
| `dcache_req_buf` | 12,580 | 1,298 | 9,728 | 496 | 0 |
| `lmem_req_buf` | 1,586 | 1,304 | 9,728 | 496 | 0 |
| `wr_slot_buf` | 18,174 | 0 | 8,320 | 0 | 0 |
| `response_payload_ram` | 0 | 7,960 | 0 | 0 | 56 RAMB36 + 8 RAMB18 |
| Named total | 32,340 | 10,562 | 27,776 | 992 | 56 RAMB36 + 8 RAMB18 |

The aligned channel implementations as a whole fell from 54,060 to 34,158
LUTs and from 47,186 to 12,144 FFs. This includes slot state and datapath logic
that Vivado attributes to the parent rather than the named buffers.

## Timing

| Metric | Baseline 006 | Response DPRAM | Delta |
| --- | ---: | ---: | ---: |
| WNS at 100 MHz | +3.853 ns | +4.342 ns | +0.489 ns |
| TNS | 0.000 ns | 0.000 ns | 0.000 ns |

Both OOC runs meet the specified timing constraint. OOC timing remains an
estimate because the clock has no implemented full-design clock root.

## Verification

- VCS aligned DMA unittest: PASS at 32:32 and 64:64 byte same-width beats.
- VCS legacy-path unittest: PASS at 32:16 byte unequal-width beats.
- The recorded C4 integration process passed `fpint_gemm_ffn_hw` with
  M=N=K=128, qblk=32, one core, sixteen threads, and eight DMA channels.
- A later runtime audit in experiment 009 showed that this process identified a
  physical XRT device instead of the socket-backed `vortex_xrtsim` runtime.
  Its 7,041 instructions and 17,265 cycles are not a VCS-backend baseline.

The recorded integration number is a functionality result from another backend,
not a controlled latency delta.
An older pre-change log has a different instruction count, so it cannot isolate
the RTL change. A cycle claim requires rebuilding baseline and candidate from
the same software tree and compile flags.

## Decision

Keep this result as the Phase 1 candidate. It removes the dominant LUT/FF drain
cost and passes the functional and OOC timing gates. Before merging it as the
final FPGA implementation, run full-design synthesis and P&R to determine
whether the additional 60 RAMB36-equivalent blocks create device-level BRAM or
placement pressure.
