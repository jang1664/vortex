# Cause of the C2/C3 cached-kernel slowdown

The two-port DMA configuration inserts a buffered CPU/DMA arbiter on the second CPU D-cache lane. The one-port configuration connects that lane directly to the cache. This changes ordinary CPU load/store latency even when the kernel submits no DMA descriptors.

## Resolved geometry

A standalone VCS probe evaluated the package constants and configuration macros from each frozen candidate config; it did not infer defaults from shell flags. See `config_probe_results.json`, `tb_config_probe.sv`, and `probe_config.py`.

| Candidate | CPU D-cache ports | D-cache banks | L1 memory ports | DMA D-cache ports |
|---|---:|---:|---:|---:|
| C1 | 2 | 2 | 2 | 1 |
| C2 | 2 | 2 | 2 | 2 |
| C3 | 2 | 2 | 2 | 2 |
| C4 | 2 | 2 | 2 | 1 |

All four use 32 KiB D-cache and the same 100 MHz model clock. C2 and C3 differ in TCU support, yet have identical kernel hashes, instruction counts and cycles for all three original workloads. These measurements do not implicate TCU execution or a different D-cache bank count.

## Controlled experiment

The frozen C3 config was copied to `config_dma1.sh`, changing **only** `DMA_DCACHE_PORTS=2` to `DMA_DCACHE_PORTS=1`. Response reordering remains enabled. LMEM stays 1.25 MiB; cache geometry, GEMM hardware and all other defines stay unchanged. Both cases used a separately configured `build_dma1_diagnostic` and `ci/run_black.sh xrt-vcs-sim`, with the original variants, shapes and deterministic inputs.

| Workload | Original C3, DMA ports=2 | Controlled C3, DMA ports=1 | Extra cycles with 2 ports, relative to 1 | Instructions in both | Reference checks |
|---|---:|---:|---:|---:|---|
| quant_v | 251,869 | 247,016 | +4,853 (+1.965%) | 1,078,114 | PASS / PASS |
| softmax | 367,738 | 363,687 | +4,051 (+1.114%) | 1,294,112 | PASS / PASS |

Both controlled kernels are byte-identical to the respective original C3 kernel. The instruction counts also match exactly. Per-case `result.json`, `command.sh`, compiler/simulator logs and model manifests are retained under `quant_v/` and `softmax/`; `results.json` contains the combined measurements. `config_dma1.diff` records the single config change.

V quantization becomes exactly equal to C1/C4: 247,016 cycles. Its entire observed 4,853-cycle C2/C3 penalty is reproduced by changing this one define in C3. The K-quantization penalty (+4,917 cycles, +0.719% versus C1) is consistent with the same topology and uses the same binary across candidates, but K quantization was not rerun in the one-port controlled config.

Softmax saves 4,051 cycles in the controlled experiment. The controlled value, 363,687, is 1,380 cycles below C1's 365,067. Thus the full C1-versus-C3 difference (+2,671 cycles) combines the measured DMA-port cost with other config-dependent timing effects. This experiment does not isolate that remaining 1,380-cycle difference, and it should not be attributed solely to LMEM capacity.

## RTL mechanism

`hw/rtl/core/VX_mem_unit.sv:491` selects `g_cpu_dma_arb` when the CPU lane index is smaller than `DMA_DCACHE_PORTS`; otherwise the CPU lane uses the direct `g_cpu_only` assignment at line 522. The arbiter uses `REQ_OUT_BUF=3` and `RSP_OUT_BUF=3` (lines 511-512).

| CPU cache lane | DMA ports=1 | DMA ports=2 |
|---|---|---|
| 0 | Buffered CPU/DMA arbiter | Buffered CPU/DMA arbiter |
| 1 | Direct CPU connection | Buffered CPU/DMA arbiter |

`hw/rtl/mem/VX_mem_arb.sv:56` sends requests through `VX_stream_arb`; the response path uses `VX_stream_switch` at line 133. `hw/rtl/VX_platform.vh:317` and line 320 decode buffer value 3 as size=2 and output-register setting=1. The second lane therefore gains registered elastic buffers on both request and response paths. The added CPU path and handshake buffering exists even with an idle DMA client; active DMA contention is not needed for this overhead.

The controlled run establishes the cost of changing the port topology. Detailed cache-stall counters were not collected, so no exact per-stall or per-request cycle attribution is claimed. DMA response reorder buffers act on the DMA path and remain enabled in both controlled configs.

## Why C4 softmax also executes fewer instructions

Softmax computes its per-warp scratch stride from `LMEM_SIZE / NUM_WARPS` in `tests/regression/softmax/kernel.rev2_shuffle_grouped.cpp:14`, then passes it to `__local_mem` at line 81. `kernel/include/vx_spawn.h:45` multiplies the local group ID by that stride.

| Candidate | LMEM | Per-warp scratch stride | Offset calculation |
|---|---:|---:|---|
| C1 | 1.5 MiB | 384 KiB, `0x60000` | Constant load, multiplication, truncation |
| C2/C3 | 1.25 MiB | 320 KiB, `0x50000` | Constant load, multiplication, truncation |
| C4 | 1 MiB | 256 KiB, `0x40000` | Shift and truncation |

The saved disassemblies `C1_softmax.asm`, `C3_softmax.asm` and `C4_softmax.asm` show that C1/C3 need two more static instructions per row than C4:

```text
C3: lui a4, 0x50; mul a4, a5, a4; slli a4, a4, 0x20; srli a4, a4, 0x20; add s6, s6, a4
C4: slli a5, a5, 0x32; srli a5, a5, 0x20; add s5, s5, a5
```

Two extra instructions × 16 lanes × 128 rows = **4,096 instructions**, exactly matching the measured dynamic instruction difference. This explains a software component of C4's softmax advantage. It is not a claim that 4,096 instructions equal 4,096 cycles, or that all inter-config softmax cycle differences have been decomposed. This address arithmetic is separate from hardware bank selection.

## Scope

The diagnosis leaves the original candidate configs and functional RTL unchanged. The derived one-port config is an experiment artifact, not a proposed replacement for the two-port GEMM configuration. Reducing ports can change DMA/GEMM throughput, which these CPU kernels do not measure.
