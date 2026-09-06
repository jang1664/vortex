# P3: S/Z response-drain elastic boundary

Implemented behind `GEMM_S_Z_SINK_ELASTIC`, default disabled for independent
ablation. Generic `VX_gemm_stream_dma_queue.SINK_ELASTIC` defaults to zero;
only qparam queue/overlap wrappers use the configuration macro. Input and
weight behavior is unchanged.

## Ownership and timing boundaries

- A SIZE=2, OUT_REG=1, LUTRAM=0 elastic buffer captures the entire sink payload,
  destination metadata, sequence/beat tag, and last marker.
- `sink_handoff_fire` releases the response slot and advances the ordered
  staging/ring pointer. `handoff_count_r` counts these handoffs for the retained
  physical install head.
- `sink_write_fire` remains the physical sink handshake. It alone advances
  `cmd_write_r`, the qparam address counters, and install/done notification.
- The command descriptor, ID, sequence, and fence remain owned until the final
  physical write. Queued data therefore cannot outlive its metadata. Existing
  command occupancy includes the entire pending-buffer lifetime.
- Writer release is checked at the output using that retained head. Data may
  enter the elastic buffer before release without becoming externally valid.
  Final destination ready and writer release have no combinational path back
  through elastic input ready to RAM staging.
- Elastic mode does not use physical `install_pop` for next-head staging
  lookahead. A ready next command begins staging after registered retirement;
  this incurs a measurable command-boundary bubble. II=1 is a within-command
  steady-state claim, not an across-command claim.
- `progress_write_beats`, `fetch_head_write_beats`, and performance write-byte
  counters continue describing physical writes. Response-slot occupancy and
  `install_ready_ahead` exclude data already handed into the elastic buffer;
  qparam does not use `install_ready_ahead` for admission.
- Qparam destination address dimensions/segment offset already advance only
  on physical write. Buffered destination metadata drives address formation,
  so no address is derived from a later command head.
- S/Z same-cycle last-consume readiness in the compute core is unchanged and
  remains local to the elastic output.

No new module or interface was introduced. Macro definition is owned by the
controller/configuration implementation, not this change.

## Assertions and trace schema

Simulation assertions check handoff ownership, output sequence/beat/last
against the retained command, payload stability, response-slot accounting,
and `handoff_count - physical_write_count == elastic_pending` with occupancy
between zero and two. Final retirement requires exactly one queued beat,
all command beats handed off, and no simultaneous new handoff.

With `DBG_TRACE_GEMM`, simulation-only events are:

- `GEMM_SINK_EB_ENQUEUE`: time, instance, work_seq, sequence, beat, last,
  occupancy before the current edge.
- `GEMM_SINK_EB_DEQUEUE`: same identity fields at physical acceptance.
- `GEMM_SINK_EB_STATE`: every active handoff/buffer cycle, before-edge
  occupancy and input valid/ready, output owned/valid/ready, and writer fence.

Both event streams use the retained command's work sequence. No trace
occupancy counter is synthesized.

## Verification request

No simulation was run by the RTL implementation agent. `git diff --check`
passed. Verification must use the configured build and sourced configuration.

1. test_type: unittest; test_path: `hw/unittest/gemm_stream_dma_queue`;
   sim_tool: vcs. Extend the focused top to pass `SINK_ELASTIC=1` in explicit
   instances, while preserving existing disabled instances. Cover response
   RAM/FF, ring/non-ring, command depth 1/2/4, and sequence wrap. Existing
   tests' physical-write/same-cycle-slot-recycle coverage must refer to
   handoff for elastic instances; physical write and slot release are now
   intentionally different events.
2. test_type: unittest; test_path: `hw/unittest/lmem_dma_qparam_overlap`;
   sim_tool: vcs. Add an explicit TB sink-elastic parameter, test S and Z with
   32-byte payloads, both bank fences, RAM and FF response storage, and
   descriptors whose destinations/strides differ. Final destination address
   and sequence must match, including a stalled last beat.
3. Directed acceptance gates: with writer fence closed allow at most two
   buffered beats and zero physical writes/notifications; refill a released
   response slot while its old data is still queued; hold first/last beats
   under arbitrary/alternating/long ready stalls; reset with queued data;
   ensure completion/idle only reflects physical retirement. Prefill a long
   single command and prove consecutive physical accepts after initial
   latency with continuous readiness. Separately measure command-boundary
   gaps; do not enforce baseline next-head lookahead timing.
4. test_type: blackbox; test_path: `fpint_gemm_ffn_hw`; sim_tool: vcs;
   mode: `ci/run_black.sh xrt-vcs-sim`; configuration:
   `improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh` plus
   `-DGEMM_S_Z_SINK_ELASTIC=1` for A6. Run plan-specified M4 repetitions and
   final shape/qdir/transpose matrix after integration.

Changed RTL files: `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv`,
`hw/rtl/core/gemm/VX_lmem_dma_misal.sv`.

## Repair iteration: held non-ring request selection

The strengthened eight-slot generic test failed at 225 ns in the elastic,
non-ring, depth-one FF case: `VX_gemm_dma_fetch_if` reported a request changing
under backpressure. With four busy low slots and a stalled offered request
using slot four, prefetch handoff released an earlier slot and the combinational
lowest-free selector changed the tag. This is also possible without the new
elastic boundary when physical sink writes release low slots while a source
request is stalled; it is a generic non-ring allocator defect, not an elastic
capacity violation.

The repair retains only the selected slot index and a valid bit after the first
stalled offer. It keeps that choice until the request handshakes. The queue is
the sole allocator, so the held slot stays free; a same-cycle recycled choice
becomes free on the offer edge. The source command/beat cannot change until
request acceptance, and a command cannot physically retire while a beat remains
unissued. Thus no wide command/payload holding registers are needed. Ring mode
already retains `alloc_slot_r` until acceptance, so the new hold logic is
constant-disabled there. Continuous-ready traffic retains its original
same-cycle allocation/recycle behavior and gains no extra forward cycle.

An assertion checks that every retained non-ring request remains valid with its
selected slot free. Existing interface assertions still check the complete
request tag/payload under stall. No test stimulus or acceptance criteria were
weakened. Re-run the unchanged strengthened generic suite, including all enabled
and disabled instances, then the pending qparam S/Z/RAM/FF suite. Add/retain a
directed disabled-elastic non-ring case where a low slot physically drains
while a higher free slot is offered under source backpressure; the original
four-slot baseline stimulus does not necessarily expose that combination.

Only a static diff check was run by the RTL implementation agent. Simulation
results remain pending independent verification.
