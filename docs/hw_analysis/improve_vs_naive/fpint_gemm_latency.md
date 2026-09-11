# FPINT GEMM cycle 비교: improve vs naive

현재 RTL 기준, `xrt-vcs-sim`, TH16 / MXU16×16, K=N=512.

## GEMM cycles

| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |
|---:|---:|---:|---:|---:|---:|
| 4 | 6,449 | 25,547 | 19,098 | 3.961× | 74.76% |
| 256 | 272,870 | 1,315,844 | 1,042,974 | 4.822× | 79.26% |

GEMM cycles는 configuration 수락부터 최초 completion-valid까지의 구간이다.

## 전체 커널 core cycles

| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |
|---:|---:|---:|---:|---:|---:|
| 4 | 12,206 | 32,154 | 19,948 | 2.634× | 62.04% |
| 256 | 278,684 | 1,322,379 | 1,043,695 | 4.745× | 78.93% |

감소율 = `(naive − improve) / naive × 100`.
