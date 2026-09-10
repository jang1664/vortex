# TMEM / placement exploration preparation

Follow-up (2026-09-09): the completed comparison led to BRAM adoption as the
TMEM default (0). The original preparation and verification below used default
1. See `../all-bram/all-bram-spec.md` for the remaining-memory experiment.

## Confirmed scope

Prepare URAM and BRAM variants for TH32 / HBM4 / TMEM8; do not launch synthesis or PnR.
The user confirmed these experiments on 2026-09-08.

| Experiment | TMEM | GEMM SLR pipeline | GEMM floorplan | Placement | Routing |
| --- | --- | --- | --- | --- | --- |
| URAM | URAM | enabled | enabled | SSI_SpreadSLLs | AlternateCLBRouting |
| BRAM | BRAM | enabled | enabled | SSI_SpreadSLLs | AlternateCLBRouting |

## Implementation

- Add a numeric `TMEM_USE_URAM` configuration macro, default 1, and a corresponding
  `VX_tensor_mem_bank` parameter. Forward the selection to its `VX_sp_ram`.
- Preserve memory width, capacity, byte enables, read latency, and backpressure.
- Keep ACC and core local memory mapping unchanged.
- Permit `SSI_SpreadSLLs` in the XRT Makefile without enabling unsupported
  subdirectives or ultrathreads.
- Provide two sourceable experiment configs derived from the existing HBM4/TMEM8
  config, with distinct names and identical settings except TMEM mapping.
- Verify config expansion, generated implementation options, and focused RTL
  functionality. Prepare configured build helpers without starting hardware builds.

## Controls

Use 100 MHz, WLOAD=4, GEMM_TIMING_CUTS=1, FAST_MODE=0, IMPL_ULTRATHREADS=0,
and `--no-early-fail`. No fine-grained clock-region constraints are added.
Future floorplan-off primary experiments should also omit GEMM_SLR_PIPELINE;
pipeline-on/floorplan-off is only a separate diagnostic experiment.

## Verification limits

Behavioral simulation cannot establish URAM/BRAM primitive mapping or physical
congestion improvement. Those require subsequent synthesis and PnR reports.
