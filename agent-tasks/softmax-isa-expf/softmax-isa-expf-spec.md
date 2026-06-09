# Softmax ISA expf Implementation Spec

## Goal

Add a Vortex custom FP32 `vx_expf` instruction and make `tests/regression/softmax` able to opt into it through `vx_expf()` after RTL/compiler/kernel support is verified.

## Scope

- Vortex RTL decode/FPU path for a custom FP32 unary exp instruction.
- LLVM Vortex RISC-V instruction/intrinsic support in `/home/jaeyongjang/project.local/vortex-llvm` branch `volt`.
- Kernel headers and softmax regression opt-in.
- Verification through unit/build/disassembly/blackbox where available.

## Out of Scope For First Milestone

- DMA node/local-memory softmax kernel optimization.
- Separate EX unit for expf.
- Automatic lowering of generic `llvm.exp.f32`.
- IEEE-exact libm-compatible `expf`.

## Confirmed Design

- Encoding: `CUSTOM0` (`0x0b`), `funct7=7'h03`, `funct3=0`, `rs2=x0`.
- Execution unit: reuse `EX_FPU`.
- Operation type: add `INST_FPU_EXP` in an unused FPU op slot.
- Software API: `vx_expf_hw(float)` and optional `VX_ENABLE_HW_EXPF` redirection in `vx_math.h`.
- Kernel optimization remains last, only after direct-DRAM softmax with hardware expf is verified.
