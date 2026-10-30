# Improve GEMM resident I/O

Current C4 integration uses [unified GEMM MMIO](../VX_gemm_unified_mmio.md) (ABI v3). The separate fusion MMIO ABI below is historical; the internal resident GEMM flags and completion semantics remain relevant.

`GEMM_SRAM_FUSION` adds single-DMA-tile resident I/O to `VX_gemm_ctrl` and `VX_gemm_fsm`. With the define absent, the existing ports, state paths, job structure, and completion conditions remain selected.

## Controller contract

The node presents `resident_flags_i[2:0]` with the accepted configuration:

- Bit 0: activation A is already in `LMEM_IBUF0` (TMEM on improve).
- Bit 1: output remains in `LMEM_OBUF` (TMEM); no output HBM operation is issued.
- Bit 2: export the FP32 accumulator without FP16 conversion; requires bit 1. Flags 6/7 select FP32 output and 2/3 retain FP16 output.
- `resident_reject_i`: extension metadata was rejected, such as an allocation-generation mismatch. This takes precedence even when both flags are zero.

The FSM latches the flags at configuration acceptance. Existing 44-word configuration registers and output-progress semantics are unchanged. Extension metadata validation/storage belongs to the node's SRAM-fusion control block.

`bridge_busy_i` prevents configuration acceptance. `resident_quiescent_o` means the FSM and controller queues/inflight records are empty, no invocation is active, and no descriptor completion is waiting for acceptance. The node must also establish physical local-DMA/registered-crossing drain before lending its TMEM route to the bridge.

`resident_done_o` pulses on the normal descriptor completion handshake for a resident or rejected invocation. `resident_done_entry_id_o` identifies that retired entry, and `resident_error_o` is its latched error code. Completion metadata is held separately from the next active invocation:

| Error | Meaning |
|---|---|
| 0 | Successful resident invocation |
| 1 | Unsupported resident shape or resident A/output range |
| 2 | Metadata rejected by the node |

A rejected invocation emits no work commands and retires normally with its error. Flags zero without rejection retain legacy execution.

## Supported resident descriptor shape

The original and target matrices must fit in one configured DMA tile. Initial resident support is limited to dimensions at most 128; tile exponents for M are 3..7 and those for N/K are `clog2(MXU_NT/KT)`..7. Original and target K/N are MXU aligned; target dimensions are positive and no larger than original dimensions. M/N starts must be zero. Quantization-group exponents are `clog2(MXU_NT)`..7. WTRANS/QDIR are Boolean.

Resident A and output bases are physical-TMEM-word aligned and their padded tile reservations must fit TMEM. Software remains responsible for nonoverlapping live allocations and valid W/scale/zero buffers.

For short-row decode, program the physical row reservation as original M (for example 8) and the computed row count as target M (for example 1 or 4). Output TMEM microtile strides use original storage rows. Do not program original M=1 and then interpret that resident output with an 8-row padded stride.

## Input readiness

The current load helper does not increment a count for each A/W/SC/ZP operation. Only the final ZP load carries a tile-ready SET notification for the ordered load sequence. Resident A skips `S_PRE0_LD_I` and starts at W; the same ZP marker and readiness targets remain valid. No prefetch path is reachable for a valid single-tile resident descriptor, and activation storage stays in IBUF0.

## Output completion

Resident output keeps the existing GEMM writeback and ACC-copy dependency fences, but skips both output-preservation HBM reads and output HBM stores. Each output microtile copies to its caller-owned TMEM slice. Padding belongs to the caller and must be initialized if deterministic inactive bytes are required.

FP32 output retains the C microtile element order with four bytes per element.
A C4 16-column row uses two 32-byte beats, columns 0..7 followed by 8..15;
its padded microtile reservation is `align8(original_M) * 16 * 4` bytes.
The FSM validates that reservation and latches the format for the invocation.
`output_fp32_o` selects the ACC half-row read and output-copy geometry through
physical completion; a later FP16 or legacy job captures its own format.
See [the FP32 export contract](../VX_sram_fusion_ctrl.md#optional-fp32-export)
for ACC addressing and inactive-row behavior.

The terminal wait compares both `completed_acc_copy_count_i` values against issued ACC-copy counts and waits for controller quiescence. These counters come from the existing ACC_FREE completion notifications; the output local-DMA completion contract includes physical TMEM write commit and SLR drain. Zero issued HBM stores alone is not a resident completion condition.

`REG_OUTPUT_PROGRESS` still counts external output-store completions. It is not repurposed as resident tile readiness.

## Required verification

Exercise flags 0/1/2/3/6/7, M=1/4/8/16/128 with physical row reservations, both QDIR values and WTRANS layouts, sequential descriptor reuse, invalid shapes/ranges, metadata rejection with flags zero, delayed ACC-copy completion, and bridge exclusion. Check that resident output issues neither preservation loads nor stores and resident A issues no HBM A load. Confirm bytes in TMEM and legacy HBM progress independently. Invalid cases must retire with an error and zero memory traffic. Include rejection of bit 2 without bit 1, FP32 values above 65504, both half-row beats under backpressure, and FP32-to-FP16-to-legacy jobs without reset.
