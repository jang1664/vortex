# External LOAD visibility contract for naive T-ready

## Finding and retained evidence

External DMA worker completion is not physical LMEM write visibility. In the
retained corrected naive M4/QCOL/WTRANS0 capture, **all 64 LOAD completions**
still have **3 to 48** reserved but uncommitted 8-byte lane writes. Final bank
commits occur **4 to 15 GEMM-clock edges later**. The audit accounts for all
**22,528** enabled physical lane writes exactly, with no remaining reservation.
This is not a newly observed numerical corruption: the baseline workload
passes, and its later control/startup intervals can hide the gap. This audit
does not claim that every later GEMM T notification is premature: its poll
latency and exact notification edge were not compared here.

Representative strict-preedge samples:

| Worker done edge | Remaining writes after same-edge commits | All writes committed edge |
|---:|---:|---:|
| 8,569 | 32 | 8,573 |
| 9,038 | 16 | 9,042 |
| 9,122 | 32 | 9,126 |
| 9,207 | 32 | 9,211 |

`p0-load-visibility-check.py` reuses the hash-checked baseline bank trace and
extracts only three additional signals via fsdb_cli: generated destination
transfer fire, generated LMEM byte mask, and bank request tags. It reserves
one word per nonzero 8-byte mask at generator acceptance, before downstream
scatter. Every actual bank write classified as normal-DMA origin independently
matches the source region [0,0x15000), and vice versa. Counts are based on actual
masked requests, not expected tensor sizes. `p0-load-visibility-results.json`
contains every worker completion and waveform/manifest/snapshot hashes.
The extra transitions are in `p0-load-visibility-signals.json`.

For this exact captured geometry, bank tag width is 12, UUID width is 1,
normal/priority selection is bit10, and the normal arbiter selector is bits9:8.
The checker asserts those captured route values. Implement symbolic widths,
not these numbers. Ordinary CPU writes, GEMM PSUM/final writes and source
region accesses must never be confused by an address-only classifier.

## Source explanation

- `VX_dma_unit_misal.sv:684-685` decrements lmem_req_pending on its wide LMEM
  request handshake. The S_RUN -> S_DONE condition at lines909-913 checks its
  internal request/response/drain state, not downstream bank commitment.
- `VX_dma_node.sv:65-136` has exactly one worker and a local lane splitter with
  request skids. Its lookahead interface is tied inactive at lines55-61.
- `VX_mem_unit.sv:157-246` adds buffered normal and priority arbiters. A write
  behind an older blocked request at one input need not outrank a later
  same-bank read arriving through another input.
- `VX_gemm_dma_ctrl_naive.sv:746-764` recognizes the DMA MMIO entry's release or
  token change. This is not a bank acknowledgment.
- `VX_local_mem.sv:403` writes RAM on the actual bank valid/ready/rw handshake.
  Its same-bank following-edge RAW guard is already present at lines416-425.

Thus neither worker completion, a later MMIO poll, nor a measured 15-cycle wait
can be the invariant for T-ready under arbitrary finite stalls. The previously
proposed GEMM-priority bank-return classifier covered only PSUM/final writes;
external LOAD writes enter the normal-DMA input and were outside it.

## Binding minimal naive-only fence

Keep each DMA descriptor owned until all its LMEM destination writes commit.
Under `ifdef GEMM_NAIVE`, separate the existing worker done interface from the
job frontend done interface in VX_dma_node. Forward both done-valid and
worker-done-ready only when the new pending count and partial-wide reservation
are empty. Hold the original entry_id and worker S_DONE until this handshake.
The worker cannot accept another descriptor until then. Stores have no LMEM
writes; with an empty counter they retain the original path. CPU-issued LOADs
through this same naive worker are fenced too, preventing foreign pending
writes from being attributed to a later GEMM descriptor. No improve port,
queue, tag or timing path changes.

### Bank event encoding, shared with the PSUM/final fence

Use the already budgeted **three bits per bank**, encoding:

| kind[1:0] | Meaning | psum_set bit |
|---|---|---|
| 00 | No relevant committed write | Ignored |
| 01 | Committed GEMM PSUM lane | Existing reconstructed PSUM set |
| 10 | Committed GEMM final-output lane | Ignored |
| 11 | Committed normal-DMA LMEM lane | Ignored |

A bank accepts at most one request per edge, so these classes cannot coincide.
Classify DMA by priority-origin=normal at
LMEM_LOCAL_TAG_WIDTH-UUID_WIDTH and normal-arbiter-origin=1 at
GEMM_LMEM_TAG_WIDTH-UUID_WIDTH. The normal selector has ARB_SEL_BITS(3,1) bits.
GEMM-priority PSUM/final decoding remains as in p0-visibility.md. CPU input0 and
ordinary GEMM input2 do not create DMA commit events. Return via naive-only
VX_local_mem -> VX_mem_unit -> VX_core control connections. At most one
register stage is allowed: **48/96 bits total at 16/32 banks**, shared with the
existing bank-commit allocation, not another vector counted on top. No result
payload, address bus, new memory tag or per-write generation tag returns.

### Exact reservation and credit bound

Add **one 12-bit unsigned pending-lane counter**, maximum **4,095**, and **one
reserved-current-wide-request bit** in VX_dma_node: **13 new functional bits**.
No payload register is added. Use the existing worker-held wide request.

Before presenting any lane of a new write to the splitter, count active lanes
by OR-reducing each 8-byte enable group (same ENABLE_LANE_MASK=1 semantics).
Reserve the entire count exactly once on first admitted presentation, before
partial scatter can occur. If pending+new_lanes exceeds 4,095, gate the new
wide request before the splitter and backpressure the worker; do not partially
issue an unreserved word. Already reserved writes remain valid while stalled.
Clear the reservation bit on full wide handshake, including same-edge initial
reserve/full acceptance. Reads do not reserve writes.

On every edge compute in at least 13-bit intermediate arithmetic:

`pending_next = pending + newly_reserved_lanes - committed_DMA_lanes`.

Assert committed <= pending+newly_reserved, next <=4,095, no duplicate reserve,
stable stalled request/mask, and no next descriptor dispatch while pending or
reserved state remains. Credit checks may conservatively ignore same-edge
freed credits; they cannot discard commit pulses. Return-event registering
must preserve every accepted bank event. Overflow is prevented by admission
credit gating even for arbitrarily long legal CPU/GEMM DMA descriptors; this
bound does not assume a maximum descriptor byte length.

Publish frontend completion only when worker done-valid, current pending=0,
no held reservation and no same-edge new reservation. The producer is closed
by worker S_DONE: internal generation, response slots and both outgoing request
queues have drained. A later pending write cannot be created by that worker.
Bank writes drain independently of descriptor completion, so this fence does
not wait for its own consumer or another descriptor to execute.

### Exact owner and source-generation mapping

Existing DMA worker entry_id and the job frontend's entry owner/generation stay
owned until the fenced done handshake. The single-worker invariant means all
reserved DMA writes belong to that active descriptor. It avoids adding an
owner record to every physical request. A changed design admitting a second
worker/descriptor before drain invalidates this proof and requires a revised
explicit ownership design.

The naive external command executor already has one active command owner.
Capture its source-buffer bit, source generation and I/W/S/Z member at LOAD
acceptance, and retain them through its allocated DMA entry's fenced completion.
Do not use a bare changed MMIO token across reset/reuse as source readiness.
Join **four distinct matching fenced LOAD completions** for one physical
source-buffer generation; only the full join publishes T0/T1. Member duplicates,
old generations and reset-token changes must fail ownership checks. The next
generation may reinitialize that buffer's join only after the previous
SRC_FREE and actual command acceptance; buffers remain separate.

Freeze an explicit conservative metadata ceiling outside the S/Z engine budget:

- Active external LOAD receipt: valid1 + buffer1 + generation32 + member2 =
  **36 bits**, one record, sharing the existing active descriptor identity.
- Per-buffer T-ready join: generation32 + completed-member mask4 + published1
  = **37 bits per buffer**, **74 bits** for the two buffers. Keep pending
  notification stable until accepted; published prevents duplicate updates.
- DMA pending/reservation: **13 bits** as above.
- Total additional global control allowance: **123 bits**, no operand payload.
  Existing command/notification records are separately budgeted, not duplicated
  here. Existing entry/owner/generation state is reused. Omit redundant receipt
  fields if already retained within an existing counted record; do not spend
  the same storage twice. Bank-event vector remains the existing shared 48/96
  bits, with the revised encoding above.

## Required implementation verification request

These are P1/P2 integration requirements, not a claim of current stalled RTL
passing. Use configured builds, proper backend configs and VCS/verify_rtl.py for
new directed unit tests. Cover MXU16 and MXU32:

1. Delay a normal-DMA write behind a different input-port request; offer a later
   GEMM source read to the same bank/address. Raw worker done may assert, but
   frontend done/T-ready and the dependent read stay blocked until bank commit.
2. Partial lane masks, zero masks, staggered lane acceptance, simultaneous
   first reserve/commit and reserve/full handshake. Count each active word once.
3. Reach the 4,095 credit cap using a long descriptor and finite bank stalls;
   no unreserved lane launches, commits reopen credits, and completion drains.
4. Interleave CPU and GEMM descriptors in the existing frontend, with distinct
   entry owner/generation values. A CPU write cannot release a GEMM T-ready
   join; next dispatch cannot occur before prior ownership drains.
5. Four-resource completion in varied orders, both source buffers, duplicate
   and stale member controls, three source generations without reset; T updates
   exactly once only after all four members' physical fences.
6. Mix CPU normal writes, ordinary GEMM reads, PSUM/final writes and DMA writes;
   compare returned event classes against actual per-bank handshakes. No class
   overlap, lost pulse, wrong set or improve-visible hardware is acceptable.

Retain quiescent reset support only. Verify improve's synthesized structure and
latency remain unchanged. Fixed-cycle waits are expressly excluded.
