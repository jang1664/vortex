# VX_gemm_tmem_dma_ctrl Future Work

## Current State

- `VX_gemm_tmem_dma_ctrl` now preserves TMEM bank-local byte offsets and rotates the active physical DMA channel based on the starting bank.
- The default regression test is the controller-level misalignment/configuration testbench:
  - `tb_VX_gemm_tmem_dma_ctrl_misalign.sv`
- An experimental mock integration testbench remains in:
  - `tb_VX_gemm_tmem_dma_ctrl.sv`

## Known Open Problem

The experimental mock integration TB shows that supporting fully general external DMA misalignment is more than a byte-offset preservation problem.

### What works

- TMEM bank-local byte address conversion now preserves `addr[5:0]`.
- Single-block transfers starting on a non-zero bank now activate the rotated physical channel.

### What is still unresolved

For a transfer like:

- `tmem_base = 0x243`
- `hbm_base = 0x80043`
- `seg_size = 64`
- constraint satisfied: `hbm_base % 512 == tmem_base % 512 == 0x43`

the 64-byte global TMEM interval spans multiple physical banks:

- bytes `0x243..0x27f` map to bank 1
- bytes `0x280..0x282` map to bank 2

The current controller/descriptor model still assumes that one programmed DMA channel handles one contiguous 64-byte bank-local chunk. That is not sufficient for a bank-crossing misaligned global transfer.

In other words:

- preserving low address bits is necessary
- channel rotation is necessary
- but neither is sufficient for general misaligned support when a transfer crosses bank boundaries

## Likely Required Design Change

Support for fully general misaligned external DMA likely needs one of these:

1. Fragment decomposition
- Split a global byte interval into per-bank fragments.
- Program multiple channels and potentially multiple fragments per channel.

2. Head/body/tail handling
- Generate partial front fragment, aligned middle body, and partial tail fragment.
- Requires descriptor semantics beyond the current fixed `64B-per-segment` model.

3. Architectural restriction
- Limit external DMA misalignment support to cases that do not cross a TMEM bank boundary.
- This is simpler, but weaker than the current desired spec direction.

## Why This Is Nontrivial

- `bound > 1` and arbitrary stride can change the starting bank per iteration.
- A channel may need multiple discontiguous fragments across one DMA command.
- The current `words_per_ch` / `BND0` decomposition is based on 64-byte aligned global blocks, not arbitrary byte intervals.

## References

- NVIDIA PVA DMA details:
  - https://docs.nvidia.com/pva/sdk/2.8.1/dma-details.html
- NVIDIA PVA architecture overview:
  - https://docs.nvidia.com/pva/sdk/2.7.1/architecture.html
- Open-source 2D DMA example:
  - https://github.com/atfox272/dma
- Gemmini DMA/alignment-oriented design:
  - https://github.com/ucb-bar/gemmini
- OpenGeMM paper:
  - https://arxiv.org/abs/2411.09543
- MemPool paper:
  - https://arxiv.org/abs/2303.17742

## Recommended Next Step

- Keep `tb_VX_gemm_tmem_dma_ctrl_misalign.sv` as the default regression TB.
- Treat the mock integration TB as a design-exploration harness until fragment decomposition semantics are defined.
