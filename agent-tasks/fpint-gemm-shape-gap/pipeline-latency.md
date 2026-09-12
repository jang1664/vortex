# Minimum input-to-accumulator latency

For the captured TH16/MXU16 QCOL configuration without GEMM_SLR_PIPELINE,
count the accepted input handshake as cycle0. With no stalls and the required
PSUM ready by accumulator launch, the structural schedule is:

| Event | Cycle |
|---|---:|
| Input accepted / prefetch allocation opportunity | 0 |
| Compute launch after input1 + QCOL align1 + prealign3 | 5 |
| MXU/correction result and fall-through merge pop | 10 |
| Two-stage INT2FP result pop / normal PSUM demand opportunity | 12 |
| Scale1 + post-scale alignment2 completed / accumulator launch | 15 |
| One-cycle add result / write handshake if write-ready | 16 |

This is a no-stall lower bound, not the measured average or a guarantee that
naive LMEM can satisfy every demand by cycle15. PSUM prefetch has12 cycles from
input admission until demand and15 until the earliest addition; actual physical
read issue follows slot allocation and can be delayed independently.

Tagged FSDB extraction by pipeline_latency.py confirms the complete schedule
for improve M4 transaction5, which reads a PSUM: cfg offsets99/104/109/111/114/115.
Naive M4 transaction1024 (initial K, no PSUM read) confirms the same data-path
schedule at6912/6917/6922/6924/6927/6928. In the first10000 cycles sampled for
naive M4, PSUM-reading transactions have observed minimum demand/add/write
latencies24/27/28 because they encounter stalls; this is only that window's
observed minimum and is not substituted for the structural lower bound.

RTL: VX_gemm_compute_core.sv localparams45-81; input pipes1232/1258/1368;
fall-through merged FIFO1841; INT2FP metadata1890; scale alignment2156;
post-head launch2261; FP32 add2372. Captures and tagged records remain local
under captures/{naive4,improve4}/pipeline-latency/.
