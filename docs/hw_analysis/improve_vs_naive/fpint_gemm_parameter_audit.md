# FPINT GEMM parameter fairness audit

The production naive weight response queue now has eight slots, matching improve for TH16/MXU16/WLOAD4. Other capacity asymmetries remain, but the directly comparable ones found in this audit favor naive: its Input response queue and local DMA command queues are larger. Some apparent configuration differences are inactive settings; others describe different memory architectures and cannot be equated by copying a number.

## Scope and method

This audit uses the exact existing comparison configurations:

- Naive: `configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh`.
- Improve: `agent-tasks/fpint-gemm-latency-compare/improve.sh`, which sources the TH16/MXU16 improve config and adds the matching four-bank D-cache/two-port settings.
- M4/M256, K=N512, QCOL, WTRANS0, WLOAD4, no `GEMM_SLR_PIPELINE`.
- Default naive PSUM read/data and physical response capacities remain 16; prior 32/64 captures used explicit experimental overrides.

Macro expansion was checked with Verilator preprocessing only. Each relevant value was then traced through the instantiated RTL: declaration defaults are insufficient when a parent overrides them or a migrated executor no longer uses them. No synthesis was used and improve was not changed.

## Directly comparable capacities

| Resource | Naive, effective | Improve, effective | Assessment |
|---|---:|---:|---|
| Weight response slots | **8 x 32 B** | **8 x 32 B** | Matched by this change; previously naive 4 |
| Input response slots | **16 x 32 B** | **8 x 32 B** | Naive has twice the logical response payload capacity |
| Scale response slots | 8 x 32 B | 8 x 32 B | Matched |
| Zero-point response slots | 8 x 32 B | 8 x 32 B | Matched |
| Local Input/Weight/Scale/Zero command storage, per executor | **4 commands** | **2 commands** | Naive has more command lookahead capacity |
| Controller ordinary-child command queue | 4 | 4 | Matched; distinct from local DMA command storage |
| Controller external-DMA child command queue | 8 | 8 | Matched; does not imply equal execution concurrency |
| Input packet contexts | 4 | 4 | Matched |
| Common merged-result FIFO | 6 | 6 | Matched |
| Common INT2FP-result FIFO | 2 | 2 | Matched |
| Common postprocessing transaction queue | 4 | 4 | Matched |

Payload figures exclude command metadata, lane assembly/FIFOs, and output stages. Equal response-slot capacity does not imply equal total storage or transport latency. A capacity advantage also does not prove a cycle advantage without measurement.

### Weight change

[VX_config.vh:1325](../../../hw/rtl/VX_config.vh:1325) now makes the naive default `W_LMEM_DMA_RD_OUTSTANDING_SLOTS` follow `W_LMEM_DMA_RESPONSE_SLOTS`. Under this configuration that is `2 * (16 / 4) = 8`. The existing `ifndef` preserves explicit outstanding-slot overrides; explicit node parameter overrides remain supported.

The production path is [node `W_RD_OUTSTANDING`](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:39), [weight executor instantiation](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:293), [gather `RD_PREFETCH_DEPTH`](../../../hw/rtl/core/gemm/VX_naive_weight_executor.sv:77), and [stream queue `RESPONSE_SLOTS`](../../../hw/rtl/core/gemm/VX_lmem_weight_gather_dma.sv:278).

Improve already selects [the response-capacity macro](../../../hw/rtl/mem/VX_tmem_subsystem.sv:49). Its legacy `W_LMEM_DMA_RD_OUTSTANDING_SLOTS` macro still expands to 4, but **that macro does not size its production weight queue**. The standalone naive weight executor also retains a four-slot declaration default; the production node explicitly overrides it with 8. This change matches the present comparison, not every possible external override or MXU geometry.

### Input and local command capacities

Naive [hard-codes 16 Input slots and an eight-entry per-lane response FIFO](../../../hw/rtl/core/gemm/VX_naive_input_executor.sv:68). Improve passes [the configured outstanding count and command depth](../../../hw/rtl/mem/VX_tmem_subsystem.sv:888), which expand to 8 and 2. Both logical Input responses are 32 bytes in this configuration.

Naive Input and S/Z reuse [a four-command descriptor array](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv:57). Its weight executor explicitly selects [a four-command gather queue](../../../hw/rtl/core/gemm/VX_naive_weight_executor.sv:79). Improve local executors use `LMEM_DMA_CMD_FIFO_DEPTH=2`. Thus copying queue depths is not currently needed to remove an improve capacity advantage in these resources.

The controller queues are separate: [naive uses 4/8](../../../hw/rtl/core/gemm/VX_gemm_ctrl_naive_meta.sv:184), matching [improve ordinary/DMA child depths 4/8](../../../hw/rtl/core/gemm/VX_gemm_ctrl.sv:7).

## Misleading or disconnected settings

1. **Naive `I_RD_OUTSTANDING`, `SZ_RD_OUTSTANDING`, and `O_RD_OUTSTANDING` node parameters are not connected to the migrated executors.** They appear only in the node parameter declarations. The four `*_RD_PREFETCH_DEPTH` declarations are also unused there. Changing their macros alone can silently leave production behavior unchanged.
2. **Naive S/Z slots are 8, despite the generic outstanding macro expanding to 16.** [The S/Z executor](../../../hw/rtl/core/gemm/VX_naive_qparam_executor.sv:80) instantiates the DMA without a response-capacity override, so [its default 8 applies](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv:12). Each engine has its own eight slots and four-entry per-lane response FIFO.
3. **`SINK_PIPELINE=0` versus 1 does not add a weight drain stage in this comparison.** Both weight paths use response RAM, and [the shared queue computes `USE_SINK_STAGE = SINK_PIPELINE || RESPONSE_DATA_RAM`](../../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv:82). It is 1 for both.
4. **Weight early release and same-cycle recycle are matched in the active no-SLR case.** Both have `EARLY_SLOT_RELEASE=0`, `RESPONSE_STAGE_BYPASS=0`, and `SAME_CYCLE_SLOT_RECYCLE=0`. The improve settings that enable these features are inside [the SLR-only branch](../../../hw/rtl/core/gemm/VX_lmem_dma_misal.sv:2154), which this comparison does not select.
5. **`GEMM_TIMING_CUTS` is 0 in naive and 1 in improve, but it is not a common compute-pipeline depth switch.** The improve controller uses these flags for dependency visibility, consume counters, capacity checks, and DMA launch buffering. The naive controller does not reference them; it directly checks [registered `sync_q` values](../../../hw/rtl/core/gemm/VX_gemm_ctrl_naive_meta.sv:203). Merely setting the naive macro to 1 would not reproduce improve's controller implementation. This requires semantic RTL review, not numerical parameter matching.
6. **Legacy platform aliases do not imply unequal external port counts.** Both active wrappers use `NUM_HBM_PORTS=8`. Naive's explicit `PLATFORM_MEMORY_NUM_PORTS=8` is only consistency-checked in [Vortex_axi](../../../hw/rtl/Vortex_axi.sv:175). `PLATFORM_MERGED_MEMORY_INTERFACE` has no active reference in the current RTL. Both use 32 modeled HBM banks and the same interleave setting.

Disconnected capacity parameters should be wired to the actual executor or removed in a separate cleanup. Any wiring change needs the executor's current supported-capacity, tag-width, and occupancy-width constraints checked. For example, the S/Z executor currently declares a four-bit slot-occupancy wire, sufficient for eight slots but too narrow to represent a count of 16; connecting a 16-slot override also requires that width to grow. Such wiring changes are not part of this weight-only change.

## Architectural differences that still affect the comparison

| Resource | Naive | Improve | Why equal numbers are insufficient |
|---|---|---|---|
| External DMA read concurrency | One CPU DMA engine with 16 read slots | Eight HBM DMA engines with 8 slots each | Different engine count and paths; up to 64 engine-local slots on improve, not 8 total |
| Accelerator operand memory | Shared LMEM, 16 banks x 8-byte words | TMEM, 16 banks x 32-byte words | Equal bank counts do not equal equal physical width or achievable bandwidth |
| Operand memory capacity | 1 MiB shared LMEM | 512 KiB dedicated TMEM, plus separate core LMEM | Allocation and sharing differ; these are not equivalent capacity pools |
| PSUM | LMEM adapter, 16 read/data slots, 16 physical response slots, 64 transaction entries | Dedicated internal accumulator RAM | Same accumulator-related macro values do not make the paths equivalent |
| Memory scheduling | LMEM arbitration and conservative PSUM bank-set ordering | TMEM resource scheduler with urgency enabled | Copying TMEM scheduler flags to naive does not add that hardware |
| External command launch | Descriptor programming and polling through CPU DMA interface | Direct multichannel DMA launch transport | Equal controller queue depth does not match launch latency or concurrency |

External engine topology is visible in [naive's CPU DMA node](../../../hw/rtl/core/VX_core.sv:317) and [improve's per-channel DMA units](../../../hw/rtl/mem/VX_dma_engine.sv:136). Improve's accelerator word width is [the 32-byte GEMM Input width](../../../hw/rtl/core/gemm/VX_gemm_node.sv:79); LMEM's word width is [XLEN/8 = 8 bytes](../../../hw/rtl/mem/VX_local_mem.sv:30).

These differences belong in an architectural LMEM-versus-TMEM comparison. A claim about layout alone, with equal memory resources and control behavior, would require a more tightly controlled experiment. In particular, the previously measured [PSUM bank-set ordering delay](fpint_gemm_post_prefetch_bandwidth.md) is a control restriction in addition to memory bandwidth.

## Matched compute settings

Both configurations select TH16, one core, MXU16x16, column tile16, WLOAD4, FP16 Input/INT4 Weight, identical arithmetic pipeline macros, and no SLR pipeline. They instantiate the same compute core with input scale delay 1, prealign delay 3, MXU output delay 5, merged-result depth 6, INT2FP-result depth 2, and postprocessing depth 4. See [common pipeline constants](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:45).

Both also use a 32 KiB instruction cache, 32 KiB data cache, four D-cache banks, two L1 memory ports, and 64-byte memory blocks. Naive's macro tile sizes are 128/128/128; improve's runtime-configurable geometry defaults to [the same 128/128/128](../../../hw/rtl/core/gemm/VX_gemm_fsm.sv:332), used by these runs. The absence of naive-only geometry macros from improve preprocessing is not a tile-size mismatch.

## Evidence and follow-up

The source/config probes and implementation checks are under `agent-tasks/naive-weight8-parameter-audit/`; generated evidence stays in ignored `runs/`. The guarded config edit leaves the complete selected improve config and macro definitions identical to HEAD with PERF both off and on. Current cycles belong in [the cycle comparison](fpint_gemm_latency.md); validation logs belong in the task directory.

The weight response mismatch is fixed. The next parameter cleanup is to make naive's Input/S/Z capacity settings accurately control the instantiated hardware. Reducing naive's larger Input or command queues merely to match improve would be a separate controlled baseline experiment, not an assumed optimization. Structural PSUM ordering and DMA topology require RTL design changes beyond parameter matching. No other capacities were changed in this task.
