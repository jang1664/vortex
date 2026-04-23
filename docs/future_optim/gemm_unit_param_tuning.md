# 04 — GEMM col tile size scaling

MXU_COL_TILE size 100M에 tight하게 해주자. FF 줄어들것.
Adder tree의 pipeline stage를 interval를 더 크게 해주기.
결국 target freq에서 최대한 tight하게 붙여서 FF를 줄이기.