# Publication ready feedback: source-only repair assessment

2026-10-24, read-only. Actual R4 opt-DCP graph confirmation is owned by independent
verification. No production source, FPGA constraint or live process is changed.

## Candidate structural cut

`VX_mem_unit.sv:287` currently counts a CPU LMEM admission from
`req_valid && req_ready && rw && lane_mask && LOCAL && !MMIO`. The same-cycle
admission count contributes combinationally to `fusion_lmem_published_o` at
line308. That signal gates PUBLISH request ready in `VX_sram_fusion_ctrl.sv:102`,
which returns through MMIO buffering/switch request-ready paths. MMIO exclusion
in the predicate does not make this structural feedback disappear.

The smallest feature-only candidate is a separate per-lane `store_present`
predicate containing all existing conditions except req_ready. Define admission
as `store_present && req_ready`; retain accepted-count/pending/physical-commit
accounting exactly. Define published as `pending_stores_q==0 && !(|store_present)`.
This does not register published or remove same-cycle protection. Every old
accepted store is presented, so every same-edge admission that blocked old
publication still blocks it. A stalled presented store additionally delays
publication conservatively until admission and physical completion.

For actual C4, `VX_lsu_slice` passes equal WORD_SIZE/LINE_SIZE and equal lane counts
to `VX_mem_scheduler`: no coalescer, one memory batch, and MEM_OUT_BUF0. Its
request queue is CORE_QUEUE_SIZE2/OUT_REG1; `VX_stream_buffer` drives valid and
data from registers. Therefore current presented valid/rw/mask/address/flags
do not depend combinationally on returned ready. The candidate removes that
specific structural ready→publication→ready edge at its source.

Keep fusion-controller doorbell logic unchanged:
`bridge_busy_o = engine_busy || (request_fire && start_request)` still excludes
same-edge GEMM dispatch. MMIO address exclusions and DMA-vs-CPU commit decoding
remain unchanged. All candidate logic belongs inside GEMM_SRAM_FUSION.

## Ordering and progress cases

- An already admitted store keeps pending positive until its physical commit.
- A store offered on the publication edge blocks publication independently of
  ready. If admitted, pending takes over on the next cycle; if stalled, the
  presented predicate continues to block. No gap appears between the two.
- A pure LMEM store at the queue head needs only the local output path. Holding
  a prior PUBLISH in the DMA-MMIO output buffer does not stop that local path
  from accepting/draining it; physical-bank backpressure can delay progress but
  cannot create this MMIO ready dependency.
- A PUBLISH request is a read and req_data.rw is common across all lanes. It
  cannot itself also be a same-packet LMEM write. Inactive lanes and MMIO stores
  remain excluded.
- Existing upstream queued-publication test forces both boundary valid and
  ready low. The new predicate therefore remains false in that artificial hold
  and preserves its expected published=true/accepted-count0 observation. A new
  natural valid-held/ready-low case is still needed to cover the conservative
  change, with a real physical commit before read completion.

## Shared-port limitation requiring explicit review

`VX_lmem_switch.sv:94` combines active destination readiness. A later WRITE packet
with both LMEM lanes and DMA-MMIO lanes could be blocked behind an older buffered
PUBLISH while its presented LMEM store holds publication low. This is a potential
head-of-line cycle for the naive valid-only candidate if mixed-destination
packets are treated as supported.

The existing switch independently asserts valid into each destination buffer,
even when aggregate request-ready is low. Therefore mixed-destination packet
semantics already need careful review: one destination may accept while another
blocks, outside the aggregate admission count. This assessment does not claim
such mixed traffic is currently correct, or authorize shared-switch changes.
No explicit generic mixed-LMEM/MMIO rejection was found in the inspected path.
The current decoder uses ordinary LMEM stores followed by separate single-lane
MMIO publication/doorbell instructions, which avoids that mixed packet shape.

Before choosing the candidate, either establish/document that supported fusion
producers issue separate destination classes as the actual decoder does, or add
a directed mixed-mask analysis/test and address it without an unproved blanket
liveness claim. Do not silently drop same-cycle store exclusion to avoid this
question. A registered publication result alone would miss the protected edge.

## Verification request if selected

Retain current publication, queued-producer, reset and doorbell/GEMM exclusion
tests. Add a real offered valid/ready-low LMEM store with zero pending count and
require published=false, then exactly one admission/physical commit and normal
PUBLISH completion. Exercise multiple producer masks, ignored inactive lanes,
MMIO address exclusion and simultaneous final-commit/new-admission behavior.
Include the shared-port packet scope decision in the test report.

Require feature-off selected-source identity and a fresh actual synthesized
structural SCC/DRC check after any authorized RTL revision. The R4 warning is
not waived by passing simulation or by this source argument. R4 remains frozen
until root explicitly authorizes a new revision; no current run is restarted.
