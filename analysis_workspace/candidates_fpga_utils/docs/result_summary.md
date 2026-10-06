# Why equal SRAM capacity produces different BRAM usage in C1–C4

Analysis date: 2026-10-05. Input: [results/summary.md](../results/summary.md), generated at `2026-10-05T02:07:24+09:00`.

All four candidates have **2,624 KiB (2.5625 MiB) of configured main data SRAM**, but this does not fix their FPGA BRAM cost. The difference is explained by two measured effects:

- C2/C3's 1.25 MiB LMEM occupies **384 BRAM36-equivalent tiles**, exactly as many as C1's 1.5 MiB LMEM. Its byte-write mapping leaves unused depth in the last BRAM of each byte slice. Adding a separate accumulator therefore adds 58 tiles without reducing LMEM tiles.
- GEMM adds DMA, command, inflight, and response buffers that are excluded from the main data SRAM capacity budget. They account for another **140 tiles in C2/C3** and **114 tiles in C4**, relative to the corresponding common core logic.

These effects account for the entire reported BRAM difference. C2 versus C1 is `+58 + 140 = +198` tiles. C4 versus C3 is `-64 - 26 = -90` tiles. The common caches, FPGA shell, and URAM placement do not explain the differences.

## 1. Scope and measurement conventions

The candidate selection is [candidate_fpga_bins.yaml](../candidate_fpga_bins.yaml), resolved through [ci/fpga_bin_alias_map.yaml](../../../ci/fpga_bin_alias_map.yaml). Each candidate's archived `manifest.json` and preprocessed `src/` snapshot determine the capacity calculation; current defaults alone are insufficient.

| Candidate | Implementation | Archived build directory under `/opt/vortex_fpga_bins/fpint/` |
| --- | --- | --- |
| C1 | SIMT + TCU | `xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_aeaa53da67_2` |
| C2 | SIMT + TCU + naive GEMM | `xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_0b1936f552_2` |
| C3 | SIMT + naive GEMM | `xrt_hw_u55c_c1_f100_fpint_L2cache_c0e620ccc8_2` |
| C4 | SIMT + improve GEMM | `xrt_hw_u55c_c1_f100_fpint_L2cache_9299cac673_2` |

All use one cluster, one core, 16 threads, the `xcu55c-fsvh2892-2L-e` device, Vivado 2025.1, and a configured clock of 100 MHz. Percentages quoted here use full-device capacity; raw hierarchy percentages can use partition capacity and are ignored. BRAM means `RAMB36 + RAMB18 / 2`, with 2,016 tiles available. All candidates use zero URAM.

The summary labels breakdown reports `pre_opt` because [util_reports.py](../util_reports.py) assigns that label to `hier_utilization.rpt`. However, all four actual report headers say **`Design State: Physopt postRoute`**. Consequently, `pre_opt` is a filename-selection label here, not evidence that these reports describe a pre-optimization design.

The hierarchy reports' full-design BRAM counts are exactly one RAMB36 higher than the final routed reports for every candidate; RAMB18 counts are unchanged. The removed instance is not identified by these utilization tables. Hierarchy counts below are kept separate from final routed totals. Because the offset is identical, their candidate-to-candidate BRAM deltas agree exactly.

## 2. Equal logical capacity, different distribution

The capacity budget includes cache **data**, LMEM, TMEM, and accumulator data. It excludes cache tags/MSHRs, register files, controller queues, and DMA buffers. KiB means 1,024 bytes.

| Main data SRAM, KiB | C1 | C2 | C3 | C4 |
| --- | ---: | ---: | ---: | ---: |
| I-cache | 32 | 32 | 32 | 32 |
| D-cache | 32 | 32 | 32 | 32 |
| L2 data | 1,024 | 1,024 | 1,024 | 1,024 |
| LMEM | 1,536 | 1,280 | 1,280 | 1,024 |
| TMEM | 0 | 0 | 0 | 256 |
| Accumulator | 0 | 256 | 256 | 256 |
| **Total** | **2,624** | **2,624** | **2,624** | **2,624** |

The archived elaborated parameters establish these values:

- C1: `VX_mem_unit.sv` instantiates LMEM with `.SIZE(1572864)`.
- C2/C3: the same instance has `.SIZE(1310720)`. `LMEM_LOG_SIZE=21` supplies the ceiling address width; it does **not** override the explicit size to 2 MiB.
- C4: LMEM has `.SIZE(1 << 20)`. The active TMEM subsystem has eight banks of 32,768 bytes, totaling 256 KiB.
- C2–C4: the active accumulator contains four banks, each `1024 × (16 × 32)` bits, totaling 256 KiB. C1 has no active GEMM accumulator; an unused module file in its snapshot is not an instantiated memory.
- All candidates instantiate 32 KiB I/D caches and a 1 MiB L2.

The capacity table in `backup.v1/results/SRAM_CAPACITY.md` concerns older aliases and different configurations. Its cache-bank and capacity differences must not be carried over to these candidates.

## 3. Exact BRAM accounting

The following rows are disjoint subtrees or disjoint groups of subtrees from each archived `bin/hier_utilization.rpt`. Parent and child totals are not added together.

| BRAM location, BRAM36-equivalent tiles | C1 | C2 | C3 | C4 |
| --- | ---: | ---: | ---: | ---: |
| I-cache subtree | 35.5 | 35.5 | 35.5 | 35.5 |
| D-cache subtree | 118 | 118 | 118 | 118 |
| L2 subtree | 314 | 314 | 314 | 314 |
| LMEM | 384 | 384 | 384 | 256 |
| TMEM physical banks | 0 | 0 | 0 | 64 |
| Accumulator / MXU BRAM | 0 | 58 | 58 | 58 |
| Common SIMT excluding TCU and `u_VX_dma_node` | 82 | 82 | 82 | 82 |
| TCU | 1 | 1 | 0 | 0 |
| `u_VX_dma_node` (classified as SIMT) | 0 | 36 | 36 | 0 |
| GEMM DMA category | 0 | 32 | 32 | 52 |
| GEMM controller | 0 | 57 | 57 | 58 |
| DMA-to-D-cache split/reorder adapter | 0 | 15 | 15 | 0 |
| TMEM weight switch | 0 | 0 | 0 | 4 |
| Common Misc: AXI adapter + memory coalescer | 3 | 3 | 3 | 3 |
| **Total Vortex_axi** | **937.5** | **1,135.5** | **1,134.5** | **1,044.5** |
| Outside Vortex_axi, same hierarchy report | 200 | 200 | 200 | 200 |
| Full FPGA, hierarchy report | 1,137.5 | 1,335.5 | 1,334.5 | 1,244.5 |
| **Full FPGA, final routed report** | **1,136.5** | **1,334.5** | **1,333.5** | **1,243.5** |
| **Final routed utilization** | **56.37%** | **66.20%** | **66.15%** | **61.68%** |

Cache rows include metadata and queues, so their tile counts cannot be converted directly into cache data bytes. The common SIMT 82 tiles are `issue=76`, `schedule=2.5`, `fpu_unit=1.5`, and `lsu_unit=2`. Other selected SIMT subtrees consume zero BRAM.

## 4. Cause A: naive LMEM loses the intended capacity saving at BRAM granularity

LMEM uses 16 banks, 64-bit words, and eight independent byte write enables. The RTL computes `WORDS_PER_BANK = SIZE / 8 / 16` and instantiates `VX_sp_ram` with `.WRENW(8)`, `.OUT_REG(1)`, and `.USE_URAM(0)`.

| LMEM geometry | C1 | C2/C3 | C4 |
| --- | ---: | ---: | ---: |
| Logical bytes per bank | 96 KiB | 80 KiB | 64 KiB |
| 64-bit words per bank | 12,288 | 10,240 | 8,192 |
| Bank address bits | 14 | 14 | 13 |
| Observed depth blocks per byte slice | 3 | 3 | 2 |
| BRAM36 per bank | 24 | 24 | 16 |
| **LMEM BRAM36 total** | **384** | **384** | **256** |

The archived synthesis log provides the mechanism, rather than just a correlation:

- `Synth 8-6841` reports that LMEM's byte-wide write RAM is implemented with a single write enable per RAM, because the address width exceeds Vivado's threshold of 12. This warning appears in all four builds; it is not unique to naive.
- For C2/C3, `Synth 8-5800` reports a cascade height reduction from four to three because the memory depth is not a power of two. The log also names eight byte slices, `ram_reg_0_bram_2` through `ram_reg_7_bram_2`, in an LMEM bank.
- The utilization report gives 24 RAMB36 and zero RAMB18 for retained C2/C3 `lmem_store` bank subtrees, and 384 tiles for the whole LMEM.

Together with the RAMB36 `4096 × 9` organization, these observations explain the selected mapping as eight byte slices with `ceil(words_per_bank / 4096)` full depth blocks per slice. The legal primitive geometry and parity organization are documented in [AMD UG573, Block RAM Summary](https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/Block-RAM-Summary). This is an explanation of the observed mapping, not a lower bound on every possible implementation.

For C2/C3, the last block in each slice has only 2,048 of its 4,096 byte positions in the logical memory. Thus the mapping leaves `16 banks × 8 slices × 2048 bytes = 256 KiB` of data-position capacity unused, equivalent to **64 tiles**. Parity bits are additional and are not included in that padding calculation.

The intended change from C1 to C2/C3 removes 256 KiB of LMEM and adds 256 KiB of accumulator. However, LMEM remains at 384 tiles, while the accumulator adds **58**. Its four `1024 × 512-bit` RAMs have one write enable per word and pack differently: each costs 14 RAMB36 plus one RAMB18, or 14.5 tiles. Equal logical byte counts therefore do not imply equal primitive counts.

C4 instead uses a 1 MiB LMEM costing 256 tiles, plus eight 32 KiB TMEM banks costing eight tiles each. With the same 58-tile accumulator, its LMEM/TMEM/ACC total is `256 + 64 + 58 = 378`, versus C3's `384 + 58 = 442`: **64 fewer tiles**. The caches are identical in measured BRAM usage.

## 5. Cause B: capacity accounting excludes substantial transport and control RAM

C2/C3 add the following buffers beyond their accumulator:

- **36 tiles in `u_VX_dma_node`**, included in the summary's SIMT category. Its LMEM lane splitter/reorder response store uses 16.5 tiles; its DMA unit uses 19.5.
- **32 tiles in the GEMM DMA category**: input executor 8, qparam executor pair 16, weight executor 4, and output LMEM DMA 4.
- **57 tiles in `gemm_node_naive/control/controller`**, included in Misc: child command queues use `12 + 9 + 10 + 10 + 12 = 53`, and four inflight queues use another 4.
- **15 tiles in `mem_unit/g_split_dma_dcache_ports.dma_dcache_split`**, also included in Misc.

Their sum is `36 + 32 + 57 + 15 = 140` tiles. The SIMT increase is therefore mostly a DMA buffer cost, and the Misc increase has concrete controller/adapter owners.

For C4, the corresponding additional cost is `52 GEMM DMA + 58 controller + 4 weight switch = 114` tiles. The DMA category consists of a 32-tile TMEM DMA engine and five 4-tile local DMA units. Controller command queues use 53 tiles and inflight queues use five. C4's GEMM DMA category is 20 tiles larger than C3's, but it has no separate 36-tile `u_VX_dma_node` or 15-tile D-cache split adapter. Across these groups, C4 saves **26 tiles**.

Small logical queues can consume many tiles when they are wide and forced into BRAM. In the archived RTL, `VX_gemm_ctrl_naive_meta.sv` uses child command FIFO depths of only four or eight. `VX_fifo_queue.sv` defaults to `LUTRAM=0` and delegates storage to `VX_dp_ram.sv`; that helper explicitly selects block RAM when its `FORCE_BRAM` condition is met. Width fragmentation, rather than just payload bytes, matters for these queues. This explains why equal main data SRAM budgets do not constrain the additional 140 or 114 tiles.

## 6. Reconciliation of the reported differences

All equations use BRAM36-equivalent tiles and match both hierarchy and final routed deltas.

| Comparison | Exact explanation | Final routed difference |
| --- | --- | ---: |
| C2 − C1 | ACC `+58`, transport/control `+140`; LMEM tiles and TCU unchanged | **+198** |
| C3 − C1 | Same additions, with TCU `−1` | **+197** |
| C2 − C3 | TCU only | **+1** |
| C4 − C3 | LMEM/TMEM/ACC placement `−64`, transport/control `−26` | **−90** |
| C4 − C1 | LMEM/TMEM/ACC placement `−6`, transport/control `+114`, TCU `−1` | **+107** |

C2 is 17.42% higher than C1 in total routed BRAM count; C4 is 6.75% lower than C3. Removing the TCU in C3 changes BRAM by only one tile, although the routed DSP count falls by 512 (`1178 − 666`). The arithmetic datapath cost and SRAM/BRAM cost are different resource comparisons.

For reporting these results, describe the matched capacity as **configured main data SRAM capacity**, and report BRAM separately as measured FPGA resource cost. Multiplying tile count by 4.5 KiB gives allocated raw primitive bits, including parity and padding; it does not recover usable SRAM capacity. The dominant differences here are the measured LMEM mapping and the extra buffer subtrees, not an unexplained synthesis variation.

## 7. Evidence and verification

For each build directory in Section 1, the analysis used:

- `manifest.json`: exact build-time defines, tool/device settings, and enabled features.
- `src/VX_mem_unit.sv`, `src/VX_local_mem.sv`, `src/VX_gpu_pkg.sv`: active LMEM size, bank/word geometry, and RAM instantiation.
- `src/VX_socket.sv`, `src/VX_cluster.sv`: active cache data capacities.
- C4 `src/VX_gemm_node.sv`, `src/VX_tensor_mem_bank.sv`: active TMEM size and physical bank storage.
- C2–C4 `src/VX_gemm_acc_internal.sv`: accumulator capacity and write-enable geometry.
- C2/C3 `src/VX_gemm_ctrl_naive_meta.sv`, `src/VX_mem_bus_split.sv`, and RAM/FIFO helpers: command and response buffer implementation.
- `bin/ulp_vortex_afu_1_0_synth_1_runme.log`: LMEM mapping diagnostics `8-6841`, `8-5800`, and byte-slice instance names.
- `bin/hier_utilization.rpt`: disjoint subtree resource counts and full-design counts.
- `bin/impl_1_full_util_routed.rpt`: final full-FPGA resource counts.

Reports were read with the existing `load_candidates`, `read_report`, and `breakdown` helpers. Capacity sums, category sums, the finer subtree accounting, and every delta above were checked against the four archived reports and the input summary. No RTL changes, new synthesis, or implementation runs were needed.
