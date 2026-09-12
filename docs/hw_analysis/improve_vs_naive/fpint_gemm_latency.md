# FPINT GEMM cycle 비교: improve vs naive

현재 RTL 기준, `xrt-vcs-sim`, TH16 / MXU16×16, K=N=512, micro-tile N-fast.
외부 DMA read slot: improve 채널당 16개, naive 32개. Weight response slot은 양쪽 모두 8개, naive PSUM read/response slot은 16개. Naive는 주소 의존성을 보존하는 PSUM read 우선 정책(R=1)을 사용한다.

## GEMM cycles

| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |
|---:|---:|---:|---:|---:|---:|
| 4 | 6,431 | 15,693 | 9,262 | 2.440× | 59.02% |
| 256 | 272,856 | 576,763 | 303,907 | 2.114× | 52.69% |

GEMM cycles는 configuration 수락부터 최초 completion-valid까지의 구간이다.

## 전체 커널 core cycles

| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |
|---:|---:|---:|---:|---:|---:|
| 4 | 12,205 | 22,254 | 10,049 | 1.823× | 45.16% |
| 256 | 278,622 | 583,329 | 304,707 | 2.094× | 52.24% |

감소율 = `(naive − improve) / naive × 100`.
