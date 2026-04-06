# GEMM Node Architecture

## Module Hierarchy

```
VX_gemm_node (hw/rtl/core/gemm/VX_gemm_node.sv)
├── VX_gemm_job_frontend        MMIO → instruction stream
│     ├── VX_lsu_mem_arb         (N_MASTER arbitration)
│     └── VX_instruction_if      (64-bit valid/ready stream)
│
├── VX_gemm_ctrl (hw/rtl/core/gemm/VX_gemm_ctrl.sv)
│     ├── VX_cmd_constructor     raw 64-bit words → gemm_unified_cmd_t
│     ├── VX_gemm_pqueue         parent command FIFO
│     ├── VX_gemm_sync           WAIT/NOTIFY + route to 5 children
│     └── VX_gemm_cqueue[5]      child command FIFOs
│
├── gemm_unit (input DMA + MXU compute + output store)
│     ├── input LMEM DMA   → VX_lmem_dma (GEMM_INPUT_DATA_SIZE = 64B)
│     ├── weight LMEM DMA  → VX_lmem_dma (GEMM_WEIGHT_DATA_SIZE = 64B)
│     ├── qparam LMEM DMA  → VX_lmem_dma (GEMM_SCALE_ZERO_DATA_SIZE = 64B)
│     ├── VX_gemm_unit       MXU core (32x32, int4 weight, fp16 input → fp32 psum)
│     └── output LMEM DMA  → VX_lmem_dma (GEMM_OUTPUT_DATA_SIZE = 64B)
│
├── VX_gemm_dma_ctrl             external DMA (DRAM ↔ LMEM via dcache)
├── VX_dma_node                  (sibling, not child — shares dcache port)
│
└── Memory fabric
      ├── VX_mem_data_adapter[4]  LSU-width ↔ GEMM-width conversion
      ├── VX_lsu_mem_arb          GEMM + DMA local memory arbitration
      └── VX_local_mem            LMEM instance
```

## Data Flow

### Load path (DRAM → LMEM → MXU)
1. SW encodes DMA_LOAD instruction → job_frontend → cmd_constructor
2. cmd_constructor decodes → gemm_sync routes to child #4 (dma_ctrl)
3. VX_gemm_dma_ctrl issues dcache requests: DRAM → LMEM byte copy
4. SW encodes MXU_LOAD_* instruction → routed to child #0/#1/#2
5. LMEM DMA reads tile from LMEM → feeds into gemm_unit

### Compute path
6. MXU_LOAD_INPUT triggers gemm_unit: reads input tile from LMEM, multiplies with loaded weight
7. Partial sums accumulate in acc_mem (fp32, 128B per entry)
8. MXU_STORE_OUTPUT: acc_mem → fp16 conversion → LMEM DMA write

### Store path (LMEM → DRAM)
9. DMA_STORE: VX_gemm_dma_ctrl copies LMEM → DRAM via dcache

## Interface Chain

```
SW kernel (fi_gemm.c)
  ↓ MMIO writes (64-bit words)
VX_instruction_if  (inst[63:0], valid, ready)
  ↓
VX_gemm_fsm_if     (ctrl: {cmd: gemm_unified_cmd_t, start}, flag: {idle, done})
  ↓ routed by VX_gemm_sync
VX_gemm_ctrl_if    (5x {lmem_dma_ctrl_t, lmem_dma_flag_t} + dma_ctrl/flag)
  ↓
Individual DMA/MXU engines
```

## Child Queue Routing (VX_gemm_sync)

| Route | Child | Opcodes | Engine |
|-------|-------|---------|--------|
| 0 | input_read | MXU_LOAD_INPUT (7), NOTIFY (3) | LMEM DMA + gemm_unit |
| 1 | weight_read | MXU_LOAD_WEIGHT (5), NOTIFY (3) | LMEM DMA → weight reg |
| 2 | quant_param_read | MXU_LOAD_QPARAM (6), NOTIFY (3) | LMEM DMA → scale/zp reg |
| 3 | output_write | MXU_STORE_OUTPUT (8), NOTIFY (3) | acc_mem → LMEM DMA |
| 4 | dma | DMA_LOAD (1), DMA_STORE (2), NOTIFY (3) | dcache ↔ LMEM |

WAIT (4) is handled by gemm_sync itself (blocks until sync_reg >= target).
CLEAR (9) is handled by cmd_constructor (signals done_if to job_frontend).
