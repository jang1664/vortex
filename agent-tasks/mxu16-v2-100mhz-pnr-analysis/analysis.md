# MXU16 v2: why 100 MHz still fails

## Scope and evidence

Read-only diagnosis of build
`build/hw/syn/xilinx/xrt/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem_v2_xilinx_u55c_gen3x16_xdma_3_202210_1_hw`.
No RTL changes, synthesis reruns, or functionality/performance tests were performed.
Vivado 2025.1, device `xcu55c-fsvh2892-2L-e`, requested kernel period 10 ns.

The final DCP was opened and 3113 worst failing endpoint records were captured
in `failing_paths.tsv`, including the full top 500 and representative full
paths for every local DMA and the HBM engine. This is a **partial** capture,
not the distribution of all 8580 failing endpoints. Detailed-report generation
was interrupted after it over-expanded direct register names into report
scopes; no implementation job or checkpoint was modified. `analyze.tcl` has
been corrected for future reruns (dump the entire TSV first, then report only
bounded module scopes); that corrected script was not rerun. Utilization and
congestion numbers below come from the existing implementation reports, not
from unfinished scoped utilization queries. `summarize.py` labels partial data.

Primary evidence under that build:

- `bin/impl_1_hw_bb_locked_timing_summary_routed.rpt`: final setup/hold results and full worst paths.
- `bin/vortex_afu.xclbin.info`: requested and achieved clocks.
- `_x/link/vivado/vpl/prj/prj.runs/impl_1/`: placed/post-route timing, congestion, route status, and final checkpoint.
- `_x/link/int/xo/ip_repo/xilinx_com_RTLKernel_vortex_afu_1_0/src/`: actual packaged source, compared with the non-v2 build.

## What improved, and what did not

| Metric | Previous build | v2 |
|---|---:|---:|
| Requested frequency | 100 MHz | 100 MHz |
| Achieved frequency | 81.3 MHz | 86.4 MHz |
| Final WNS | -2.297 ns | -1.572 ns |
| Final TNS | -18782.457 ns | -4525.323 ns |
| Failing setup endpoints | 20540 | 8580 |
| Worst hold slack | +0.005 ns | +0.009 ns |

The launch buffer helped: TNS magnitude fell by about 76%, and failing endpoints
by about 58%. It did not cut every compute-to-DMA control path.

The packaged source directories differ in **only `VX_gemm_node.sv`**. The diff
is the one-entry registered HBM DMA command launch buffer from commit
`16663576`. Scale/zero-point consume feedback, local DMA launch, and response
queue turnover are unchanged. This is not evidence of a stale build omitting
the intended modification. The saved config fingerprints are identical.

v2 placed timing was already failing: WNS -0.794 ns, TNS -494.625 ns, 1846
endpoints. Routing worsened this to -1.572 ns / -4525.323 ns / 8580 endpoints.
Post-route physical optimization did not improve the reported setup result.
All 934458 routable nets are fully routed, with zero routing errors.
The failure is setup timing, not missing routes or hold timing.

## Root cause 1: same-cycle S/Z consume feedback reaches payload RAM control

The final worst path, starting at timing report line 2085:

```text
GEMM ctrl sync_regs_q[6][19] (W1 load generation)
  -> weight_ready / compute issue / ZP consume event
  -> same-cycle sync_zp_consume1_next
  -> local ZP writer fence / GEMM destination ready
  -> sink_write_fire / install_pop
  -> next command, beat and response-slot selection
  -> response_payload_ram ENARDEN
```

Slack is **-1.572 ns**, with **10.899 ns data-path delay**: 2.395 ns logic,
8.504 ns routing (78.0%), 31 logic levels including 9 CARRY8s. The next path
to another ZP payload BRAM has -1.543 ns slack. This is a control/enable path,
not a 256-bit payload arithmetic path.

RTL correspondence in the current source (unchanged in these blocks between builds):

- `hw/rtl/core/gemm/VX_gemm_ctrl.sv:542`: 32-bit consume counter next-state additions.
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv:657`: weight consume outputs use registered
  `sync_regs_q`; **scale and ZP outputs still use combinational `*_next`**.
- `hw/rtl/core/gemm/VX_gemm_compute_core.sv:1531`: weight readiness controls
  `compute_fire`; line 644 derives the QROW ZP consume event from it.
- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:1423`: qparam writer release compares
  the consume value with the command's target.
- `hw/rtl/core/gemm/VX_gemm_compute_core.sv:1078`: S/Z destination readiness
  also includes same-cycle consumer release.
- `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv:182`: sink turnover selects
  the post-write command/beat/slot combinationally to sustain one beat/cycle.
- `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv:275`: `stage_found` directly
  enables the payload RAM read.

Having a registered **data** stage does not register the reverse ready path
or the next-slot read-enable calculation. These shortcuts concatenate in one
cycle. Optimized net names may sit under the compute or RAM hierarchy even
when the corresponding operation comes from scheduler/queue RTL.

## Root cause 2: local DMA command launch remains combinational

The third reported path, line 2513, is a different branch:

```text
compute load_result_valid
  -> accumulator writeback handshake / tagged_final_writeback
  -> child completion and sync dependency resolution
  -> scale_dma_ctrl_if.start
  -> local queue command_enqueue
  -> cmd_request_r[1][12] synchronous reset
```

Slack is **-1.512 ns**, with **10.633 ns data-path delay**, 28 logic levels,
and 8.460 ns routing (79.6%). Eight of the ten worst setup paths in the
packaged timing summary end in scale local DMA command counters.

`VX_gemm_node.sv:846` directly forwards the scale start, and line 887 does
the same for ZP. These do not pass through `u_gemm_dma_launch_buffer` at
line 1231. Thus the v2 change cuts HBM command launch only; the scheduler
can still propagate current-cycle completion through to local DMA enqueue.

Fixing only the ZP consume path will therefore not close timing.

The DCP also confirms this completion-to-dependency-to-launch chain for output
(-1.469 ns), input (-1.413 ns), and weight (-1.291 ns) local DMA. Do not assume
that fixing only scale/ZP launch removes the shared scheduler bottleneck.
A registered completion/dependency boundary is another candidate for cutting
the common upstream chain, but it changes same-cycle scheduler wakeup and must
preserve completion identity, updates, and throughput contracts.

## Top-500 endpoint distribution

One worst setup path per endpoint, sorted by slack; these are not all failing
paths or path-membership counts:

| Endpoint block | Count | Worst slack (ns) |
|---|---:|---:|
| Zero-point local DMA | 55 | -1.572 |
| Scale local DMA | 133 | -1.512 |
| Output local DMA | 103 | -1.469 |
| GEMM controller | 24 | -1.465 |
| Input local DMA | 119 | -1.413 |
| HBM DMA engine | 22 | -1.321 |
| Weight local DMA | 42 | -1.291 |
| Other GEMM node logic | 2 | -1.237 |

**452/500 (90.4%)** end in local DMA, and 439/500 start in compute and end in
local DMA. The equivalent prior-build top 500 were dominated by HBM DMA
endpoints (492/500). The v2 launch cut has exposed the remaining local control
branches as the dominant worst-path family.

## Root cause 3: HBM destination-write ready traverses the pair and bank arbiter

The final DCP reveals an additional independent failing path; see
`worst_u_dma_engine.rpt`:

```text
HBM channel 0 out_off[3]
  -> remaining-byte / write request generation
  -> TMEM bank 0 request and arbitration
  -> pair adapter req_all_done / upstream req_ready
  -> HBM DMA slot_release_fire / wr_slot_read_fire
  -> slot_state_r[5][1] CE
```

Slack is **-1.321 ns**, data-path delay **10.756 ns**, 28 logic levels,
2.643 ns logic and 8.113 ns routing (75.4%). It starts and ends in the HBM
engine but **passes through the bank arbiter and pair adapter**. Endpoint-only
classification must not be interpreted as proof that the pair is off-path.

The key RTL choices are:

- `VX_dma_unit_align.sv:1103`: the request elastic buffers hold **read control
  only**, not destination writes. Lines 1142 onward route write ready directly
  from the bus; line 1209 uses it in `dst_req_fire`.
- `VX_tmem_dma_pair_adapter.sv:48`: the 64 B request splits directly into two
  32 B bank requests. Lines 72-74 return readiness only when both halves have
  physically accepted, retaining a two-bit partial-accept mask.
- `VX_dma_unit_align.sv:1505`: destination acceptance releases the current
  response slot and can permit the next response RAM read in the same cycle.

There is no general reorder network here. The width split itself remains
simple, but zero-buffer physical acceptance couples the DMA to bank arbitration
and back again. A properly accounted write/skid stage or decoupled RAM-output
ownership is a relevant timing fix; rebuilding this as a general split/reorder
fabric is not required by this evidence. If acknowledgment moves to an ingress
buffer, completion must still wait for both physical bank writes, and payload
storage must stay owned until the buffered write is safe to release.

## Physical effects: placement density amplifies long control paths

From `bin/impl_1_full_util_routed.rpt`:

- Device-wide CLB LUT use: 498314 / 1303680 = 38.22%.
- Device-wide occupied CLB sites: 97980 / 162960 = 60.13%.
- Occupied CLB sites by SLR: **91.48% / 76.04% / 12.29%** for SLR0/1/2.
- SLR0 LUT use is 59.57%, BRAM tile use 53.35%, URAM use 30.00%.

These are distinct metrics: 91.48% CLB site occupancy is not 91.48% LUT
capacity. There is unused device capacity, but it is not evenly distributed.

Post-place congestion still contains level-6 windows around the TMEM/HMSS
region, for example North Long `(CLEL_R_X56Y31,CLEL_R_X86Y94)` and West Long
`(CLEL_R_X42Y10,CLEM_X73Y73)`. However, the **post-route QoR assessment marks
Congestion OK, score 5**, while Timing is score 2. Do not equate historical
placer congestion with an unresolved routing failure, or infer that routing
delay percentage alone proves congestion caused the entire violation.

The evidence supports long unregistered control chains aggravated by physical
placement/routing; it does not support a blanket redesign of the HBM bus or
pair adapter as the first fix.

## Recommended fix order (not implemented)

1. Put S/Z writer fence visibility on a registered consume boundary, as weight
   already does. Review the independent same-cycle S/Z `req_ready` release
   bypass too: cutting consume counter forwarding alone leaves this second
   route from compute into the DMA queue.
2. Add proper registered command acceptance for local DMA; failures are
   confirmed in all five local engines. Also consider a common registered
   completion/dependency boundary upstream. Buffer the whole command
   and ownership/tag metadata, and return readiness from buffer acceptance.
   Do not delay only `start` while leaving command or accounting live.
3. Decouple sink ready from next-slot BRAM read selection in the stream queue.
   A prefetch/output elastic stage or precomputed next-slot eligibility can
   preserve throughput. A naive register may create an every-other-cycle
   refill bubble; evaluate that tradeoff separately from correctness.
4. Cut the HBM destination-write ready round trip through the pair/bank
   arbiter. Preserve two-bank acceptance and completion semantics; account for
   any buffered pending write. Keep the fixed pair topology and assess the
   cost of a payload skid stage versus retaining RAM-output ownership.
5. Recheck all remaining endpoint classes, then consider local replication,
   hierarchy placement, and HBM descriptor fanout reduction where measured.

Keep HBM DMA at 64 B and TMEM/local DMA at 32 B for these fixes. No timing
exception or multicycle constraint is justified for the observed functional
same-cycle handshakes. No claim is made that any single proposed cut alone
guarantees 100 MHz; that requires implementation and routed timing evidence.
