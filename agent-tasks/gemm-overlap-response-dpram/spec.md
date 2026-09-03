# GEMM Overlap Response DPRAM Specification

Status: confirmed

## Goal

Move the wide response payload storage in the GEMM overlap DMA queues and the
TMEM Weight wide-read assembly switch from resettable FF arrays and variable
index muxes to optional synchronous `VX_dp_ram` storage. The change targets
lower FF/LUT use, fanout, and routing congestion while preserving functional
ordering and steady-state throughput.

## Scope

- `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv`
- overlap wrappers in `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`
- `hw/rtl/mem/VX_tmem_wide_read_switch.sv`
- `hw/rtl/mem/VX_tmem_subsystem.sv`
- default macros in `hw/rtl/VX_config.vh`
- target `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem*.sh`
- focused and existing overlap/wide-switch tests under `hw/unittest`
- GEMM-node OOC flow and xrt-vcs-sim FPINT GEMM verification

Output DMA, HBM DMA, response-slot counts, command scheduling, floorplanning,
and full XRT P&R are outside this task.

## Confirmed design decisions

1. Both modules have a compile-time `RESPONSE_DATA_RAM` parameter whose default
   is one. An explicit zero override preserves the FF implementation for A/B
   comparisons and debugging.
2. Stream queue RAM mode stores only payload in one registered-read 1R1W
   `VX_dp_ram`; control metadata remains in FF. Existing production sink stages
   launch the synchronous read and keep one-beat-per-cycle turnover.
3. Wide-switch RAM mode uses one context-addressed `VX_dp_ram` per logical
   response lane. Lane-local round-robin arbitration serializes simultaneous
   responses from physical TMEM ports that target the same logical lane.
4. The wide switch has a scalar response ownership stage. RAM registered data
   drives the output directly and is not copied into another wide FF register.
5. Contexts are freed only when the assembled response handshakes. Stalled
   output data/tag remain stable, and read/write collisions are asserted illegal.
6. Input, Weight, Scale/Zero-point queues and the Weight wide switch are
   independently selectable from `VX_tmem_subsystem`; all production parameter
   layers default to RAM mode while retaining independent explicit overrides.
7. RAM mode must preserve data, tags, ordering, fences, out-of-order response
   handling, and steady-state one logical response per cycle. The wide-switch
   initial synchronous-read fill may add at most one cycle.

## Acceptance gates

- Focused queue, wide-switch, and all overlap DMA unit regressions pass.
- FPINT GEMM xrt-vcs-sim passes for M=4/256, N=K=256, QBLK=32, QDIR=0/1,
  WTRANS=0, WLOAD=4, with no case exceeding 2% kernel-cycle regression.
- Four WLOAD4 GEMM-node OOC variants (FF/FF, RAM/FF, FF/RAM, RAM/RAM) are
  synthesized at 7.000 ns with identical non-storage settings.
- The retained production candidate has WNS >= 0, TNS = 0, no setup failing
  endpoints, reduced relevant FF/LUT usage, inferred RAMB payload storage, and
  no DSP/URAM increase.

The detailed implementation and verification matrix in `plan.md` is normative.
