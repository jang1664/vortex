# FPINT GEMM cycles: improve vs naive

Current RTL, xrt-vcs-sim, TH16 / MXU16x16, K=N=512, micro-tile N-fast. Naive uses continuous Input issue and PSUM read quota=1. Weight response slots: 8 on both backends; naive PSUM read/response slots: 16. External DMA read slots: naive 32, improve 16 per channel. Naive LMEM total capacity: 1 MiB.

## Naive LMEM port/bank matrix

| Ports / banks | M4 GEMM | M256 GEMM | M4 core | M256 core |
|---|---:|---:|---:|---:|
| 16 / 16 | 16,257 | 606,387 | 22,854 | 612,954 |
| 32 / 16 | 15,846 | 546,009 | 22,404 | 552,579 |
| 16 / 32 | 13,574 | 574,406 | 20,154 | 581,004 |
| 32 / 32 | 13,034 | 414,891 | 19,629 | 421,479 |

## GEMM cycles: improve vs naive 32-port/32-bank

| M | Improve | Naive 32/32 | Naive - improve | Naive / improve | Improve cycle reduction |
|---:|---:|---:|---:|---:|---:|
| 4 | 6,431 | 13,034 | 6,603 | 2.027x | 50.66% |
| 256 | 272,856 | 414,891 | 142,035 | 1.521x | 34.23% |

## Kernel core cycles: improve vs naive 32-port/32-bank

| M | Improve | Naive 32/32 | Naive - improve | Naive / improve | Improve cycle reduction |
|---:|---:|---:|---:|---:|---:|
| 4 | 12,205 | 19,629 | 7,424 | 1.608x | 37.82% |
| 256 | 278,622 | 421,479 | 142,857 | 1.513x | 33.89% |

GEMM cycles: configuration acceptance to first completion-valid. Reduction = (naive - improve) / naive.
