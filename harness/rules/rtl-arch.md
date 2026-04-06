---
paths: ["hw/rtl/**"]
---

# RTL Rules (Branch: fpint_improve — instruction stream architecture)

- Adding a new opcode requires updating ALL 4 files: VX_cmd_constructor.sv, VX_gemm_sync.sv, VX_gemm_dma_ctrl.sv, VX_gemm_node.sv
- `gemm_unified_cmd_t` (VX_gpu_pkg.sv) is the single command struct for all opcodes — do not create opcode-specific structs
- HW does not compute addresses, strides, or bounds — these are passed through from the SW-encoded command
