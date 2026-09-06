# P4: G2L destination write elastic boundary

Implemented in `hw/rtl/core/VX_dma_unit_align.sv` behind module parameter
`LMEM_WRITE_ELASTIC`, whose default is `GEMM_HBM_WRITE_EB2`. The configuration
macro defaults to zero for independent A7 ablation. Compile-time L2G-only
instances (`FIXED_DIR=1`) omit this buffer regardless of the macro.

## Transaction and retirement

The SIZE=2, OUT_REG=1, LUTRAM=0 buffer captures the local destination address,
resolved wide write data, byte enables, flags, UUID, and tag. Its direction is
always write. Crucially, no-padding equal-width mode captures the existing
`ram_wr_slot_data` expression; padding mode captures the existing selected or
zero payload. No live response slot or descriptor address is used by a held
buffer output.

`dst_req_fire` remains the internal write-issue handshake, now elastic enqueue
for G2L. Existing offsets, segment state, and payload-slot release advance on
that event. `lmem_req_fire` remains actual aggregate acceptance by the external
TMEM interface. The unmodified fixed-pair adapter only produces this acceptance
after both 32-byte lanes accept; partial-lane masks and tag assembly are not
changed.

The existing two-bit `lmem_req_buf_pending_r` already counted **all** local
request issues minus physical accepts, not just reads. It now retains buffered
writes automatically. Both existing direction-specific DECIDE completion gates
require `lmem_req_buf_pending_next==0`, as well as source response/slot drain.
These gates were preserved rather than adding a redundant pending counter or
substituting queue acceptance for physical completion.

The shared count is bounded by two: local reads occur only for L2G, writes only
for G2L, and cfg/new direction is accepted only in IDLE or DONE. DONE requires
the old transport to have drained. Read and write buffers cannot simultaneously
own requests. An independent simulation-only write count and assertions check
this conservation, 0..2 bounds, mutually exclusive direction ownership, and
no done/new descriptor before physical drain.

## Data release audit

Existing G2L write issue is gated by `lookahead_if.data_release`; no buffered
write can be admitted before release. In `VX_gemm_tmem_dma_ctrl`, release is
`!work_data_prefetched_q || work_data_released_q`. A prepared command changes
release from zero to one only at the registered architectural release. It
remains released until logical completion, which requires all active channel
done events. New data prepare is accepted only in S_SELECT, and chaining
replaces work ownership only after channel completion. Generic DMA node use
ties release high. Therefore output release cannot be revoked while a queued
write remains physically unaccepted. Simulation asserts this invariant and
held request/entry identity; no extra live fence gate or ready feedback was
introduced at output.

L2G destination transport and the existing read buffers are unchanged. Payload
width, TMEM mapping, DMA channel count, source outstanding depth, and layout are
unchanged.

## Trace events

`DBG_TRACE_GEMM` adds simulation-only `DMA_WRITE_EB_ENQUEUE` and
`DMA_WRITE_EB_DEQUEUE` events with timestamp, instance, retained entry ID,
address, byte enable, and before-edge occupancy. `DMA_WRITE_EB_STATE` records
active-cycle occupancy and input/output valid/ready. The existing performance
write counters already use physical `lmem_req_fire` and retain that meaning.

## Verification request

No simulation was run by the RTL implementation agent. `git diff --check`
passed. Tests must use configured builds and the sourced MXU16 configuration.

- test_type: unittest; sim_tool: vcs; changed_files:
  `hw/rtl/core/VX_dma_unit_align.sv`. Run aligned DMA source/destination focused
  suites with `LMEM_WRITE_ELASTIC=0/1`, equal 64-byte buses, padding both
  enabled and disabled, partial final-byte enables, and direction changes.
  Include existing width-conversion tests with padding enabled where supported.
- test_type: new_tb or extended integration suite; sim_tool: vcs. Couple the
  aligned DMA to `VX_tmem_dma_pair_adapter` and 32-byte bank responders. Stall
  either lane independently, particularly the final beat with the other lane
  already accepted. Require exactly one half-write per enabled lane, stable
  payload/address/tag while stalled, zero early done/cfg handshakes, then prompt
  drain and next-descriptor/direction acceptance. Exercise consecutive ready,
  alternating/long stalls, and reset with queued/partially accepted writes.
- Prove one beat/cycle steady state at the elastic boundary with preavailable
  input data and both banks continuously ready. Do not confuse the preexisting
  response-RAM refill throughput with the buffer's transport II.
- test_type: blackbox; sim_tool: vcs; mode:
  `ci/run_black.sh xrt-vcs-sim`; app: `fpint_gemm_ffn_hw`; A7 selector:
  `-DGEMM_HBM_WRITE_EB2=1`. Follow the plan's M4 repetitions and final shape/
  qdir/transpose matrix after integration.

The timing check must demonstrate final bank/pair ready no longer reaches
`wr_slot_read_ready`, `wr_slot_pop_ready`, write offsets, or source slot refill
through combinational write acceptance. Completion still depends on physical
drain through registered state, as required.
