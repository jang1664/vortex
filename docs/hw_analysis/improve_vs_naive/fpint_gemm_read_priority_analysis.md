# Naive PSUM read priority: waveform-based assessment

> Historical proposal and baseline evidence: the recommended policy has now been implemented and measured in [the scheduler sweep](fpint_gemm_read_priority_sweep.md). The waveforms and RTL annotations below describe the pre-change baseline.

**Recommendation: prioritize eligible PSUM reads over independent PSUM writes, but replace the broad bank-set read fence as part of that change.** Merely swapping an arbiter priority or holding write-ready low while retaining the current gate does not solve the observed problem. Preserve true address dependencies and ensure writes continue to make progress.

Scope: selected naive external-DMA32 / Weight8 / PSUM16, TH16/MXU16, N-fast, M4/M256, K=N512. This is an analysis of the existing passing FSDBs, not a simulation of modified arbitration. No speedup for the proposed RTL has been measured.

## What the additional address audit found

Earlier annotations identified long bank-set ordering waits. This follow-up reconstructs the addresses of every physically pending PSUM write, rather than comparing only the current write request with the read.

| Observation | M4 | M256 |
|---|---:|---:|
| Node bank-set read-block cycles | 9,070 | 357,280 |
| Blocked read has an outstanding write to its same 64-byte row | **0** | **0** |
| No pending same-row write, but current write is to that same row | **0** | **0** |
| Block is only due to other rows in the bank set | **9,070** | **357,280** |
| Other-row block while external DMA idle | 2,898 | 330,786 |
| Other-row block coincides with PSUM-only postprocessing wait | 4,528 | 116,492 |

Thus every observed **node bank-set gate** stall concerns a physically different PSUM row in these two workloads. That is strong evidence that the gate is more conservative than these accesses require. It is not evidence that all read-after-write dependencies can be removed: the adapter separately fences reads behind older same-address transactions before they reach the node. The table is conditional on a node read being presented and blocked, not a census of all logical dependencies.

Nor are 9,070/357,280 directly removable GEMM cycles. Many requests are prefetches for later transactions; waits overlap across stages. The PSUM-only coincidence row checks that the postprocessing head has scaled data and result capacity but lacks PSUM; it does not prove that the node's current request belongs to that head. Changing arbitration also moves write timing and subsequent dependencies.

## How the address reconstruction was checked

[Audit script](../../../agent-tasks/dma-read-slot-saturation/read_priority_audit.py), [M4 evidence](../../../agent-tasks/dma-read-slot-saturation/annotations/read-priority-m4.json), [M256 evidence](../../../agent-tasks/dma-read-slot-saturation/annotations/read-priority-m256.json).

The script reads these signals directly with `fsdb_cli.report` from the selected `slots32-m4` and `slots32-m256` FSDBs:

- `CORE/gemm_node_naive/psum_rd_raw_bus_if/{req_valid,req_data.addr}`.
- `CORE/gemm_node_naive/psum_wr_raw_bus_if/{req_valid,req_ready,req_data.addr}`.
- `CORE/gemm_node_naive/psum_wr_reserve`.
- `CORE/gemm_node_naive/naive_write_commit`.
- `CORE/mem_unit/local_mem/per_bank_req_addr`.
- `CORE/gemm_node_naive/psum_wr_pending_by_set[0]` and `[1]`.

`CORE` is `/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core`.

Each PSUM row is64 bytes, split into eight8-byte lanes. A first-presented write reserves all eight lanes. Every physical PSUM bank commit removes exactly its committed word address from the reconstructed pending multiset. The reconstructed per-set lane totals match **both RTL pending counters at every cycle**:15,970 checks in M4 and671,993 in M256. The pending multiset is empty at GEMM completion. Current uncommitted write presentation is checked separately as well.

Addresses below are physical byte offsets within the1MiB LMEM, not host virtual addresses. The script masks the raw bus address to the physical LMEM address space. It checks each committed word against the reserved address multiset and bank-set decode. Sampling is strictly before the positive clock edge, with edge time `10*C+5 ns`.

RTL: [PSUM width](../../../hw/rtl/VX_config.vh:1370), [eight-lane count at MXU16](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:78), [first-presentation reservation](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:183), [physical bank address and commit decoding](../../../hw/rtl/mem/VX_local_mem.sv:136), [pending counter updates](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:603).

## Concrete review example: M256 C635,474

FSDB: `agent-tasks/dma-read-slot-saturation/runs/naive/slots32-m256/wave.fsdb`. Configuration accepted at C24,339, so C635,474 is relative C611,135 and6,354,745ns. The existing [per-cycle window](../../../agent-tasks/dma-read-slot-saturation/annotations/N256_PSUM.csv) contains ready/valid and compute signals; the [address-audit detail](../../../agent-tasks/dma-read-slot-saturation/annotations/read-priority-m256.json) adds pending row addresses.

| Access | Physical LMEM byte offset | Same bank set as the read? | Same address as the read? |
|---|---:|---|---|
| Blocked PSUM read | `0x28F80` | — | — |
| Physically pending write | `0x28E80` | Yes | **No** |
| Other physically pending write | `0x28EC0` | No | No |
| Current write request | `0x28F00` | Yes | **No** |

`psum_rd_pending_conflict=1`, raw read valid=1/ready=0, downstream read valid=0. External DMA is idle; Weight and scaled data are ready. The post head has result capacity but lacks PSUM. The conflict is bank usage/order conservatism, not an outstanding write to the read's row.

At C635,475 the node gate opens and accepts a read. A response is observed at C635,477, followed by head PSUM-ready and launch at C635,478. These are temporal observations, not a tag-matched proof that this one accepted read produces that exact head response. Read priority could allow an independent request earlier, but the changed schedule needs simulation to determine the resulting cycle saving.

M4 also has concrete other-row conflicts. At C18,758, read `0x21040` waits while pending writes include `0x2B040` and `0x2B0C0` in its bank set, with current write `0x1D040`. None is the read address. At C18,780, read `0x21080` is blocked with a pending write at `0x21000`. See [M4 address details](../../../agent-tasks/dma-read-slot-saturation/annotations/read-priority-m4.json).

## Why priority alone is insufficient

There are three distinct layers:

1. **Logical address dependency.** The adapter scans older accepted transactions for a write to the candidate read address. Those reads must remain behind the producer write, or obtain a correct forwarded value. [Exact-address fence](../../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv:198).
2. **Physically pending writes.** A transaction retires at the core/adapter write acceptance boundary, which can precede actual LMEM bank commit. Removing the broad node fence cannot rely solely on the adapter's transaction table: exact-address ordering must also remain valid through downstream queues. [Transaction retirement](../../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv:427), [write-accept/commit logic](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:2435), [physical commit](../../../hw/rtl/mem/VX_local_mem.sv:144).
3. **Bank arbitration between eligible independent accesses.** Once both accesses are safe, choosing the read first is a performance policy. Currently the broad node fence deasserts the downstream read's valid, so that read cannot compete in the arbiter at all. [Node gate](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:578).

The current TH16 mapping places eight PSUM write lanes in request slots0–7 and eight read lanes in slots8–15. [Port mapping](../../../hw/rtl/core/VX_mem_unit.sv:222). The local-memory request crossbar uses priority arbitration, with the priority encoder's default selecting low indices. [Crossbar](../../../hw/rtl/mem/VX_local_mem.sv:312), [priority encoder](../../../hw/rtl/libs/VX_priority_encoder.sv:19). The nearby slot0–15/16–31 comment describes a larger geometry; effective bounds come from `GEMM_PSUM_LANES=8` here. Reordering these ports is therefore not equivalent to fixing the node's eligibility gate.

## Write backpressure is supported, but should be bounded

The common compute core already retains results while the write interface is not ready. The LMEM adapter propagates PSUM write-ready back to that interface. A held write does not inherently lose data. [Adapter ready propagation](../../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv:365), [result queue and commit](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:2423).

Existing PSUM write valid-without-ready cycles are797 in M4 and824 in M256. In411/530 of those cycles respectively, result credit is zero and no result commits. These passing traces demonstrate supported write holding, but also show that the buffering is finite. They do not measure the pressure under a new read-first policy.

If writes are delayed indefinitely, results cannot retire and result credits eventually stop further postprocessing. Consequently, prioritize an eligible read while ensuring periodic/progress-driven write grants. Reads with an actual dependency on a pending write must allow that producer write to drain. Only not-yet-accepted work may be deferred; accepted or partially split lane transactions must be completed consistently.

There is a specific trap in a superficial implementation: `psum_wr_reserve` fires on first **valid**, not on `valid && ready`. This is intentional because a splitter may forward some lanes before all lanes are ready. If new logic blocks all forwarding of that write but still reserves it, while the read continues waiting for the reserved writes to drain, it can create a circular wait. [Reservation and held state](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:183). Arbitration/grant, partial-lane acceptance, and reservation must be designed together; simply changing `wr_ready` is insufficient.

## Suggested policy

Prefer **address-safe read priority**: keep the older-transaction fence, distinguish same-row physical pending writes from independent rows, let eligible PSUM reads compete ahead of independent writes, and preserve write progress with bounded grants. This directly targets the other-row stalls demonstrated in both FSDBs.

If exact pending-address tracking is too expensive, a more conservative alternative is to stop admitting new conflicting writes, drain the already accepted writes, then grant the waiting read before starting another write batch. It retains some unnecessary drain delay but avoids indefinite replenishment of a bank set's pending writes. This alternative still requires correct first-presentation reservation and same-address dependency handling; it is not a ready-only patch.

The current traces strongly justify trying read priority, especially at M256. They do not establish a numerical speedup or prove that unconditional read-first scheduling is optimal. Compare the modified policy using the same xrt-vcs-sim workloads, checking whole GEMM cycles along with PSUM waits, Input acceptance, write backpressure, and result-credit exhaustion. The accepted baseline and detailed prior phase annotations remain in [the review guide](fpint_gemm_annotated_explanation.md).
