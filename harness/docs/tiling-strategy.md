# Tiling Strategy — SW/HW Responsibility Split

## Core Principle

**SW computes all addresses, strides, and bounds. HW only routes and executes.**

The GEMM kernel (`kernel/src/fi_gemm.c`) runs a triple-nested tile loop (m_tiles x n_tiles x k_tiles)
and encodes each DMA/MXU operation as multi-word instructions sent to the HW via MMIO.

## Tile Parameters

Defined in `hw/rtl/VX_config.vh` lines 1151-1155:

| Parameter | Value | Meaning |
|-----------|-------|---------|
| GEMM_FSM_MT | 128 | DMA tile rows (M dimension) |
| GEMM_FSM_NT | 128 | DMA tile columns (N dimension) |
| GEMM_FSM_KT | 128 | DMA tile reduction (K dimension) |
| GEMM_FSM_MXU_KT | 32 | MXU micro-tile K (= MXU_ROW) |
| GEMM_FSM_MXU_NT | 32 | MXU micro-tile N (= MXU_COL) |

A DMA tile is processed as micro-tiles: each DMA tile has (KT/MXU_KT) x (NT/MXU_NT) micro-tiles.

## Data Types and Sizes

| Tensor | Element Type | Bytes/Element | Data Size per MXU op |
|--------|-------------|---------------|---------------------|
| Input | FP16 | 2 | 64B (MXU_ROW=32 x 2B) |
| Weight | INT4 packed | 0.5 | 64B (MXU_COL=32 x MXU_WLOAD_NUM=4 x 4bit / 8) |
| Scale | FP16 | 2 | 64B (MXU_COL=32 x 2B) |
| Zero-point | INT16 | 2 | 64B (MXU_COL=32 x 2B) |
| Output | FP16 | 2 | 64B (MXU_COL=32 x 2B) |
| Partial sum | FP32 | 4 | 128B (MXU_COL=32 x 4B) |

## SW Tiling Loop Structure

```
for each m_tile:
  for each n_tile:
    DMA_LOAD input tile [MT x KT] from DRAM → LMEM
    DMA_LOAD weight tile from DRAM → LMEM
    DMA_LOAD scale/zp from DRAM → LMEM

    for each k_micro in (KT / MXU_KT):
      MXU_LOAD_WEIGHT   (LMEM → weight reg, with wtrans/reg_idx flags)
      MXU_LOAD_QPARAM   (LMEM → scale/zp reg)
      for each n_micro in (NT / MXU_NT):
        MXU_LOAD_INPUT  (LMEM → MXU, triggers compute, is_accum/is_last flags)

    MXU_STORE_OUTPUT    (acc_mem → LMEM)
    DMA_STORE output    (LMEM → DRAM)
```

Synchronization between DMA and MXU operations uses NOTIFY/WAIT on 11 sync registers.

## Quantization Modes

- **QCOL (qdir=0)**: Quantization along columns. Scale/ZP layout: [K_groups, N]. Groups = ceil(K / qblk).
- **QROW (qdir=1)**: Quantization along rows. Scale/ZP layout: [K, N_groups]. Groups = ceil(N / qblk).

The mode affects how SW computes scale/zp DMA addresses and strides — HW does not distinguish.

## Weight Transpose

- **wtrans=0**: Weight stored as [K, N] packed row-major (N/2 bytes per row).
- **wtrans=1**: Weight stored as [N, K] packed row-major (K/2 bytes per row).

SW adjusts stride and seg_size accordingly. HW flag `flags[1]` carries wtrans to gemm_unit.
