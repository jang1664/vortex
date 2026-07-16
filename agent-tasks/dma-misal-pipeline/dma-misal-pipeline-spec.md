# Misaligned DMA Pipeline Specification

## Goal

Improve `VX_dma_unit_misal` throughput by overlapping descriptor iteration,
source read issue, response realignment, and destination write issue. The main
target is the current one-source-beat-at-a-time path that exposes the full
DCache response latency.

## Confirmed Scope

- `hw/rtl/core/VX_dma_unit_misal.sv`
- `configs/naive_gemm_simd_th16_tcol32_hwexp_dcache.sh`
- Shared FIFO or metadata helpers only if an existing library block cannot be reused
- DMA unit tests and the configured `fpint_gemm_ffn_naive` blackbox regression

The active aligned global DMA, local misaligned DMA, weight gather DMA, and AXI
DMA engine already use decoupled or buffered request/response paths. They are
comparison targets and regression scope, not implementation targets. The
legacy `VX_lmem_dma.sv` has no product-RTL instantiation and remains unchanged.

## Proposed Stages

1. Descriptor and address generator
   - Capture stride, bound, segment size, padding, direction, and base addresses.
   - Generate ordered source-read descriptors and destination placement metadata.
   - Run ahead into a bounded FIFO while downstream stages are busy.
2. Source-read issuer
   - Consume read descriptors and issue LMEM or DCache reads under backpressure.
   - Allow multiple DCache reads to be outstanding up to a parameterized depth.
3. Read-response and realignment stage
   - Associate each response with its segment/beat metadata.
   - Perform byte realignment and assemble destination beats.
   - Queue completed destination write requests.
4. Destination-write issuer
   - Issue LMEM or DCache writes independently under backpressure.
   - Retire writes and generate completion only after every pipeline stage drains.

## Constraints

- Preserve both GLOBAL-to-LMEM and LMEM-to-GLOBAL behavior.
- Preserve 3-D stride/bound semantics, padding, byte enables, and misalignment.
- Do not assume equal DCache and LMEM widths.
- Preserve UUID/tag behavior and avoid response association ambiguity.
- Use bounded storage and valid/ready backpressure at every stage.
- Keep the configured naive memory-system topology unchanged.

## Design Decisions

- Reuse the tagged response-slot organization from `VX_dma_unit_align`; do not
  depend on response ordering.
- Keep independent read-side and write-side 3-D iterators so read generation can
  cross segment boundaries while earlier responses and writes drain.
- Use `DMA_RD_OUTSTANDING_SLOT` as the global-DMA slot cap and set an explicit
  depth in the target naive configuration.
- Use registered depth-4 request buffers on both DCache and LMEM so address
  generation can run ahead of physical request acceptance.
- Size the response-slot array from the configured cap, but limit each transfer
  direction by the source interface's available response-tag bits. In the
  target configuration this provides eight G2L slots from the DCache tag and
  two L2G slots from the narrower LMEM tag without widening shared interfaces.
- Completion requires both iterators to finish and all response slots, pack
  state, request buffers, and DCache write drain state to become empty.

## Confirmation

Status: confirmed on 2026-07-16.

## Focused Waveform

The xrt-vcs testbench supports `FSDB_DMA_ONLY` to dump only the first core's
`u_VX_dma_node`. Keep this simulation-only define out of hardware configuration
files and enable it for long waveform runs with:

```bash
ci/run_black.sh xrt-vcs-sim \
  --configs-extra "-DFSDB_DMA_ONLY" \
  --app fpint_gemm_ffn_hw_naive \
  --args "-m 1024 -k 256 -n 256 -q 32 -t 0 -d 0"
```
