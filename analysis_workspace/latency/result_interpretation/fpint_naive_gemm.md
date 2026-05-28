# FPxINT Naive GEMM Bottleneck Analysis

## Summary

FPxINT naive GEMM is not bottlenecked by HBM latency or cache misses in the current no-stall DRAM configuration. For large GEMM sizes, the dominant bottleneck is the local LMEM-to-GEMM streaming path: the input LDMA and the MXU input valid stream deliver one 64 B activation vector every 15 cycles. The MXU datapath therefore produces one 32x32 KxN partial result event every 15 cycles, which corresponds to only 6.5% of an ideal one-event-per-cycle MXU issue rate.

For `m256_k256_n256`, GEMM compute accounts for 252,435 cycles, or 80.6% of the GEMM window. The corrected internal MXU throughput is 132.9 flop/compute-cycle, whereas a 32x32 MAC event every cycle would be 2048 flop/cycle. For `m1_k256_n256`, the bottleneck changes: only 4,094 cycles are spent in compute, while 36,397 cycles are non-compute GEMM overhead. This small-M case has very poor amortization of weight loading and synchronization overhead.

## Methodology

The analysis uses the generated FPINT CSVs under `analysis_workspace/latency`:

- `fpint_naive_phase_compact.csv`
- `fpint_naive_mpm_compact.csv`
- `fpint_naive_util_compact.csv`
- `fpint_naive_fire_interval_compact.csv`
- `fpint_naive_sync_wait_compact.csv`
- `fpint_naive_system_compact.csv`
- `fpint_naive_mxu_pipeline_compact.csv`

Additional metrics were added to `cycle_util.py` to sample the memory subsystem and internal MXU pipeline signals directly from FSDB. In particular, `merger_in_valid` is used as the internal MXU result event. This is more accurate than the existing MPM `macs` field for throughput analysis.

The current traces are:

| Workload | User body cycles | GEMM total | GEMM compute | GEMM non-compute | Compute / GEMM |
|---|---:|---:|---:|---:|---:|
| `fpint_naive_m1_k256_n256` | 44,061 | 40,555 | 4,094 | 36,397 | 10.1% |
| `fpint_naive_m256_k128_n128` | 98,069 | 94,555 | 63,174 | 31,349 | 66.8% |
| `fpint_naive_m256_k256_n256` | 316,856 | 313,331 | 252,435 | 60,768 | 80.6% |

`GEMM non-compute` is `gemm_total - gemm_compute - gemm_stall`. Top-level GEMM stall is negligible in all traces: 64, 32, and 128 cycles respectively.

## Correcting the MAC Counter

The MPM `macs` field should not be used as the true FPxINT GEMM MAC count. In RTL, `perf_mac_count_r` increments on `perf_output_fire`, where `perf_output_fire = o_lmem_bus_if.req_valid && o_lmem_bus_if.req_ready`. This counts output LMEM transactions, not internal MXU multiply-accumulate events.

The internal compute event is `merger_in_valid = &mxu_output_valid_dly`, which fires when all delayed MXU column outputs are valid. With `MXU_ROW=32` and `MXU_COL=32`, one `merger_in_valid` event represents 1024 MACs for one K-microtile and 32 output columns.

| Workload | MPM MAC count | `merger_in_valid` events | Corrected MAC count | Under-count factor |
|---|---:|---:|---:|---:|
| `m1_k256_n256` | 8,192 | 64 | 65,536 | 8.0x |
| `m256_k128_n128` | 1,048,576 | 4,096 | 4,194,304 | 4.0x |
| `m256_k256_n256` | 2,097,152 | 16,384 | 16,777,216 | 8.0x |

The corrected MAC counts exactly match `M*K*N`. Therefore, all throughput conclusions below use the corrected `merger_in_valid`-based count.

## MXU Cadence

For the two large GEMMs, every major MXU datapath valid signal has the same steady-state cadence:

| Workload | Compute cycles | `merger_in_valid` events | Median event interval | P90 event interval | Corrected flop/compute-cycle | Ideal-peak fraction |
|---|---:|---:|---:|---:|---:|---:|
| `m1_k256_n256` | 4,094 | 64 | 556 cycles | 564 cycles | 32.0 | 1.56% |
| `m256_k128_n128` | 63,174 | 4,096 | 15 cycles | 15 cycles | 132.8 | 6.48% |
| `m256_k256_n256` | 252,435 | 16,384 | 15 cycles | 15 cycles | 132.9 | 6.49% |

The large-GEMM behavior is internally consistent: one 1024-MAC event every 15 cycles gives `2*1024/15 = 136.5` flop/cycle before boundary effects, close to the measured 132.8-132.9 flop/compute-cycle. Thus the low PE utilization is not a measurement artifact; it follows directly from the observed issue interval.

This 15-cycle interval is already visible before the post-MXU scaler/accumulator path:

- `mxu_input_p50 = 15 cycles`
- `ldma_input_src_rd_req_p50 = 15 cycles`
- `ldma_input_dst_wr_p50 = 15 cycles`
- `merger_in_valid_p50 = 15 cycles`

Therefore, the primary limiter is upstream of the MXU arithmetic tree. The MXU can process an input-valid stream, but the local DMA path only supplies one activation vector every 15 cycles in steady state.

## Memory System

External memory is not the bottleneck in these traces. The global DMA never stalls on either side:

| Workload | DMA active / GEMM | DMA wait dcache | DMA wait LMEM | HBM read mean latency | Dcache read mean latency | LMEM read mean latency |
|---|---:|---:|---:|---:|---:|---:|
| `m1_k256_n256` | 41.8% | 0 | 0 | 3.03 cycles | 4.88 cycles | 3.00 cycles |
| `m256_k128_n128` | 45.9% | 0 | 0 | 3.02 cycles | 4.40 cycles | 3.00 cycles |
| `m256_k256_n256` | 40.7% | 0 | 0 | 3.00 cycles | 4.12 cycles | 3.00 cycles |

The L2 hit rate is modest for the large run (`m256_k256_n256`: 50.1% read hit, 36.4% overall hit), but it does not translate into long service latency because DRAM Markov stalls are disabled and HBM read latency remains about 3 cycles. Thus cache misses do not dominate the measured execution time.

The important memory-side bottleneck is not off-chip latency. It is the local data-movement microarchitecture between LMEM and the GEMM unit. In RTL, the input path uses `VX_lmem_dma_misal` with a per-segment FSM sequence: prepare segment, decide, issue source read, wait for response, decide, issue destination write, advance segment. For input, `seg_size = MXU_KT*16/8 = 64 B`, and each 64 B segment feeds one 32-element FP16 activation vector into the GEMM unit. The measured 15-cycle interval is the cost of this serialized per-vector local DMA sequence.

## Synchronization Behavior

The sync wait counters show that large GEMM execution is waiting for GEMM completion, not for weight preload:

| Workload | G0 wait | G1 wait | W0 wait | W1 wait | O wait |
|---|---:|---:|---:|---:|---:|
| `m1_k256_n256` | 2,143 | 2,143 | 15,680 | 15,400 | 143 |
| `m256_k128_n128` | 31,649 | 31,621 | 1,105 | 0 | 13,095 |
| `m256_k256_n256` | 126,434 | 126,385 | 4,413 | 0 | 20,279 |

For `m256_k256_n256`, `G0 + G1 = 252,819`, which matches the GEMM compute window of 252,435 cycles. This agrees with the RTL: the input child reports completion through `gemm_unit_if.done`, and `gemm_done` is asserted only when the accumulator write FSM leaves its write state. Therefore, G-register waits are essentially waits for the GEMM compute/accumulate pipeline to finish.

The M=1 case is different. `W0 + W1 = 31,080` cycles dominates the observed waits, while compute is only 4,094 cycles. This indicates that the single-row workload is dominated by weight/register preload and control synchronization overhead. It does not amortize weight loading across many M rows.

## RTL Interpretation

The RTL supports the measured bottleneck:

- `VX_gemm_unit.sv` defines `in_flight = (state == COMPUTE)`, so `gemm_compute_cycles` measures the full compute state, not just arithmetic issue.
- The compute state exits only when the accumulator write FSM is about to finish. Thus compute cycles include MXU output conversion, scaling, accumulation, and accumulator-memory write completion.
- `merger_in_valid` is generated from the delayed MXU output-valid vector, so it is the correct internal event to count MXU results.
- `perf_mac_count_r` increments on output LMEM request fire, so it is a writeback-proxy counter and undercounts true MACs when K has multiple microtiles.
- `acc_rd_fifo_full` is high in large runs: 69.3% and 81.0% of compute cycles. Since `gemm_stall_cycles` and DMA wait counters remain near zero, this is not an external-memory stall. It shows that psum prefetch is ahead of the slower MXU/output consumption cadence.
- The PE tree itself is pipelined with elastic buffers and reduction-tree valid propagation. The sparse `input_valid_i` stream, rather than arithmetic pipeline latency, determines the sustained `merger_in_valid` interval.

Relevant RTL anchors:

- `hw/rtl/core/gemm/VX_gemm_unit.sv`: `in_flight`, compute-state exit, `gemm_done`, `merger_in_valid`, accumulator write completion, and perf-counter definitions.
- `hw/rtl/core/gemm/VX_gemm_node.sv`: input DMA configuration (`seg_size = MXU_KT*16/8`), LMEM/GEMM split, and `u_input_lmem_dma` instantiation.
- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`: per-segment FSM states for source read, response wait, destination write, and segment advance.
- `hw/rtl/core/gemm/VX_pe_tree_new.sv`: pipelined MAC/reduction tree with valid propagation from `input_valid_i`.

## Bottleneck Conclusion

For large FPxINT naive GEMM, the limiting factor is the LMEM-to-GEMM local DMA/input issue cadence. The arithmetic array only receives useful work every 15 cycles, resulting in about 6.5% of the ideal one-32x32-event-per-cycle rate. HBM/cache latency is not the limiting factor under the current simulation configuration.

For `m1_k256_n256`, the bottleneck is fixed overhead: weight preload and synchronization dominate because only one M row is computed. This case is not representative of the scalable compute path; it primarily measures the cost of the GEMM orchestration around a small amount of useful work.

The next optimization target should be the local DMA/GEMM input stream. Specifically, reducing the per-64B segment FSM overhead or converting the LMEM-to-GEMM input path into a more continuous stream would directly reduce the 15-cycle interval and raise MXU utilization. The MPM MAC counter should also be fixed or supplemented to count `merger_in_valid * MXU_ROW * MXU_COL`, otherwise reported flop/cycle substantially underestimates actual internal work.
