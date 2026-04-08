---
paths: ["kernel/**"]
---

# Kernel Rules (Common — all branches)

- Before modifying kernel code that touches DMA addresses or memory allocation, read `docs/hbm-bank-interleaving.md` to understand HBM address mapping, interleave vs contiguous modes, and runtime BANK_INTERLEAVE behavior.
