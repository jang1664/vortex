# FPINT GEMM cycle 비교: improve vs naive

현재 RTL 기준, `xrt-vcs-sim`, TH16 / MXU16×16, K=N=512.
naive: PSUM read/response slot 16개, Input 수락 시 prefetch 예약.

## GEMM cycles

| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |
|---:|---:|---:|---:|---:|---:|
| 4 | 6,449 | 19,981 | 13,532 | 3.098× | 67.72% |
| 256 | 272,870 | 676,378 | 403,508 | 2.479× | 59.66% |

GEMM cycles는 configuration 수락부터 최초 completion-valid까지의 구간이다.

## 전체 커널 core cycles

| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |
|---:|---:|---:|---:|---:|---:|
| 4 | 12,206 | 26,529 | 14,323 | 2.173× | 53.99% |
| 256 | 278,684 | 682,929 | 404,245 | 2.451× | 59.19% |

감소율 = `(naive − improve) / naive × 100`.
