# DMA Node Misalignment PACK_BYTES Sweep

## Recommendation

Use `MISALIGN_PACK_BYTES=8` when the objective is to reduce DMA-node area.
It is the only completed point that materially lowers LUT utilization while
meeting the 100 MHz OOC timing constraint. Keep `16` only when the measured
DMA throughput benefit is worth 7,338 additional LUTs per DMA-node backend.

`32` and `64` are not viable: `32` adds 53.79% LUT versus `16` and misses
timing, while `64` does not complete synthesis within 30 minutes. `4` also
times out and takes 2.61x the `16`-byte unittest completion time.

## Fixed synthesis conditions

- OOC top: `VX_dma_unit_ooc`
- Measured hierarchy: `u_dma_unit`
- DCache port: 64 bytes
- Aggregate LMEM port: 128 bytes
- Read outstanding depth: 8
- Config: `configs/improve_th16_tcol32_hwexp_dcache.sh`
- Part: `xcu55c-fsvh2892-2L-e`
- Vivado: 2025.1
- Constraint: `hw/syn/xilinx/dut/project.xdc` (100 MHz)
- Git commit: `498e81c196b9b500fb411f4262af2df7ebc9b738`

The existing `VX_dma_engine_ooc` wrapper uses equal-width engine ports. This
experiment instead uses the 64-byte/128-byte shape instantiated by
`VX_dma_node`, so the PACK mux and assembly costs match the node backend.

## Utilization and timing

| PACK bytes | Test | OOC status | Synth elapsed | LUT | Delta LUT vs 16 | FF | RAMB36 | RAMB18 | DSP | WNS (ns) |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 4 | PASS | TIMEOUT | >30 min | — | — | — | — | — | — | — |
| 8 | PASS | PASS | 4m 46s | 21,815 | -7,338 (-25.17%) | 5,260 | 14 | 3 | 16 | +1.130 |
| 16 | PASS | PASS | 13m 53s | 29,153 | baseline | 5,339 | 14 | 3 | 16 | +1.359 |
| 32 | PASS | PASS | 28m 33s | 44,834 | +15,681 (+53.79%) | 5,368 | 14 | 3 | 16 | -0.314 |
| 64 | PASS | TIMEOUT | >30 min | — | — | — | — | — | — | — |

All completed points use 14 RAMB36 plus 3 RAMB18, or 15.5 equivalent
RAMB36. PACK size therefore changes LUT cost and timing, not response-storage
BRAM or DSP count.

## Functional-cycle proxy

The same VCS test ran 2,125 misalignment, width-conversion, padding, partial
beat, and backpressure cases for every PACK value. All candidates passed.
The finish time is a controlled testbench cycle proxy, not an application
benchmark.

| PACK bytes | Test finish time | Delta vs 16 |
| ---: | ---: | ---: |
| 4 | 7,453,215 ns | +161.08% |
| 8 | 4,377,315 ns | +53.33% |
| 16 | 2,854,775 ns | baseline |
| 32 | 2,320,075 ns | -18.73% |
| 64 | 2,249,825 ns | -21.19% |

Moving from 8 to 16 bytes improves this proxy by 34.8% relative to the
8-byte runtime, but costs 33.6% more LUT relative to the 8-byte design.
Moving beyond 16 gives only another 18.7-21.2% versus the 16-byte runtime,
while area and synthesis complexity rise sharply.

## Interpretation

- Area-first default: `8` bytes.
- Throughput-first default: retain `16` bytes until an application benchmark
  proves that the additional LUT cost is acceptable.
- Do not use `32`: it fails the OOC timing constraint.
- Do not use `4` or `64`: both fail the 30-minute synthesis-completion gate.

Before changing the production default to `8`, run an `xrt-vcs-sim` workload
that exercises DMA and compare application cycles against `16`. This sweep is
an OOC estimate and does not replace full-design placement and routing.

## Artifacts

- Machine-readable summary: `results.csv`
- Functional logs: `tests/pack*/sim.log.gz`
- Completed raw reports: `ooc/pack{8,16,32}/post_synth_util.rpt` and
  `post_synth_timing_summary.rpt`
- Timeout logs: `ooc/pack{4,64}/synth_runme.log`
- Per-run defines and source manifests: `ooc/pack*/configs.txt` and
  `ooc/pack*/sources.txt`
