# DMA Dcache Tag Width Split Specification

Status: confirmed

## Goal

Allow the naive common DMA to use 16 true outstanding read slots without increasing `LSUQ_OUT_SIZE` from 8 or aliasing DMA response slots through the current three-bit CPU dcache tag value.

## Scope

- Define separate CPU and DMA dcache tag widths.
- Preserve the existing CPU coalescer depth and native tag width.
- Normalize CPU and DMA tags to a common width immediately before the CPU/DMA dcache arbiter.
- Increase the cache-facing core tag width by the required payload bit while leaving cache behavior unchanged.
- Update focused DMA/memory integration tests as needed for 16 slots.
- Verify with the naive 32-thread hardware-exp dcache configuration and `xrt-vcs-sim` through `ci/run_black.sh`.

## Design Decisions

- CPU tag value width remains `DCACHE_TAG_ID_BITS`, derived from `LSUQ_OUT_SIZE`.
- DMA tag value width is the maximum of the CPU tag value width and `clog2(DMA_NODE_RD_OUTSTANDING_SLOT)`.
- The common pre-arbiter tag value width is the maximum native producer width.
- Width adaptation must preserve UUID bits at the top and pad/truncate only the value field.
- The CPU/DMA route bit is inserted above the common value field and removed before returning the response to its producer.
- The cache treats the widened tag as opaque payload; no cache algorithm change is in scope.

## Constraints and Assumptions

- `DMA_NODE_RD_OUTSTANDING_SLOT=16` is a positive power of two.
- `LSUQ_OUT_SIZE=8` remains unchanged.
- Both debug and `NDEBUG` UUID widths must elaborate correctly.
- Existing unrelated working-tree changes must be preserved.
- Do not silence the existing DMA tag-capacity assertion; make its width requirement true.

## Verification

- Focused RTL verification must exercise DMA slots 8 through 15 and out-of-order responses.
- CPU and DMA shared-port response routing must remain correct.
- Blackbox compile and test must source `configs/naive_gemm_th32_tcol32_hwexp_dcache.sh` and run in `xrt-vcs-sim` mode via `ci/run_black.sh` from a configured build directory.
