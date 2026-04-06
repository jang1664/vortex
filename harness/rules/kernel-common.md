---
paths: ["kernel/src/**"]
---

# Kernel Rules (Common — all branches)

- GEMM kernel is `kernel/src/fi_gemm.c`
- Toolchain: `/opt/vortex/llvm-vortex/` (RISC-V with Vortex extensions)
- Quantization modes: QCOL (qdir=0) and QROW (qdir=1)
- Weight transpose: wtrans=0 ([K,N]) and wtrans=1 ([N,K])
