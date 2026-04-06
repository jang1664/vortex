---
paths: ["kernel/src/**"]
---

# Kernel Rules (Branch: fpint_improve — instruction stream architecture)

- All address, stride, bound, and seg_size computation happens in SW — HW only forwards
- Encode multi-word instructions per `harness/docs/isa-opcodes.md`
- Sync registers (11 total) coordinate DMA and MXU operations via NOTIFY/WAIT
- QCOL/QROW and wtrans affect address calculation — see `harness/docs/tiling-strategy.md`
