---
paths: ["hw/rtl/**"]
---

# RTL Rules (Branch: fpint_improve — instruction stream architecture)

- Opcodes are 4-bit values in instr[3:0]. Adding a new opcode requires updating ALL 4 files:
  VX_cmd_constructor.sv, VX_gemm_sync.sv, VX_gemm_dma_ctrl.sv, VX_gemm_node.sv
  (see `harness/docs/isa-opcodes.md` for the full mapping)
- `gemm_unified_cmd_t` (VX_gpu_pkg.sv) is the single command struct for all opcodes — do not create opcode-specific structs
- SW encodes multi-word instructions; HW (cmd_constructor) collects and decodes them
- DMA address/stride/bound are passed through from cmd — HW does not compute them
