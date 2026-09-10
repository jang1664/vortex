# FPINT GEMM latency: improve vs naive, th16 / MXU16x16

Measured on 2026-09-10 with current RTL in `xrt-vcs-sim`. The naive results include the MXU16 support and pending-write accounting fix authorized during this task. Baseline source revision: `dc3f571bd05ed69332fc299ccff739f8573db4e1`. No FPGA bitstream was used for these results.

- **M=4, K=512, N=512:** improve is **9.546x faster** over the GEMM interval, reducing latency by **89.52%**. Whole-kernel speedup is **5.584x**.
- **M=256, K=512, N=512:** improve is **5.031x faster** over the GEMM interval, reducing latency by **80.12%**. Whole-kernel speedup is **4.949x**.

## GEMM interval

`total_cycles` is the accelerator-controller active interval, including its memory work. It excludes CPU setup before accelerator invocation and completion work afterward. At the configured 100 MHz logic clock, one cycle is 0.01 us.

| M | K | N | naive cycles | improve cycles | naive time (us) | improve time (us) | Speedup | Latency reduction |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4 | 512 | 512 | 61,552 | 6,448 | 615.52 | 64.48 | 9.546x | 89.52% |
| 256 | 512 | 512 | 1,372,729 | 272,869 | 13727.29 | 2728.69 | 5.031x | 80.12% |

Speedup = naive cycles / improve cycles. Reduction = (naive cycles - improve cycles) / naive cycles.

## Whole kernel

`PERF: instrs=..., cycles=...` reports the core cycle counter and includes device-side setup, dispatch, polling, and completion. These are simulated device cycles, not host wall-clock measurements.

| M | naive cycles | improve cycles | naive time (us) | improve time (us) | Speedup | Latency reduction |
|---:|---:|---:|---:|---:|---:|---:|
| 4 | 68,154 | 12,206 | 681.54 | 122.06 | 5.584x | 82.09% |
| 256 | 1,379,304 | 278,684 | 13793.04 | 2786.84 | 4.949x | 79.80% |

## Conditions and interpretation

- Both: XLEN64, one core, four warps, 16 threads; MXU_ROW=16, MXU_COL=16, MXU_COL_TILE=16, MXU_WLOAD_NUM=4; 32 KiB I/D caches, four D-cache banks, two L1 memory ports; 1 MiB LMEM; accumulator depth 1024.
- Improve: `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`, plus `-DDCACHE_NUM_BANKS=4 -DL1_MEM_PORTS=2`. Dedicated 512 KiB TMEM with 16 banks, eight tile-DMA channels, GEMM_TIMING_CUTS=1, eight LMEM DMA read slots.
- Naive: `configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh`. Sixteen LMEM ports/banks, no dedicated TMEM, sixteen LMEM DMA read slots. The comparison matches compute geometry; it does not equalize SRAM area or replace the backends with identical memory pipelines.
- Arguments: `-m M -k 512 -n 512 -q 32 -t 0 -d 0 -r 1`. FP16 activations, packed INT4 weights, FP16 output. Improve uses `fpint_gemm_ffn_hw`; naive uses `fpint_gemm_ffn_hw_naive`. Improve reserves an 8-row-aligned layout for M=4 but computes/verifies the requested rows.
- One fresh kernel invocation per shape, with numerical output verification. No warmup or host benchmark loop. All four reported cases returned zero and printed `PASSED`.
- Both memory-model manifests specify 100 MHz logic, eight 64-byte AXI ports, 300 MHz HBM AXI, HBM2_2Gbps, and the same abstract switch profile. No DRAM/CACHE environment overrides were present. The model explicitly reports uncalibrated timing; microseconds here are simulated time, not measured board latency.
- Improve runs retained wrapper-default waveform dumping. Final naive runs used `-DDISABLE_FSDB` to reduce simulation wall time. Naive M4 returned identical GEMM/core cycles with and without waveform dumping.

| M | naive DMA/MXU overlap | improve DMA/MXU overlap |
|---:|---:|---:|
| 4 | 28.470% | 91.795% |
| 256 | 79.665% | 96.254% |

The logged overlap is overlap cycles divided by DMA-active cycles, not a percentage of total GEMM time. These percentages are not directly comparable: VX_core ties the naive local-DMA performance structs to zero, while improve includes local operand/output DMA activity in the DMA-active union. The [M4 FSDB analysis](fpint_gemm_m4_bandwidth_analysis.md) compares explicitly selected external-DMA busy signals and common MXU input handshakes instead. It finds faster external transfers together with a large reduction in repeated command startup and completion gaps.

The common compute core currently leaves compute_cycles, stall_cycles, and mac_count zero and maps job_count to accumulator-write count. Therefore this report does not interpret the printed zero FLOPs/cycle or the jobs field as performance/workload counts. The latency fields are independently wired controller/core counters.

## MXU16 support and validation

The original naive RTL rejected MXU16. The changes make the controller microtile dimensions follow MXU_ROW/MXU_COL, place tensor clients at offsets 0/4/8/12 for MXU16 while retaining 0/8/16/24 for MXU32, and permit eight-lane PSUM response joins.

M256 exposed a pending-write underflow: VX_mem_bus_split can forward individual lanes before the complete wide request is acknowledged. Pending writes are now reserved once when a wide request is first presented, retained through backpressure, and decremented at downstream lane completion. This applies to PSUM ordering counters and aggregate write-drain tracking.

- PSUM join tests passed for 8 and 16 lanes: out-of-order completion, FIFO backpressure, stale responses, occupied reset, and early lane responses before all request lanes are accepted.
- Both MXU16 GEMM shapes passed numerical verification after the write-reservation fix.
- Existing MXU32 naive M4/K512/N512 passed numerical verification after the fix; its GEMM/core cycles remained 16,943/23,529.
- No synthesis or hardware timing closure was run for the new configuration.

## Reproduction

Run from the repository root. Use new, empty build directories; the existing VCS make target can reuse a stale simulator after a header-only RTL change.

```bash
mkdir -p build_fpint_latency_improve_vcs build_fpint_latency_naive_vcs
for variant in improve naive; do
  (cd "build_fpint_latency_${variant}_vcs" && ../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex")
  python3 agent-tasks/fpint-gemm-latency-compare/run_vcs.py "$variant"
done
python3 agent-tasks/fpint-gemm-latency-compare/write_report.py
```

The runner sources the task config from the repository root, then invokes the following from each configured build directory, with the appropriate APP and M:

```bash
ci/run_black.sh xrt-vcs-sim --perf 3 --app APP --args "-m M -k 512 -n 512 -q 32 -t 0 -d 0 -r 1"
```

The current runner adds DISABLE_FSDB for both variants. Exact configs and commands used for the reported measurements are in each results.json.

## Evidence

- [Improve M4 log](logs/vcs_improve/m4.log), [improve M256 log](logs/vcs_improve/m256.log), [improve results/config](logs/vcs_improve/results.json), [memory model](logs/vcs_improve/u55c_model_manifest.json).
- [Naive M4 log](logs/vcs_naive/m4.log), [naive M256 log](logs/vcs_naive/m256.log), [naive results/config](logs/vcs_naive/results.json), [memory model](logs/vcs_naive/u55c_model_manifest.json).
- [Eight-lane PSUM test](logs/psum_join_lanes8.log), [sixteen-lane PSUM test](logs/psum_join_lanes16.log), [MXU32 regression](logs/vcs_naive32/m4.log).
- [Original source hashes](logs/source_manifest.json), [final change hashes](logs/final_change_manifest.json). Simulator fingerprints are saved under each variant log directory.
- Preliminary physical-board results under `logs/hardware_preclarification/` are excluded. Failed intermediate attempts are retained with descriptive prefixes.
