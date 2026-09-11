# Independent active-parameter cross-check

Scope: the exact TH16/MXU16/WLOAD4 comparison config scripts, without `GEMM_SLR_PIPELINE`. This is a source cross-check, not another measurement.

| Capacity or option | Naive | Improve | Interpretation |
| --- | --- | --- | --- |
| Input response slots | 16, hardcoded at `VX_naive_input_executor.sv:68` | 8 through `VX_tmem_subsystem.sv:898` | Active tunable-capacity asymmetry favoring naive; 32-byte logical beats in both |
| Weight response slots after this change | 8 through production node override | 8 | Equal logical response capacity |
| Input/Weight/Scale/Zero command retention | 4 | 2 | Active capacity asymmetry; naive qparam DMA `COMMANDS=4`, weight queue `CMD_FIFO_DEPTH=4`; improve `LDMA_CMD_FIFO_DEPTH=2` |
| Scale/Zero response slots | 8 each, executor uses DMA defaults | 8 each through subsystem | Equal despite naive generic outstanding macro evaluating to 16 |
| Shared compute post transaction queue | 4 | 4 | Equal (`VX_gemm_compute_core.sv:115`) |
| Shared compute INT2FP result FIFO | 2 | 2 | Equal (`VX_gemm_compute_core.sv:105`) |
| Shared compute merged result FIFO | 6 | 6 | Equal for no-SLR MXU16 (`VX_gemm_compute_core.sv:95`) |

The naive node's legacy Input/Scale/Zero outstanding parameters do not determine those engines' actual response capacity. Likewise, several legacy prefetch-depth parameters are unused. Config macro equality alone is insufficient; the active instantiation must be traced.

## Weight queue flags: apparent difference is inactive

`VX_lmem_dma_misal.sv:2158` enables early slot release, response bypass, and same-cycle recycle only under `GEMM_SLR_PIPELINE`. That define is absent from this comparison. The active improve branch sets recycle to zero and inherits zero for early release and bypass, matching the naive gather queue. These are not additional active asymmetries.

The raw `SINK_PIPELINE` setting is zero in naive and one in improve, but both use response RAM. The shared queue derives `USE_SINK_STAGE = SINK_PIPELINE || RESPONSE_DATA_RAM`, making its effective stage enabled in both. Do not count this raw parameter difference as a pipeline advantage.

## Timing and structural qualifications

`GEMM_TIMING_CUTS` is enabled only in improve's config, but its consumers are improve controller/node logic. The common compute pipeline does not use these flags. Simply setting the macro in naive would not reproduce the controller registration behavior.

Naive Input and Scale/Zero additionally have per-lane response FIFOs, respectively depth 8 and 4, in `VX_naive_qparam_dma`. Their role is assembling fragmented LMEM lane responses. They are transport buffers, not extra logical response slots, and cannot be compared one-for-one with an improve native TMEM beat queue.

No additional RTL or parameter changes were made by this cross-check.
