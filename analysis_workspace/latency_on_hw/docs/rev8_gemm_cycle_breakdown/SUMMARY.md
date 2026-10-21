# rev8 GEMM cycle breakdown: why C1 can beat C2/C3

Measured 2026-10-20. This extends the [previous FSDB port profile](../rev8_gemm_port_profile/SUMMARY.md). Production datapath RTL and GEMM kernels were not changed for this investigation.

## Findings

The strongest identified cause of the Llama3 Gate/Up reversal is the **address-dependent cost of weight DMA on the cache-miss/external-memory path**. The reversal is reproducible on FPGA, and removing both MXUs from the experiment preserves the direction of the penalty. Port concentration exists, but port count alone does not explain all measurements.

This conclusion concerns the measured linear GEMM, especially M1 K4096 N14336. It is not a complete attribution of every attention GEMM or the entire B1/KV8192 decoder graph. The rev8 suite reuses C3 linear measurements for C2; separate C2 hardware checks below confirm the same trend.

## 1. Complete GEMM on the same FPGA

BDF `0000:2a:00.1`, existing rev8 aliases, M1 K4096, three benchmark iterations with no warmup. Values are the last iteration's core cycle CSR, not host wall time. Duplicate PERF lines are duplicate dumps, not independent samples.

| Candidate / linear engine | N14336 | N14464 | N11008 | N14336 to N14464 |
|---|---:|---:|---:|---:|
| C1 FPFP | 5,410,928 | 8,324,963 | 6,299,445 | +53.85% |
| C2 FPINT | 8,309,942 | 4,253,689 | 4,331,326 | -48.81% |
| C3 FPINT | 7,914,588 | 4,311,470 | 4,352,674 | -45.53% |

N14464 has **0.893% more columns** than N14336. The change adds one N tile and changes row stride. More arithmetic cannot explain the large speedup of C2/C3 or the opposite response of C1.

C2 N14336 uses the clean confirmation log. An earlier run reported 8,098,522 cycles, but overlapped briefly with preparation of a separate diagnostic in the same build directory. That value is excluded from the table; the diagnostic was stopped and subsequently run in its own configured build directory. C1/C3 table measurements were completed before that overlap.

To account for the different tile count, divide kernel cycles by `(K/128)*(N/128)`:

| Candidate | N14336 cycles/tile | N14464 cycles/tile | Difference |
|---|---:|---:|---:|
| C1 | 1,509.75 | 2,302.26 | +792.51 |
| C2 | 2,318.62 | 1,176.35 | -1,142.27 |
| C3 | 2,208.31 | 1,192.33 | -1,015.98 |

These are normalized whole-kernel costs, not isolated tile latency. Benchmark mode does not numerically validate the full-size outputs; the small complete VCS jobs and the DMA probes below do validate their outputs.

## 2. Exact, non-overlapping VCS cycle partition

Complete M1 K128 N512 jobs, `xrt-vcs-sim --perf 3`, both functionality PASS. Testbench observation preserves the previously measured core cycles exactly. The CSV is sampled before each active edge and its row count equals the RTL GEMM job cycle counter.

| Exclusive activity bucket | C3 FPINT | C1 FPFP |
|---|---:|---:|
| DMA executor active, arithmetic pipeline empty | 2,308 | 1,445 |
| DMA executor active, arithmetic pipeline nonempty | 1,316 | 3,321 |
| DMA executor idle, arithmetic pipeline nonempty | 405 | 1,899 |
| DMA executor idle, arithmetic pipeline empty | 20 | 15 |
| **GEMM job total** | **4,049** | **6,680** |
| Core cycles outside the GEMM job | 8,328 | 7,903 |
| **Whole kernel core cycles** | **12,377** | **14,583** |

Pipeline nonempty means resident work, including stalls, not useful MAC execution on every cycle. DMA executor time includes descriptor setup, completion polling, and output preparation. The four buckets are disjoint; summing independent executor totals would double-count overlap. Core cycles outside the job are device-side software/startup/completion work, not CPU-to-device transfer time.

DMA executor active time, attributed to its current tensor:

| Tensor | C3 | C1 |
|---|---:|---:|
| Input | 294 | 254 |
| Weight | 2,274 | 4,224 |
| Scale | 384 | 0 |
| Zero point | 384 | 0 |
| Output | 288 | 288 |
| Total DMA-active cycles, including overlap | 3,624 | 4,766 |

Additional observations:

| Event | C3 | C1 |
|---|---:|---:|
| Input packets accepted | 256 | 512 |
| Accumulator write events | 256 | 512 |
| Input valid but not ready | 137 | 4,164 |
| Weight installation events (perf) | 1,024 | 4,096 |

FPFP ROW8 versus FPINT ROW16 doubles micro-input/accumulator packets here. FPFP WLOAD1 versus FPINT WLOAD4 also requires more installation events. C1 therefore does not have an intrinsically cheaper compute schedule in this test. Quantization parameters cost C3 768 DMA-executor cycles, but this alone cannot explain the N-dependent reversal.

### Counter limitations

Existing FPGA images return zero for the detailed DMA/cache/MXU performance counters; total core cycles remain usable. An exact full-size **hardware** phase partition is therefore not available from those images. The partition above is explicitly a smaller **simulation** result.

In `VX_gemm_compute_core.sv`, `perf.job_count` is assigned the accumulator-write event counter, while some compute/stall fields remain zero. Thus the printed compute-side `jobs=256` is not 256 submitted GEMM jobs, and zero compute/stall fields do not establish zero work/stalls. The node's job-active cycle counter is separately used to validate the trace partition.

## 3. DMA-only hardware experiment

The new `gemm_dma_profile` diagnostic submits the same strided DRAM-to-LMEM descriptor geometry, with **no GEMM arithmetic**. Every copied 64-bit word is checked outside the timed interval. All 18 authoritative profiles PASS with zero errors.

For each strided profile: 32 K tiles, four column tiles, two immediate copies per tile, 256 samples. The source starts at `0x12000`. The destination is contiguous LMEM. Timing is device MCYCLE from after the MMIO kick to observed completion, including polling overhead. Descriptor setup is measured separately: approximately 483–484 cycles per transfer, essentially unchanged across these cases.

The following table uses **the same C3 FPGA image for every row**, so it changes data layout without changing compute hardware. The matching C1-image probes reproduce the decisive N14336/N14464 trend.

| Source pattern | Rows | Bytes/row | Stride (bytes) | First-copy wait, mean cycles | Immediate-repeat wait |
|---|---:|---:|---:|---:|---:|
| INT4 N14336 | 128 | 64 | 7,168 | **2,184.45** | 649 |
| INT4 N14464 | 128 | 64 | 7,232 | **1,034.40** | 649 |
| INT4 N11008 | 128 | 64 | 5,504 | 1,416.82 | 649 |
| FP16 N14336 | 128 | 256 | 28,672 | **1,802.87** | 1,417 |
| FP16 N14464 | 128 | 256 | 28,928 | **2,568.37** | 649 |
| FP16 N11008 | 128 | 256 | 22,016 | 2,184.47 | 1,417 |
| Scale or zero, N14336 | 4 | 256 | 28,672 | 647.46 | 265 |
| Scale or zero, N14464 | 4 | 256 | 28,928 | 647.48 | 265 |

“First copy” is a first visit to that tile in this traversal, not a guarantee that every cache level is cold. Immediate repeat follows copy verification; it is a controlled reuse test, not the full GEMM's reuse distance.

- INT4's N14336 penalty versus N14464 is **1,150.05 cycles** per first copy. Its repeat times are identical. This localizes the difference to source delivery on misses rather than arithmetic or destination copying.
- FP16 changes in the opposite direction: N14464 costs **765.50 extra cycles** per first copy, although both patterns use four HBM-facing ports.
- These deltas are of the same scale and direction as whole-GEMM normalized changes: C3 -1,015.98 and C1 +792.51 cycles/tile. They are not an exact additive accounting: the diagnostic has software overhead and no compute overlap.
- Scale/zero descriptor timings barely change, so they do not explain the large stride sensitivity.

A contiguous control on the same C3 image costs 1,029.31 cycles for 8 KiB and 2,182.69 for 32 KiB; immediate repeats cost 649. The 8 KiB control removes most of the INT4 strided penalty in this probe. Packing is not universally faster: the original FP16 strided first copy is faster than the 32 KiB contiguous control.

Earlier exploratory probes executed `vx_fence` between transfers. In this system FENCE flushes caches and invalidates a warm-repeat interpretation. Those logs are excluded. The final diagnostic uses compiler barriers within the loop and a single final fence; only `nofence_dma_*.log` and the separately built `dense_dma_b*.log` enter `hardware_dma.json`.

## 4. Port mapping, cache conflicts, and what simulation proves

The existing FSDB already directly verified one-port weight tiles for INT4 N14336, two-port tiles for INT4 N11008, and four-port tiles for FP16. With 64-byte line address L, the configured mapping selects port `L % 4` and HBM bank `8*(L%4) + ((L//4)%8)`.

The Dcache has 128 global bank/set positions and four ways (32 KiB total). For 128 source rows per tile, the address geometry is:

| Format / N | Ports | Distinct configured HBM banks | Dcache bank/set positions | Lines per position |
|---|---:|---:|---:|---:|
| INT4 / 14336 | 1 | 2 | 8 | 16 |
| INT4 / 14464 | 4 | 32 | 128 | 1 |
| INT4 / 11008 | 2 | 16 | 64 | 2 |
| FP16 / 14336 | 4 | 4 | 8 | 64 |
| FP16 / 14464 | 4 | 32 | 128 | 4 |
| FP16 / 11008 | 4 | 16 | 64 | 8 |

These are address-derived mappings, not measurements of internal proprietary HBM-controller activity. Set pressure above four lines exceeds L1 associativity. L2 has 1 MiB, two banks, eight ways, and 2,048 global bank/set positions; it can absorb repeated accesses that miss L1.

A separate complete VCS probe with 16 rows, 256 bytes/row and two copies confirms extra L1 conflict traffic:

| Stride | Dcache read misses | L2 reads | L2 read misses | Whole kernel cycles |
|---|---:|---:|---:|---:|
| 28,672 | 336 | 372 | 177 | 179,889 |
| 28,928 | 270 | 306 | 177 | 179,863 |

Both PASS. Counters include startup and verification, but the matched runs have 66 extra Dcache misses/L2 reads and unchanged L2 misses. Extra traffic is served by L2. Their first/repeat DMA waits are nevertheless identical (765/649 cycles), showing that the current VCS memory model does not reproduce the real FPGA's large cold-transfer penalty.

**Supported boundary:** address pattern affects cache traffic and external-memory delivery enough to reverse the candidates' ordering. **Not established:** which proprietary HBM scheduling/row-buffer/queue behavior accounts for each extra hardware cycle. Counting ports alone, or treating all cache conflicts as equivalent penalties, overstates the evidence.

## 5. Reproduction and retained evidence

Hardware aliases:

- C1: `fpfp_th16_m8_n16_wload1_all_bram_acc`
- C2: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_fpfp_m8_n16_wload1_base_pnr_v3_qcol_pnr_spread`
- C3: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3_fix_sub_norm`

From a configured, dedicated build directory:

```bash
./ci/run_black.sh hw --fpga-bin ALIAS --app APP --bench --perf 0 --power=off \
  --args "--warmup=0 --iterations=3 -m 1 -k 4096 -n 14336 -q 32 -t 0 -d 0"
./ci/run_black.sh hw --fpga-bin ALIAS --app gemm_dma_profile --perf 0 --power=off \
  --args "-r 128 -b 64 -s 7168 -t 32 -n 4 -p 2"
```

APP is `fpfp_gemm_ffn_hw_naive` for C1, `fpint_gemm_ffn_hw_naive` for C2/C3. See the [diagnostic README](../../../../tests/regression/gemm_dma_profile/README.md) for parameter semantics and timing limitations.

For complete VCS GEMM traces, source the candidate config, add `-DFSDB_PORT_PROFILE -DGEMM_BREAKDOWN` to CONFIGS, and run `xrt-vcs-sim --app APP --args "-M 1 -K 128 -N 512" --perf 3`. The observer is testbench-only and gated by the FSDB build guards.

Retained evidence:

- [FPINT phase summary](fpint_m1_k128_n512.json), [FPFP phase summary](fpfp_m1_k128_n512.json), [trace analyzer](analyze_cycles.py).
- [Hardware GEMM measurements](hardware_gemm.json), [verified DMA measurements](hardware_dma.json), [log collector](collect_hardware.py).
- `build_rev8_port_{fpint,fpfp}/captures/breakdown_m1_k128_n512/`: CSV, FSDB, simulator log.
- `build_rev8_port_fpint/captures/dma_cache16_s{28672,28928}/`: cache-control FSDB/logs; host logs are in the build root.
- `build_rev8_breakdown_hw_{c1,c3}/matched_*.log` and `nofence_dma_*.log`; dense controls in `build_rev8_breakdown_dma_dense/`.

The raw waveform/build artifacts are ignored build outputs and may be lost during build cleanup. The JSON summaries and this report retain the measured counts and provenance.
