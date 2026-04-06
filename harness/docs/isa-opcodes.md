# GEMM Instruction Set — Opcode Reference

## Opcode Table

All opcodes are 4-bit values in `instr[3:0]` of `gemm_unified_cmd_t`.

| Value | cmd_constructor Name | gemm_sync Name | Words | Description |
|-------|---------------------|----------------|-------|-------------|
| 1 | RAW_OP_DMA_LOAD | OP_DMA_LD | 3 | DRAM → LMEM tile copy |
| 2 | RAW_OP_DMA_STORE | OP_DMA_ST | 3 | LMEM → DRAM tile copy |
| 3 | RAW_OP_NOTIFY | OP_NOTIFY | 1 | Set/increment sync register |
| 4 | RAW_OP_WAIT | OP_WAIT | 1 | Block until sync_reg >= value |
| 5 | RAW_OP_MXU_LOAD_WEIGHT | OP_W_LDMA_MXU | 1 | LMEM → weight register |
| 6 | RAW_OP_MXU_LOAD_QPARAM | OP_SZ_LDMA_MXU | 2 | LMEM → scale/zp register |
| 7 | RAW_OP_MXU_LOAD_INPUT | OP_I_LDMA_ARM | 2 | LMEM → MXU input + compute |
| 8 | RAW_OP_MXU_STORE_OUTPUT | OP_O_ACC2LMEM | 2 | acc_mem → LMEM output |
| 9 | RAW_OP_CLEAR | (cmd_constructor only) | 1 | Signal job completion |

Definitions located in:
- `hw/rtl/core/gemm/VX_cmd_constructor.sv` lines 17-25 (RAW_OP_*)
- `hw/rtl/core/gemm/VX_gemm_sync.sv` lines 25-32 (OP_*)
- `hw/rtl/core/gemm/VX_gemm_dma_ctrl.sv` lines 47-49 (OP_DMA_LD/ST/NOTIFY only)
- `hw/rtl/core/gemm/VX_gemm_node.sv` line 59 (OP_NOTIFY only)

## gemm_unified_cmd_t Structure

Defined in `hw/rtl/VX_gpu_pkg.sv` lines 755-770.

| Field | Width | Used by | Notes |
|-------|-------|---------|-------|
| uuid | UUID_WIDTH | (legacy) | Not used by GEMM pipeline |
| wid | NW_WIDTH | (legacy) | Not used by GEMM pipeline |
| pc | PC_BITS | (legacy) | Not used by GEMM pipeline |
| instr | 32 | all opcodes | [3:0]=opcode, [31:4]=payload (seg_size or acc_cnt) |
| rs1 | NUM_REGS_BITS | (legacy) | Not used |
| rs2 | NUM_REGS_BITS | (legacy) | Not used |
| rd | NUM_REGS_BITS | (legacy) | Not used |
| rs1_data | XLEN | all opcodes | Destination addr or reg_id |
| rs2_data | XLEN | all opcodes | Source addr or value |
| stride | 32 | DMA/MXU ops | [31:16]=stride_a, [15:0]=stride_b |
| bound | 16 | DMA/MXU ops | Iteration bound |
| flags | 8 | MXU ops | Per-opcode bit flags |

## Per-Opcode Word Encoding

### DMA_LOAD (1) — 3 words

```
Word 0: [63:40] tmem_base_addr[24]  [39:4] dram_base_addr[36]  [3:0] opcode=1
Word 1: [47:32] tmem_stride0[16]    [31:16] dram_stride0[16]   [15:0] bound0[16]
Word 2: [31:0]  seg_size[32]
```
cmd_t mapping: rs1_data=tmem(dst), rs2_data=dram(src), stride={dram_s,tmem_s}, bound=bound0, instr={seg_size[27:0],opcode}

### DMA_STORE (2) — 3 words

Same encoding as DMA_LOAD. cmd_t mapping: rs1_data=dram(dst), rs2_data=tmem(src).

### NOTIFY (3) — 1 word

```
Word 0: [41] set_mode  [40:9] value[32]  [8:4] reg_id[5]  [3:0] opcode=3
```
cmd_t mapping: rs1_data=reg_id, rs2_data={set_mode,value[30:0]}

### WAIT (4) — 1 word

```
Word 0: [40:9] value[32]  [8:4] reg_id[5]  [3:0] opcode=4
```
cmd_t mapping: rs1_data=reg_id, rs2_data=value

### MXU_LOAD_WEIGHT (5) — 1 word

```
Word 0: [61] wtrans  [60] reg_idx  [59:44] bound[16]  [43:28] stride[16]  [27:4] tmem_base[24]  [3:0] opcode=5
```
cmd_t mapping: rs2_data=tmem_base, stride={0,stride16}, bound=bound16, flags={...,wtrans,reg_idx}

### MXU_LOAD_QPARAM (6) — 2 words

```
Word 0: [51:28] mxu_sz_base[24]  [27:4] tmem_base[24]  [3:0] opcode=6
Word 1: [47:32] tmem_stride[16]  [31:16] mxu_stride[16]  [15:0] bound[16]
```
cmd_t mapping: rs1_data=mxu_base, rs2_data=tmem_base, stride={tmem_s,mxu_s}, bound=bound16

### MXU_LOAD_INPUT (7) — 2 words

```
Word 0: [57] is_accum  [56] is_last  [55] wreg_idx  [54] sreg_idx  [53] zreg_idx
        [52] qdir  [51:28] tmem_base[24]  [27:4] acc_mem_base[24]  [3:0] opcode=7
Word 1: [63:32] acc_cnt[32]  [31:16] stride[16]  [15:0] bound[16]
```
cmd_t mapping: rs1_data=acc_mem_base, rs2_data=tmem_base, instr={acc_cnt[27:0],opcode}, stride={0,stride16}, flags={0,0,qdir,is_last,is_accum,wreg,sreg,zreg}

### MXU_STORE_OUTPUT (8) — 2 words

```
Word 0: [51:28] tmem_base[24]  [27:4] acc_mem_base[24]  [3:0] opcode=8
Word 1: [31:16] stride[16]  [15:0] bound[16]
```
cmd_t mapping: rs1_data=tmem_base, rs2_data=acc_mem_base, stride={0,stride16}, bound=bound16

### CLEAR (9) — 1 word

```
Word 0: [3:0] opcode=9
```
Handled by cmd_constructor only — triggers done_if to job_frontend, does not enter gemm_sync.
