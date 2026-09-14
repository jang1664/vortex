# Current naive M256 Input / PSUM root cause

Analysis of the existing single-cycle-Input-issue experiment; no RTL or configuration changes. M=256, K=N=512, TH16, MXU16. Current naive GEMM: 606,387 cycles. This is the modified Input issuer run, not the historical 576,763-cycle baseline.

## Evidence and cycle convention

- FSDB: `agent-tasks/naive-input-single-cycle-issue/runs/v1/m256/wave.fsdb`.
- Extracted with `tools/fsdb_cli.py` through `fsdb_cli.report`.
- Artifacts: [summary](../../../agent-tasks/naive-psum-root-cause/summary.json), [tagged window](../../../agent-tasks/naive-psum-root-cause/stall-window.csv), [signal paths](../../../agent-tasks/naive-psum-root-cause/window-paths.json).
- C denotes the absolute simulator cycle: rising edge at C * 10 ns + 5 ns. Values are sampled immediately before that edge. Intervals are half-open unless stated otherwise.
- Whole GEMM window: [21191, 627578). Input stream analysis: [22773, 626847), excluding the final Input handshake.
- Packed bank ready/rw fields contain unknown bits on invalid banks. The analysis checks that every bit counted on a valid request is known; invalid bits are excluded.

## Causal chain

There are two distinct Input limitations, coupled by the shared LMEM fabric:

1. Input data cannot reach the compute unit quickly because its LMEM request ports are shared with accumulator writes.
2. When Input data is already valid, delayed PSUM reads can prevent the accumulator from consuming completed compute results. The four-entry post-processing transaction queue fills, result/compute credits stop returning, and backpressure reaches Input.

The physical memory banks are not globally saturated. The more specific causes are serialization at shared ingress ports, bank arbitration that allows ordinary Input reads to precede PSUM reads, and waiting for all lanes of a PSUM response. PSUM write completion itself is not the dominant direct dependency blocker in this capture.

## Input ready: follow the dependency backwards

Input has valid data but ready=0 for 120,031 cycles in the Input stream window. During those cycles, the post-processing transaction queue has no space for 94,033 cycles; compute tree credit is unavailable for 119,915 cycles. These predicates overlap and must not be summed as independent lost-cycle components.

The RTL chain is:

- [Input ready, VX_gemm_compute_core.sv:632](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L632): admission and Input pipeline readiness must both hold.
- [Compute ready:1770](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1770): requires a tree credit or returned credit, plus operand readiness.
- [Credit return:1805](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1805) and [merged FIFO pop:1849](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1849): credits return when downstream consumes the merged result.
- [Result acceptance:1961](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1961): requires `post_txn_space`; [space:2176](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L2176) depends on queue occupancy.
- [Head PSUM availability:2246](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L2246) and [post launch:2261](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L2261): a completed scaled compute value cannot advance without its own PSUM.

This is downstream backpressure. Separately, the stream has 221,900 cycles without valid Input data, so PSUM-induced ready stalls do not explain every missing Input handshake.

## A transaction-specific example

Transaction 32249, PSUM byte address 8,585,891,392, logical read slot 1 and physical join slot 1:

| Absolute cycle | FSDB observation | Meaning |
|---|---|---|
| 96547 | `rd_lmem_fire=1`, transaction=32249; join allocates slot 1 | Read has been submitted |
| 96548 | join issue slot=1, lane request fire mask=0xff | All eight lane requests accepted together |
| 96557 | response tag=1 accepted on lanes 0–3 | First half of PSUM returned |
| 96576 | post head tag=32249, PSUM ready=0 | This read is now needed by the accumulator |
| 96577–96601 inclusive | post count=4, head PSUM ready=0 | Full downstream queue waits for this PSUM |
| 96592 | response tag=1 accepted on lanes 4–6 | Most of the remaining data returns |
| 96600 | response tag=1 accepted on lane 7 | Last required lane finally returns |
| 96601 | wide response accepted, logical slot=1 | Adapter receives the assembled PSUM, 54 cycles after read acceptance |
| 96602 | core response tag=32249, head PSUM ready=1, post launch=1 | Accumulator resumes |
| 96604 | Input valid=1, ready=1 | Input acceptance resumes after credit propagation |

Input valid=1/ready=0 throughout C96578–96603 inclusive. The physical lane response tags are six bits each. Lane requests carry word addresses 1,073,236,424 through 1,073,236,431, mapping to banks 8–15.

[Join request and response tagging:147](../../../hw/rtl/core/gemm/VX_gemm_psum_read_ooo_join.sv#L147), [independent lane response capture:174](../../../hw/rtl/core/gemm/VX_gemm_psum_read_ooo_join.sv#L174).

This example is not delayed by waiting to issue the other lanes: all requests already handshook at C96548. Allowing a lane to issue the next row earlier cannot directly remove this already-issued request's downstream service delay.

## Why PSUM read completion is delayed

All 253,952 prefetch reservations were accepted by the read join exactly one cycle later. Adapter-to-join request backpressure was zero. Acceptance-to-assembled-response latency was min 11, median 14, mean 18.78, p90 29, p99 39, max 54 cycles. Thus the extra delay is after prefetch submission, not a skipped prefetch.

The bank arbiter's current read-priority rule only excludes classified PSUM writes when PSUM reads wait, subject to the write quota. It does not exclude ordinary requests. The selection loop examines low-index roots first.

- [Hierarchy and slice grouping, VX_local_mem.sv:824](../../../hw/rtl/mem/VX_local_mem.sv#L824): lower slice contains ports 0–7; upper slice contains ports 8–15 in this configuration.
- [Root selection:872](../../../hw/rtl/mem/VX_local_mem.sv#L872): ordinary traffic has neither PSUM read nor PSUM write classification, so it remains eligible ahead of the upper PSUM-read slice.
- C96551–96559 and C96564–96585: bank 12 has a pending upper-slice PSUM read, but grants lower-slice ordinary traffic from physical port 0. This is in the tagged stall window above. Root grants here are class/port evidence; the root payload tag was not extracted, so these grants are not individually attributed to transaction 32249.

Whole-run bank-root evidence:

| Bank | Cycles PSUM read waits at root | Ordinary request wins | PSUM write wins | No grant |
|---|---:|---:|---:|---:|
| 0 | 51,681 | 43,284 | 8,397 | 0 |
| 8 | 43,038 | 37,468 | 5,570 | 0 |

The increased Input issue rate can therefore delay PSUM reads by keeping ordinary requests eligible. This explains a mechanism for the observed regression; these overlapping arbitration counts are not a cycle-exact attribution of the entire 29,624-cycle regression.

## Why writes also matter even when write completion is not the direct blocker

[Input lane mapping, VX_gemm_node_naive.sv:84](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv#L84) places Input lanes on ports 0–3. [VX_mem_unit.sv:225](../../../hw/rtl/core/VX_mem_unit.sv#L225) places accumulator write lanes on ports 0–7, and [the two-to-one priority arbiter:234](../../../hw/rtl/core/VX_mem_unit.sv#L234) merges each with ordinary traffic. Accumulator writes have priority over ordinary Input requests at this boundary. Final output writes also use this path: [VX_gemm_node_naive.sv:510](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv#L510).

A port is an entrance to the bank-routing network, not a physical bank. Two requests sharing that entrance cannot pass simultaneously even when their destination banks differ.

Measured port 0 in the full GEMM window:

| Event | Count |
|---|---:|
| Accumulator writes accepted, including final output | 262,144 |
| Ordinary requests accepted | 274,944 |
| Total output request handshakes | 537,088 |
| Ordinary valid but not ready | 232,530 |
| Above waits coincident with an accepted accumulator write | 231,182 |
| Accumulator write valid but not ready | 643 |

Input alone accounts for 262,144 of the ordinary requests per Input lane. Input plus accumulator writes therefore requires at least **524,288 port-service cycles** at each shared Input port, before other traffic. The observed port-0 utilization is **88.57%** (537,088 / 606,387).

By contrast, every physical LMEM bank services 337,408 requests, **55.64%** of GEMM cycles. Bank 0 has no valid-request/ready stall; several other banks have only tens of such cycles. The RAM's final handshake is not the main queueing point. Queueing occurs upstream in the port and bank arbiters. Single-port bank storage still limits conflicting requests, but aggregate bank capacity alone misses the tighter ingress bottleneck: [bank storage, VX_local_mem.sv:464](../../../hw/rtl/mem/VX_local_mem.sv#L464).

The 524,288 bound concerns the current request count and shared-port mapping. It is not an estimate of recoverable cycles. Under those assumptions, more outstanding slots cannot reach the improve run's 272,856 cycles merely by hiding memory latency.

## Excluded explanations and limits

In this capture, adapter RAW read suppression, PSUM read ordering suppression, write-table-full, write WAW blocking and write WAR blocking each count zero. Adapter write request backpressure exists (10,329 cycles), but read request backpressure is zero. Physical response ready backpressure is also zero. The read join is issuing a row without all lane handshakes for 120,794 cycles, whereas transaction 32249 illustrates additional delay after all lane handshakes.

More response slots may hide some tail latency. Independent lane issue may avoid the current row issue barrier. Neither changes the shared ingress service limit or automatically fixes ordinary-before-PSUM-read arbitration. This analysis establishes the current bottlenecks; it does not claim an unmeasured optimized speedup.

The causal interpretation is therefore: accumulator writes consume the same ingress capacity as Input; ordinary Input requests can in turn postpone PSUM reads at bank arbitration; delayed PSUM responses fill downstream queues and stop Input through returned-credit backpressure. Treating this only as slow external DMA, insufficient response slots, or globally saturated LMEM banks would miss the actual structural constraints.
