# Direct core reset for C4 SRAM fusion

Status: confirmed by the user on 2026-10-26.

## Goal
Remove the added two-stage endpoint reset relays. The user permits reset to cross SLRs without extra FFs. Use the existing core reset directly for same-clock fusion logic. Preserve existing core reset generation.

## Scope
RTL: VX_gemm_node, VX_mem_unit, VX_lmem_switch, VX_mem_arb, VX_sram_bank_slice_transport, obsolete VX_sram_reset_relay and its source-list references. Physical constraints/checkers: fusion floorplan reset roots and reset crossing classification; replace the local two-FDPE structural assumption with actual source/consumer checks.

## Required behavior
Both endpoints receive the common existing core reset. Keep valid/credit/request/response/commit pipeline FFs, state reset and handshake gating. No extra two-cycle reset release holdoff. Clear pending transactions, credits, FIFO state and publication/ownership state on reset. Preserve feature-off RTL and existing core reset generation. No blanket timing or cross-SLR waiver.

## Verification
Reuse transport, controller, publication and frontend tests; cover reset with pending work, reset gating, stale-work clearing and first post-reset request. Use configured builds and the C4 config before VCS. Independent verifier uses tools/verify_rtl.py. Update physical negative controls so ordinary unregistered transaction crossings remain rejected and verified core-reset fanout is permitted. New RTL requires fresh physical implementation and hardware evidence.

## Evidence policy
Frozen R11 packages remain unchanged. Their failures stay historical failures. The complete plan still requires accepted 100 MHz physical results, a fresh unique image/alias, the 99-command hardware matrix and final delivery.
