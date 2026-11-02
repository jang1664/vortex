# SRAM fusion ABI and integration contract

Status: M0 interface contract, agreed between implementation work units.

The feature is `GEMM_SRAM_FUSION`, requiring improve. The legacy GEMM descriptor remains 44 words. The C4 DMA MMIO window starts at 0x1480 and is reused only with the feature enabled.

| Offset | Register |
|---|---|
| 0x00 | Capability 0x53465202 |
| 0x04 | Status: bit 0 busy, bit 1 sticky done |
| 0x08 | Command: bit 0 start, bit 1 LMEM-to-TMEM direction |
| 0x0c | Command sequence |
| 0x10 / 0x14 | TMEM byte offset low/high |
| 0x18 / 0x1c | LMEM byte address low/high |
| 0x20 | Length in bytes |
| 0x24 | Completed sequence |
| 0x28 | Error: 0 success, 1 zero length, 2 alignment, 3 range, 4 busy submission, 5 invalid command/MMIO |
| 0x2c | Blocking publication read; returns 1 after prior accepted SIMD local stores physically commit |

Each producer warp performs the publication read after its stores and before joining. Store admission tracking starts at the LSU memory ingress before the independent local/MMIO output buffers. The implementation must prove the upstream LSU issue/posted-store ordering, not assume a controller-only fence publishes other workers.

PUBLISH request acceptance may precede store commitment; only its response
establishes publication. The controller retains one pending response in existing
mask/tag/data registers and blocks overwrite until release. Other fields in a
mixed PUBLISH/metadata read are acceptance-time snapshots; software must issue a
subsequent read for post-publication metadata. Request-ready must not depend
combinationally on publication, which includes current-cycle LSU admissions.

Per-entry extension: offset `0x100 + 16 * entry`.

| Offset in entry | Meaning |
|---|---|
| +0 | Flags: bit 0 resident A, bit 1 resident output, bit 2 FP32 output (requires bit 1); write last to arm |
| +4 | Expected allocation generation |
| +8 | Status: bit 0 armed, bit 1 working, bit 2 done, bit 3 error; error code in bits 31:16 |
| +12 | Completed generation |

Resident error codes: 0 success, 1 invalid resident shape, 2 stale/rejected extension. A rejected job emits no child work and retires with error. Extension metadata is matched against the actual allocation generation and consumed at issue; stale state is cleared on reallocation. Done status remains readable after normal retirement until subsequent reuse/reset.

After writing the extension generation and flags, software reads the armed status and expected generation back through the same sidecar MMIO window before publishing GEMM CONTROL. The two windows have independent buffered routes; posted writes alone do not establish this ordering. Flags zero disarm the extension and do not request a resident completion event.

GEMM controller extension ports: `resident_flags_i[2:0]`, `resident_reject_i`, `bridge_busy_i`; outputs `resident_quiescent_o`, `resident_done_o`, `resident_done_entry_id_o[31:0]`, `resident_error_o[31:0]`. Quiescence includes no active invocation or pending retirement, FSM idle, and scheduler/child drain. Bridge ownership additionally covers downstream reservations and crossings.

`VX_sram_dma` command uses valid/ready, direction, 64-bit TMEM and LMEM byte addresses, 32-bit length/sequence; outputs busy, one-cycle done, retained done sequence and 3-bit error. It has one outstanding transaction. LMEM writes wait for `lmem_write_commit_i`; TMEM writes consume normal bus acknowledgements. Route ownership is retained until busy deasserts after the completion pulse.

Readiness audit: the current GEMM tile input load does not increment a per-load completion counter. The final zero-point load SETs the tile marker. Resident A skips the A load while preserving that final producer marker and consumer wait contract.

Optional FP32 output layout, capacity, and numerical requirements are specified in `fp32-export-contract.md`. The format signal remains stable for the invocation; both 32-byte halves must physically commit before resident completion.
