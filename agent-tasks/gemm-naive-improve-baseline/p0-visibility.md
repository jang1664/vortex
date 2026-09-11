# P0 physical completion and visibility audit

## Decision

Keep normalized GEMM latency at the existing `e_cfg -> first done-valid` boundary. For naive, define `e_store` / O release as completion of the cache-path output DMA descriptor: every source OBUF read has returned, its payload has been transferred into the destination path, and that descriptor can no longer read OBUF. This is sufficient to release the *source* OBUF/PBUF owner. It does not mean the final data has reached HBM. Existing write-through cache drain and AXI write-response drain remain the host-visibility boundary; no new HBM wait or improve behavior change is needed in P0.

The existing `gemm_wr_lane_pending_r == 0` is **not** a RAM-commit fence. The retained corrected naive M4 FSDB demonstrates this directly. G1/OUTPUT_READY in the redesign must use a naive-only bank-commit control event and ownership accounting, unless an actual ordered read boundary is separately proved. Per-input FIFO order and the baseline's startup delay are not that proof.

This result closes the semantic distinction between source release and host visibility. It does not turn the old node-pending counter into a general physical visibility proof. The proposed bank-commit change is a binding implementation requirement before overlapping reuse can pass the plan's physical-write gate.

## Retained FSDB evidence

Run `python3 agent-tasks/gemm-naive-improve-baseline/p0-visibility-check.py`. It uses `fsdb_cli.report`, samples values strictly before each rising edge, and checks the retained `p0-baseline/naive-m4-retry1/wave.fsdb`. Results and source/config hashes are in `p0-visibility-results.json`; raw selected traces are in `p0-visibility-signals.json`.

| Check | Observed result |
|---|---|
| Node accepted PSUM/final lane writes matched to actual bank writes by address, data, byte enable | 32,256 / 32,256, no mismatch or unretired write |
| Node acceptance to bank RAM-write edge | Exactly 3 cycles for every matched write in this trace |
| `gemm_done_drained` events | 1,024 |
| Those events with bank writes still pending | **1,024 / 1,024**, maximum 16 outstanding words |
| Actual PBUF / OBUF bank reads checked for a pending earlier same-address node write | 31,744 / 512; no observed overtaking |
| Each of four output DMA workers | 8 source requests, 8 source responses, 16 destination requests; source slots and both request-buffer counts zero at worker done |
| Worker done / polled `store_done` edges | 24408/24414, 39621/39627, 54830/54836, 70025/70031 |
| Host AFU done edge | 71955, with cache drain and AXI pending-empty both true |

The configured external DMA reads aggregate 16 LMEM ports × 8 bytes = 128 bytes per source beat, then writes 64-byte destination beats. Each M4/N128 output tile is 1,024 bytes: eight source and sixteen destination beats. This makes the cross-port issue stronger than an assumed 64-byte source beat. Final GEMM writes remain 32 bytes for MXU16.

These are verified transitions for one corrected M4/QCOL/WTRANS0 invocation, not a proof under arbitrary memory stalls or overlapping candidates. Source hashes for the inspected RTL match the retained run manifest. No simulation or production edit was made by this audit.

## Why descriptor retirement releases OBUF

1. `VX_core.sv:314` instantiates the core DMA node with `ENABLE_MISALIGN=1`. `VX_dma_node.sv` selects `VX_dma_unit_misal` through `VX_dma_unit.g_misaligned.u_impl` and uses `VX_job_frontend` for descriptor ownership.
2. In `VX_dma_unit_misal.sv:667`, a store's source is LMEM (`active_dir=1`). Every issued source request reserves a response slot. `src_rsp_fire` writes `response_payload_ram` and sets the corresponding slot READY (`:724`, `:1024`). A slot reaches DRAINING only after its captured response is read. `slot_retire` frees it only when the realigner accepts its payload (`:770`, `:1031`).
3. `S_RUN -> S_DONE` at `:908` requires RD_DONE, WR_DONE, `slot_occupancy_next==0`, `dcache_req_pending_next==0`, and `lmem_req_pending_next==0`. WR_DONE is set only after the final generated destination beat is accepted (`:1040`). The pending counts compare internal issue with actual downstream request handshake (`:660-685`). Thus worker completion cannot precede an outstanding OBUF response or leave a future OBUF source read behind. Downstream cache buffering still owns the copied data.
4. `VX_job_dispatcher.sv:83` clears the exact active entry only on `done_if.valid && done_if.ready`. `VX_job_desc_mmio_regs.sv:340` then clears occupy/working. A new allocation selects only unoccupied entries and increments the generation (`:378-394`). Consequently a changed owner/generation token also implies the old descriptor was released first, under the supported no-reset/no-token-wrap conditions.
5. `VX_gemm_dma_ctrl_naive.sv:746` polls the allocated entry's control register. It recognizes either occupy/working cleared or an ownership/generation change. `store_done` at `:516` asserts on that response's transition to S_DONE for OP_DMA_ST. It is later than worker completion, as the FSDB's six-cycle gaps confirm.

The proof obligation is source ownership, not host visibility: queued write-through traffic contains the bytes and does not refer back to OBUF. Reusing OBUF after O cannot change that copied payload. Retain separate invocation/entry/generation identities; reset-induced token changes or generation wrap are outside this argument and require their own tests.

## Existing host visibility boundary

In write-through mode, `VX_cache_bank.sv:633` enqueues a memory write for every accepted non-replayed store. Its drain expression at `:245` covers lookup stages, MSHRs, response state, and outgoing memory queue. `VX_cache`, `VX_cache_wrap`, `VX_cache_cluster`, `VX_socket`, `VX_cluster`, and `Vortex` aggregate drain and exclude pending request/response interfaces.

`VX_afu_wrap.sv:164` enables cache-drain gating only when `AFU_DONE_WAIT_CACHE_DRAIN` is defined and DCACHE/L2/L3 are write-through. At `:173-175`, AFU completion requires STATE_DONE, AXI pending writes empty, and cache drain. `VX_axi_write_drain.sv:77` defines empty by all three equalities: accepted AW count equals B count, AW count equals WLAST count, and the sum of AW burst beats equals accepted W beats. Host completion therefore waits for cache emission and the memory model's AXI write responses. It does not merely look at a posted write's address handshake.

This is the supported deterministic XRT/VCS memory-model contract, not a claim about persistence beyond AXI completion on arbitrary hardware. The checked baseline has these configuration guards and observes both drain terms high at AFU done. The GEMM done-valid timestamp should remain earlier and retain its existing meaning.

## Why the present G1 candidate is not sufficient

The existing path is:

```text
accumulator wide request, reserved once on first presentation
  -> GEMM lane splitter / node lane arbiter
  -> psum_wr_lmem_bus_if[p] handshake: CURRENT pending counter pops here
  -> mem_unit.g_lmem_priority_order[p].lmem_priority_arb, REQ_OUT_BUF=3
  -> local_mem request crossbar, OUT_BUF=3 and hierarchical arbitration
  -> per_bank_req_valid[b] && per_bank_req_ready[b] && per_bank_req_rw[b]
  -> local_mem.g_data_store[b].lmem_store.write: RAM updates on this edge
```

`VX_gemm_node_naive.sv:323-389` reserves the whole lane count once even if a wide request is partially forwarded, and retires those reservations at the node's outgoing lane handshake. That correctly protects the node's own split queues, but downstream request buffers are outside its count. FSDB proves the distinction rather than inferring it from names.

`VX_mem_unit.sv:212-246` gives GEMM writes priority in each input port's arbiter, and the LMEM xbar also uses fixed priority. This does not imply that a write queued in one input port precedes a later read from another port. For example, OBUF+32 is written through final lanes 0–3 but appears in lanes 4–7 of a 128-byte DMA source request. A write behind an earlier blocked request in port 0 is not a visible xbar contender; a later same-bank read from port 4 can be visible. Priority cannot select the hidden write. A finite stall on that earlier request can outlast any fixed startup gap. This topology argument identifies a missing ordering invariant; it is not a newly simulated corruption trace.

The configured HIER path does not enable the Omega store-CAM guard. Enabling a different fabric is not a substitute for the required naive-specific ownership fence.

At the actual bank, one request is selected per bank, so same-cycle read and write cannot both fire there. The RAM write condition is exactly `per_bank_req_valid && per_bank_req_ready && per_bank_req_rw` (`VX_local_mem.sv:402-403`). `last_wr_valid/last_wr_addr` additionally block a read of the same address on the following edge (`:416-425`), avoiding the RAM read-during-write hazard. Thus an acknowledgment from the bank-write edge is an unambiguous commit endpoint; a read admitted only after that fence cannot precede the write.

## Required naive-only implementation proposal

### Event insertion and identity

Add synthesis-visible **naive-only control outputs** at `VX_local_mem`, immediately beside `g_data_store`'s RAM write expression. Carry them through `VX_mem_unit` and `VX_core` to `VX_gemm_node_naive`, all under `ifdef GEMM_NAIVE`. The improve branch must elaborate exactly its existing ports, tag widths, buffers, and logic.

Use the existing bank request origin/tag information; no payload or new result-data path returns to the GEMM node:

- `per_bank_req_idx[b]` identifies the original LMEM input port. For naive, a GEMM write must come from a port below GEMM_PSUM_LANES.
- `lmem_priority_arb` inserts its origin bit at `LMEM_LOCAL_TAG_WIDTH - UUID_WIDTH`. Zero identifies its GEMM-priority input, one the normal input. The bit survives into `per_bank_req_tag[b]`.
- The node's three-input write arbiter previously inserted two route bits at `GEMM_BASE_TAG_WIDTH - UUID_WIDTH`: selections 0/1 identify PSUM lane sources, selection 2 identifies final output. `ASSIGN_VX_MEM_BUS_IF_EX` only zero-extends above the existing tag value, so those positions remain intact. Decode symbolic constants and assert the allowed source/port combinations; do not hardcode a baseline numeric width.
- `VX_local_mem` drops request flags before its bank queue, so flags alone cannot identify bank commits without adding a naive-only packed field. Existing tags and port index avoid that change. Current accumulator memory tags are zero payload identity plus routing: they do **not** carry work_seq/tile generation.

A compact event per bank contains `commit_valid`, `is_final`, and PSUM bank-set identity if the existing PSUM ordering counters use it. Derive bank-set identity from the reconstructed local word address `{per_bank_req_addr, bank_index}` at `CLOG2(GEMM_PSUM_LANES)`; this remains correct for MXU16 and MXU32. No address/data bus needs to return when only counts are required.

### Ownership accounting and close condition

Keep reserve-on-first-presentation for partially forwarded wide writes. Add each reserved physical lane exactly once, and decrement only on its actual bank commit, not node acceptance. The existing node-queue counter may remain diagnostic, but it cannot drive G1 or physical PSUM order release. Retarget the physical PSUM bank-set counters to actual PSUM commits as well, preserving current same-address accepted-producer checks.

All compute writes belong to one PBUF/OBUF owner because every next-owner Input admission waits for the prior O event. Hold that owner/generation until its closed-producer marker and all bank commits are complete, followed by STORE release. This permits aggregate per-owner pending accounting without adding a work ID to every memory write; prove that no future-owner write can exist during that lifetime. If integration permits multiple write owners, this simplification is invalid and exact ownership must be carried in a naive-only tag/metadata extension instead.

G1 may publish only when (a) the real terminal Input has established a closed producer set for its output owner, (b) every reserved matching PSUM/final lane has committed, and (c) no result-conversion/write holder can create a later unreserved write. Use next-state counts or a following registered edge to handle simultaneous reserve/commit correctly; never inspect current zero while a new reserve arrives. A held producer-close event must not be lost under notification backpressure.

### Control-cost ledger and verification

| Item | Proposed cost treatment |
|---|---|
| Per-bank event classification | Naive-only combinational tag/port decode plus existing write-fire terms; zero payload storage |
| Commit event transport | Direct control wires, or at most one registered stage. A registered three-bit-per-bank event costs 48 bits at 16 banks and 96 bits at 32 banks, plus reset behavior; account the chosen implementation, not both |
| Pending counters | Reuse or replace existing total/per-set counters where semantics allow. Recompute the maximum in-flight lane reservations under all configured buffers; retain 12-bit width only with a bound below 4096. Any widening is naive-only and belongs in the ledger |
| Output owner / closed marker | Reuse command-generation metadata where available; otherwise one owner/generation register of its declared width and one closed bit. Do not claim zero extra bits before elaboration |
| Result data / payload queues | Zero added payload bits; no widening of improve metadata, no new cache or forwarding store |
| Improve cost and timing | All ports/logic/parameters guarded out. Re-run exact structural/resource and cycle comparison after implementation |

Required directed verification must stall a bank behind an earlier request, put a final upper-half word and a later DMA read on different input ports, and show that G1 stays blocked until bank commit. Check simultaneous reserve/commit, delayed final lanes, owner-close races, per-set PSUM read hazards, three or more OBUF/PBUF reuses, and reset only at the supported quiescent boundary. Verify returned control identities against actual bank write edges and ensure duplicate/missing acknowledgments fail assertions.

The parent's audit additionally found that host `-r 3` resets the GEMM epoch between jobs. Those runs verify changed payloads individually but are not no-reset lifecycle coverage. Add the required integrated-node or purpose-built kernel sequence for no-reset ownership/generation testing; do not credit ordinary `-r` for that requirement.
