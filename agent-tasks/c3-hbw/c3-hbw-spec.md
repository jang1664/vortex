# C3_HBW: Decouple DMA/LMEM Bandwidth from CPU Threads

Status: verified
Date: 2026-07-18

## Goal

Add a C3_HBW configuration that keeps the C3/C4 CPU shape at 16 threads and
16 LSU lanes while matching the C4 raw HBM DMA width of 512 bytes/cycle.

The target paths are:

1. Cache/HBM to shared LMEM through the general DMA: 8 cache lines per cycle,
   or 8 x 64 bytes = 512 bytes/cycle peak.
2. Shared LMEM fabric: 64 word ports/banks, or 64 x 8 bytes = 512 bytes/cycle
   peak.
3. Shared LMEM to the naive GEMM engine: retain the four existing independent
   64-byte tensor clients, for the same 256 bytes/cycle aggregate client width
   as the C4 GEMM-side DMA topology.

## Constraints

- Do not rename existing configuration macros.
- Add new macros only where an independent physical width is required.
- New macros must default to the existing derived width so all configurations
  other than C3_HBW retain their current elaborated topology.
- Keep `NUM_THREADS=16` and the default `NUM_LSU_LANES=16` in C3_HBW.
- Do not modify unrelated dirty PyTorch or regression-test files.
- Do not add direction-specific generate branches to the common DMA core.

## Design Decisions

### Independent LMEM ports

Add `LMEM_NUM_PORTS`, defaulting to `NUM_LSU_LANES`. The CPU LSU adapter still
creates `NUM_LSU_LANES` clients. The general DMA and naive GEMM interfaces use
`LMEM_NUM_PORTS`; CPU inputs above `NUM_LSU_LANES-1` are tied off at the
per-port arbiter.

C3_HBW sets:

- `LMEM_NUM_PORTS=64`
- `LMEM_NUM_BANKS=64`

### Independent DMA cache ports

Add `DMA_DCACHE_PORTS`, defaulting to 1. Keep `DCACHE_NUM_REQS` as the number of
CPU-generated cache requests. Add the package local parameter
`DCACHE_CORE_NUM_REQS=max(DCACHE_NUM_REQS, DMA_DCACHE_PORTS)` for the physical
core-to-cache interface.

The general DMA operates on one aggregate beat of
`DMA_DCACHE_PORTS * DCACHE_WORD_SIZE`. `VX_mem_bus_split` scatters that beat to
independent cache-line ports. A per-port arbiter combines the CPU request, when
present, with the corresponding DMA request.

C3_HBW sets:

- `DMA_DCACHE_PORTS=8`
- `DCACHE_NUM_BANKS=8`
- `L1_MEM_PORTS=8`

The existing L2 derivation then produces eight L1 inputs, eight L2 banks, and
eight memory ports for the single-socket/single-core configuration.

### Compatibility boundary

`DCACHE_NUM_REQS`, `NUM_LSU_LANES`, `LMEM_NUM_BANKS`, `L1_MEM_PORTS`, and all
other existing macro names retain their meaning. Only the new C3_HBW config
overrides the new macros. Existing C3 and C4 config files are not changed.

## Affected RTL

- `hw/rtl/VX_config.vh`: new macro defaults.
- `hw/rtl/VX_gpu_pkg.sv`: physical dcache request count and tag widths.
- `hw/rtl/core/VX_core.sv`: wider DMA and LMEM interfaces.
- `hw/rtl/core/VX_mem_unit.sv`: physical LMEM ports, DMA cache-line splitter,
  and per-port CPU/DMA arbitration.
- `hw/rtl/core/VX_dma_node.sv`: aggregate cache and LMEM beat widths.
- `hw/rtl/core/gemm/VX_gemm_node_naive.sv`: physical LMEM port mapping.
- `hw/rtl/VX_socket.sv`: physical core-to-dcache request count.
- `hw/rtl/core/VX_core_top.sv` and `hw/rtl/core/VX_mem_unit_top.sv`: wrapper
  port dimensions for width-override elaboration.
- `configs/naive_gemm_th16_tcol32_hwexp_dcache_hbw.sh`: C3_HBW definition.

## Verification Contract

1. Compile/elaborate the focused DMA and core RTL with default C3 values.
2. Compile/elaborate with the C3_HBW overrides and confirm:
   - 16 CPU LSU lanes,
   - 64 LMEM ports/banks,
   - eight physical dcache ports,
   - 512-byte aggregate general-DMA beats.
3. Run `xrt-vcs-sim` for C3_HBW:
   - app: `fpint_gemm_ffn_hw_naive`
   - args: `-m 128 -k 128 -n 128`
4. Run `xrt-vcs-sim` for C4:
   - config: `configs/improve_th16_tcol32_hwexp_dcache.sh`
   - app: `fpint_gemm_ffn_hw_naive`
   - args: `-m 128 -k 128 -n 128`
5. Run an existing-C3 compile or simulation regression to prove the default
   macro path remains compatible.

## Acceptance Criteria

- Both requested blackbox workloads pass bit-exact checking.
- C3_HBW uses 16 threads/LSU lanes and has a 512-byte/cycle raw general-DMA and
  shared-LMEM fabric width.
- Existing C3/C4 config files and existing macro names are unchanged.
- No unrelated working-tree file is modified.

## Verification Results

All configurations were force-recompiled before the wrapper run because the
`simv` build target does not track a changed `CONFIGS` value as an input.

| Configuration | Threads | DMA cache / LMEM fabric peak | Result | Cycles |
| --- | ---: | ---: | --- | ---: |
| Legacy C3 | 16 | 64 / 128 B/cycle | PASS | 20,777 |
| C3_HBW | 16 | 512 / 512 B/cycle | PASS | 23,383 |
| C4 | 16 | 512 B/cycle target topology | PASS | 12,137 |

These cycle counts do not establish end-to-end performance equivalence.
C3_HBW widens the general DMA and shared LMEM fabric, while C4 still has its
own eight-channel GEMM DMA/engine topology. The naive GEMM clients remain four
independent 64-byte paths (256 B/cycle aggregate), and `VX_mem_bus_split`
retires an aggregate beat only after every participating lane completes.

## Follow-up: Efficient Partial Wide Beats

Status: verified

The first C3_HBW performance run showed that widening each general-DMA beat to
512 bytes increased the physical traffic for row-oriented descriptors. The
follow-up implementation applies two complementary optimizations:

1. Coalesce dimension-0 segments into one descriptor segment when source and
   destination strides both equal `seg_size`, padding is zero, dimensions 1/2
   are singleton, and the combined size fits 32 bits. This preserves the DMA
   descriptor semantics while avoiding a separate 512-byte alignment window
   for every contiguous row.
2. Add an opt-in active-lane mode to `VX_mem_bus_split`. The common DMA marks
   the valid byte range of read requests in the existing `byteen` field; writes
   already carry byte enables. The masked splitter sends requests only to lanes
   containing at least one enabled byte and keeps an eight-entry response-mask
   context queue so a read response waits only for participating lanes.

The new splitter mode is enabled only on the general DMA cache and LMEM split
paths. Existing GEMM splitters retain the legacy all-lane behavior by default.

### Follow-up verification results

Both configurations were force-recompiled before their `xrt-vcs-sim` runs.
The workload is `fpint_gemm_ffn_hw_naive -m 128 -k 128 -n 128`.

| Configuration | Result | Cycles | DMA active cycles | Read / write bytes | Destination-write stall |
| --- | --- | ---: | ---: | ---: | ---: |
| Legacy C3, optimized RTL | PASS | 20,728 | 6,223 | 43,008 / 32,768 | 2,113 |
| C3_HBW, before follow-up | PASS | 23,266 | 8,787 | 135,168 / 65,536 | 4,910 |
| C3_HBW, optimized RTL | PASS | 18,055 | 3,264 | 43,008 / 32,768 | 2,296 |

Relative to the PERF-enabled pre-follow-up C3_HBW profile, the optimized result
is 5,211 cycles (22.4%) faster. It is also 2,673 cycles (12.9%) faster than the
optimized legacy C3 result. The descriptor coalescing removes the repeated wide-beat
alignment windows, reducing counted read traffic by 68.2% and write traffic by
50.0%. The masked splitter prevents any remaining disabled lanes from becoming
physical cache or LMEM transactions.

The memory-performance counters support the same explanation. Compared with
the pre-follow-up C3_HBW profile, physical LMEM reads/writes fell from
25,856/20,992 to 21,760/9,472, while dcache reads/writes fell from 2,563/1,460
to 1,123/948. The 32 x 32 x 32 C3_HBW workload also passes bit-exact checking,
and the common DMA unit regressions pass all 2,125 misaligned cases plus the
aligned-DMA suite.
