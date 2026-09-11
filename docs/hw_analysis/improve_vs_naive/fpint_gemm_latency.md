# FPINT GEMM cycle 비교: improve vs naive

현재 RTL 기준, `xrt-vcs-sim`, TH16 / MXU16×16, K=N=512.
양쪽 모두 micro-tile N-fast, Weight response slot 8개. naive PSUM read/response slot은 16개이며 Input 수락 시 prefetch를 예약한다.

## GEMM cycles

| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |
|---:|---:|---:|---:|---:|---:|
| 4 | 6,433 | 15,867 | 9,434 | 2.467× | 59.46% |
| 256 | 272,869 | 671,929 | 399,060 | 2.462× | 59.39% |

GEMM cycles는 configuration 수락부터 최초 completion-valid까지의 구간이다.

## 전체 커널 core cycles

| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |
|---:|---:|---:|---:|---:|---:|
| 4 | 12,206 | 22,404 | 10,198 | 1.835× | 45.52% |
| 256 | 278,684 | 678,504 | 399,820 | 2.435× | 58.93% |

감소율 = `(naive − improve) / naive × 100`.

## improve의 micro-tile 순서 변경 전후

| M | K-fast GEMM | N-fast GEMM | cycle 감소 | K-fast core | N-fast core |
|---:|---:|---:|---:|---:|---:|
| 4 | 6,449 | 6,433 | 16 | 12,206 | 12,206 |
| 256 | 272,870 | 272,869 | 1 | 278,684 | 278,684 |
