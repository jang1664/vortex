# Add Opcode

Checklist for adding a new GEMM opcode (e.g., `RAW_OP_NEW = 4'd10`).

## 1. VX_cmd_constructor.sv (hw/rtl/core/gemm/)
- Add `localparam logic [3:0] RAW_OP_<NAME> = 4'd<N>;` (after line 25)
- Add entry in `cmd_word_count()` — specify how many 64-bit words this opcode needs (1, 2, or 3)
- Add case in `build_cmd()` — map raw word bits to gemm_unified_cmd_t fields

## 2. VX_gemm_sync.sv (hw/rtl/core/gemm/)
- Add `localparam logic [3:0] OP_<NAME> = 4'd<N>;` (lines 25-32)
- Add routing case in `unique case (opcode)` — assign `cmd_route` (0=input, 1=weight, 2=sz, 3=output, 4=dma)

## 3. VX_gemm_dma_ctrl.sv (hw/rtl/core/gemm/) — if DMA-related
- Add matching `localparam` in opcode section (lines 47-49)
- Add handling in the DMA command processing state machine

## 4. VX_gemm_node.sv (hw/rtl/core/gemm/) — if needs notify/DMA mapping
- Add `*_is_notify` comparison wire if the new opcode goes to a child that handles NOTIFY
- Wire the child's DMA ctrl interface fields from the cmd

## 5. Kernel (kernel/src/fi_gemm.c)
- Add instruction word encoding function that packs fields per the new format

## 6. Testbench (hw/unittest/gemm_node_improve/)
- Add stimulus in tb_VX_gemm_node_improve.sv exercising the new opcode
- Add test case to test.sh if needed

## Verification
```bash
cd hw/unittest/gemm_node_improve
make SIM_EXEC=vcs run M=32 N=32 K=128 QBLK=32
# Check for "OUTPUT CHECK PASSED"
```
