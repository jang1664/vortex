# GEMM_NAIVE External PSUM Memory Plan

## Goal

When building with `GEMM_NAIVE`, stop using the `gemm_unit` internal ACC
Memory and store partial sums in the external local memory. When building with
`GEMM_IMPROVE`, preserve the current internal ACC Memory behavior.

The only arbitration rule required for this change is:

> If a local-memory bank conflict includes a GEMM PSUM request, the PSUM
> request must be selected before every ordinary local-memory request.

The `gemm_unit` has no PSUM back-pressure protocol. Therefore the memory system
must accept and service PSUM requests according to this fixed-priority rule.

## Requirements

### R1. Preserve the two GEMM implementations

- `GEMM_IMPROVE`
  - Keep the existing internal ACC Memory.
  - Keep its current accumulator read/write FSM and memory timing.
  - Do not route improve-mode PSUM traffic through local memory.

- `GEMM_NAIVE`
  - Do not instantiate or use the internal ACC Memory for PSUM storage.
  - Use the external local-memory path for PSUM reads and writes.
  - Preserve the existing GEMM accumulator operation and address progression.

### R2. Give PSUM requests fixed priority

PSUM priority must hold at both arbitration levels:

1. Between GEMM PSUM traffic and other requests entering the same physical
   local-memory lane.
2. Between requests from different physical lanes that target the same local
   memory bank.

The second level is essential. Giving PSUM priority only inside
`VX_mem_unit` is insufficient because the local-memory bank crossbar can still
select an ordinary request from another lane.

### R3. Do not add GEMM-unit back-pressure behavior

This change must not add a new PSUM retry, stall, or hazard-management protocol
to `VX_gemm_unit`.

The memory system owns the arbitration change. If the existing request timing
cannot be supported by the local-memory path, fix the memory system rather than
changing the GEMM-unit scheduling contract.

## Current Relevant Path

The configured build is:

`configs/naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16.sh`

It enables:

```text
NUM_THREADS=32
LMEM_LOG_SIZE=20
stream crossbar for LMEM requests (`LMEM_REQ_OMEGA_ENABLE` disabled)
stream path for LMEM responses (`LMEM_RSP_OMEGA_ENABLE` disabled)
ENABLE_GEMM_ACCEL
GEMM_NAIVE
MXU_COL_TILE=32
GEMM_ACC_MEM_DEPTH=512
```

The relevant current RTL path is:

```text
VX_gemm_unit
  -> VX_gemm_node_naive
  -> gemm_data_if
  -> VX_mem_unit
  -> VX_local_mem
  -> local-memory bank crossbar
```

The existing `VX_mem_unit` arbitration combines CPU, DMA, and GEMM traffic,
while `VX_local_mem` performs the final request-to-bank arbitration. PSUM
priority must be visible to both stages.

## Implementation Units

### U1. Remove the naive ACC-memory-to-LMEM command first

Files:

- `hw/rtl/core/gemm/VX_gemm_fsm_naive.sv`
- `hw/rtl/core/gemm/VX_gemm_sync_naive.sv`

`GEMM_NAIVE` will no longer have an internal ACC Memory. Therefore its FSM
must not issue `OP_O_ACC2LMEM`.

Remove the naive-only command definition, command emission, notification, and
wait sequence:

```text
OP_O_ACC2LMEM
S_O_ACC2LMEM
S_O_ACC2LMEM_NTF
S_O_WAIT_ACC2LMEM_DONE
```

After the prior output-buffer reuse wait (`S_O_WAIT_LMEM2DRAM_DONE`), the FSM
must advance through the external-PSUM output flow without issuing an ACC
Memory copy command. Remove `OP_O_ACC2LMEM` from the naive sync route decode
as well, so no stale command can be routed to child 3.

This is restricted to the `_naive` FSM/sync modules. Do not change
`VX_gemm_fsm.sv` or `VX_gemm_sync.sv`, which serve the improve backend.

### U2. Allocate and program a PSUM local-memory region

Files:

- `tests/regression/fpint_gemm_ffn_hw_naive/main.cpp`
- `tests/regression/fpint_gemm_ffn_hw_naive/common.h`
- `tests/regression/fpint_gemm_ffn_hw_naive/kernel.cpp`
- `hw/rtl/core/gemm/VX_gemm_fsm_naive.sv`

The naive host currently allocates input, weight, scale, zero-point, and FP16
output buffers in local memory. It allocates no PSUM storage because the
partial sums currently reside in the internal ACC Memory.

Add one tile-local FP32 PSUM allocation:

```text
lmem_psum_bytes = DMA_MT * DMA_NT * sizeof(fp32)
```

For the current 128 x 128 DMA tile, this is 65,536 bytes. Allocate it through
the existing aligned `compute_lmem_layout()` allocator, validate that the
expanded layout fits `VX_CAPS_LOCAL_MEM_SIZE`, and add
`lmem_psum_base` to `kernel_arg_t`.

Expose the base through a new 64-bit naive descriptor field. Use the currently
reserved register pair 40/41 for `REG_LMEM_PSUM_LO/HI`; keep register 43 as
`REG_OUTPUT_PROGRESS`, so `GEMM_JOB_NUM_REGS32` remains 44. The kernel must
write this base when programming a job, and `VX_gemm_fsm_naive` must latch it
into `job_t`.

Replace the naive FSM's fixed `ACCUM_BASE` use in `lmem_out_slice` with:

```text
job_q.lmem_psum_base + n0_out * MT * FP32_BYTES
```

This preserves the current `[MT x NT]` FP32 row-major PSUM layout and lets the
existing input-arm command pass a local-memory PSUM address to the GEMM unit.

On the final accumulation, the GEMM unit must write the converted FP16 result
directly to `lmem_obuf` while it writes the FP32 PSUM result to the PSUM
region. It must not rely on a later ACC-memory copy command.

### U3. Add the GEMM_NAIVE external PSUM path

Files:

- `hw/rtl/core/gemm/VX_gemm_unit.sv`
- `hw/rtl/core/gemm/VX_gemm_node_naive.sv`
- `hw/rtl/core/VX_core.sv`

Add the `GEMM_NAIVE`-only wiring needed to carry PSUM reads and writes to
external local memory. Reuse the existing GEMM-wide/lane-width adaptation
patterns where possible.

The path must preserve the existing PSUM request fields, including address,
read/write direction, write data, byte enables, and tags. Improve mode must
remain on the current internal ACC Memory path.

This unit does not introduce new GEMM-unit back-pressure, request retry, or
PSUM hazard logic.

### U4. Prioritize PSUM within `VX_mem_unit`

File:

- `hw/rtl/core/VX_mem_unit.sv`

Separate PSUM traffic from ordinary GEMM traffic sufficiently for the local
memory arbitration to identify it as high priority.

At a physical lane conflict, the selection order must be:

```text
PSUM > ordinary GEMM / DMA / CPU
```

The existing response/tag routing must continue to work for both ordinary GEMM
requests and PSUM requests.

### U5. Propagate PSUM priority through the bank crossbar

Files:

- `hw/rtl/mem/VX_local_mem.sv`
- the local-memory arbitration module used by `VX_local_mem`, if a shared
  arbiter change is needed

Modify the bank arbitration so that a PSUM request is selected whenever it
conflicts with an ordinary request targeting the same bank.

The implementation may use either:

- a PSUM-aware priority input to the existing crossbar, or
- a dedicated PSUM-first arbitration stage before ordinary requests.

The chosen implementation must preserve existing behavior for builds without
`GEMM_NAIVE` and must not change the ordinary CPU/DMA/GEMM arbitration policy
when no PSUM request is present.

### U6. Keep configuration and compile-time behavior isolated

Use `GEMM_NAIVE` guards around the new external-PSUM wiring and priority
metadata. Confirm that the improve configuration does not require new ports,
signals, or local-memory behavior.

Do not change:

- `configs/naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16.sh`
- the meaning of `GEMM_IMPROVE`
- the internal ACC Memory implementation used by improve mode

## Verification Plan

### RTL focused checks

Add or extend focused tests for:

- `GEMM_NAIVE` PSUM read/write requests with no conflict.
- PSUM versus ordinary request targeting the same physical lane.
- PSUM versus ordinary request from another lane targeting the same bank.
- Multiple simultaneous PSUM requests targeting different banks.
- A build without `GEMM_NAIVE`, proving the improve/internal-ACC path still
  compiles and behaves as before.

The key assertion is:

```text
same-bank conflict && psum_valid && ordinary_valid
    => selected_request == psum_request
```

### Integration checks

Run the configured RTL tests and the `fpint_gemm_ffn_hw_naive` regression from
a configured build directory using `xrt-vcs-sim` and the repository wrapper:

```bash
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args "..."
```

Source the following configuration before simulation or synthesis, as required
by the repository execution notes:

```bash
source configs/naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16.sh
```

This configuration deliberately leaves both `LMEM_REQ_OMEGA_ENABLE` and
`LMEM_RSP_OMEGA_ENABLE` undefined so that LMEM requests and responses use the
stream paths. Verification must specifically confirm that this path change
removes the stale PSUM read-after-write failure. Keep the remaining
compile-time options aligned with
`naive_gemm_th32_tcol32_hwexp_dcache.sh`.

Start bring-up with smaller dimensions so that compile/simulation iterations do
not spend unnecessary time on large GEMMs. Once the focused conflict checks and
small functional runs pass, use these two cases as the final functional PASS
criteria:

```text
-m 1  -k 256 -n 256
-m 32 -k 256 -n 256
```

Both commands must complete through `fpint_gemm_ffn_hw_naive` with a passing
output comparison. The `-m 1` case provides a short initial end-to-end check;
the `-m 32` case is the required larger final check.

### Stream-xbar verification result (2026-07-28)

The request stream-xbar experiment did not remove the stale PSUM failure.
After a clean VCS rebuild with
`naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16.sh`, the diagnostic run

```text
-m 32 -k 128 -n 256
```

failed in the PSUM LMEM read-after-write scoreboard at lane 2, word address
`0x3a12`:

```text
got      0xc4cb4000c3bb8000
expected 0xc4b34000c3b18000
```

This is the same stale-data signature observed with the request OMEGA path.
Therefore disabling only `LMEM_REQ_OMEGA_ENABLE` is not sufficient. The two
final PASS cases remain required, but must not be reported as passing until the
memory-system ordering issue is resolved and both complete successfully.

### Full stream-path verification result (2026-07-28)

After also disabling `LMEM_RSP_OMEGA_ENABLE`, a clean VCS build with stream
paths for both LMEM requests and responses passed the stale diagnostic and both
final functional criteria:

```text
-m 32 -k 128 -n 256  PASSED
-m 1  -k 256 -n 256  PASSED
-m 32 -k 256 -n 256  PASSED
```

All runs completed through `fpint_gemm_ffn_hw_naive`, including host output
comparison, with no PSUM LMEM scoreboard mismatch. This supersedes the blocked
result above, which applied to request-stream/response-OMEGA mode only.

### Out of scope

- Adding back-pressure to `VX_gemm_unit`.
- Adding a new PSUM request retry protocol.
- Adding separate GEMM-unit read/write hazard handling.
- Changing GEMM computation, tiling, or accumulator scheduling.
- Performance tuning unrelated to PSUM priority.

If the existing PSUM request timing cannot be sustained, the follow-up change
belongs in the local-memory request/response system rather than in the
`gemm_unit` scheduling logic.
