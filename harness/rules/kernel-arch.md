---
paths: ["kernel/src/**"]
---

# Kernel Rules (Branch: fpint_improve — instruction stream architecture)

- All address, stride, bound, and seg_size computation happens in SW — HW only forwards
- Encode multi-word instructions per `harness/docs/isa-opcodes.md`
