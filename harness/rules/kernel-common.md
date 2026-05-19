---
paths: ["kernel/**"]
---

# Kernel Rules (Common — all branches)

- Before modifying kernel code that touches DMA addresses or memory allocation, inspect the current runtime and simulator address handling in `runtime/xrt/vortex_v*.cpp`, `runtime/common/`, and `sim/xrtsim*/`. This branch does not carry a dedicated HBM interleaving design note.
