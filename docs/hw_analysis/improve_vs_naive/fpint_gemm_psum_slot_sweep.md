# Naive FPINT GEMM cycles versus PSUM slot capacity

> This sweep used four weight response slots, before the default was increased to eight. Its PSUM plateau applies to that configuration; see the [current cycle comparison](fpint_gemm_latency.md).

`xrt-vcs-sim`, TH16 / MXU16x16, K=N=512, QBLK=32, QCOL, WT=0.
All sizes use mandatory prefetch reservation at Input admission.
Adapter read/data slots and physical response assembly slots grow together.
The separate response transport FIFO remains two entries.

## GEMM cycles

| Read/data slots | Physical response slots | M4 | M256 |
|---:|---:|---:|---:|
| 16 | 16 | 19,981 | 676,378 |
| 32 | 32 | 19,981 | 675,484 |
| 64 | 64 | 19,981 | 675,484 |

| Capacity change | M4 cycles saved | M256 cycles saved | M256 reduction |
|---|---:|---:|---:|
| 16 to 32 | 0 | 894 | 0.1322% |
| 32 to 64 | 0 | 0 | 0.0000% |

GEMM cycles span configuration acceptance through first completion-valid.

## Kernel core cycles

| Read/data slots | Physical response slots | M4 | M256 |
|---:|---:|---:|---:|
| 16 | 16 | 26,529 | 682,929 |
| 32 | 32 | 26,529 | 682,029 |
| 64 | 64 | 26,529 | 682,029 |

16 to 32 saves zero M4 core cycles and 900 M256 core cycles (0.1318%).
32 to 64 saves zero core cycles for either shape.

Among the tested capacities, M4 is flat from 16, and M256 is flat from 32.
M256 is already within 0.1322% of that plateau at 16. The default remains 16.
