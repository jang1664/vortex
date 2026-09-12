## Follow-up: why the prefetched read buffer does not prevent the stall

The current naive prefetch allocator only runs on the exact GEMM input-accept
cycle (`prefetch_alloc = txn_accept_valid && txn_accept_rd_en && ...`). If no
slot is available then, that transaction is not queued for a later prefetch
retry. It waits until its normal read demand reaches postprocessing. A later
transaction can consequently obtain prefetch storage before an earlier skipped
transaction. See VX_gemm_acc_lmem.sv:190.

The eight read slots hold both pending reads and returned data. A returned
prefetch remains in its slot until the matching normal demand is accepted and
the core consumes the response. Data for a later work tag cannot satisfy the
current request. A speculative reservation leaves capacity for late demands
to ensure progress, but does not guarantee continuous throughput.

A tagged FSDB example makes the gap explicit. Cycles below are relative to the
accepted configuration of naive M256; the requested transaction tag is 9993.

| Cycle | Event |
|---:|---|
| 50,053 | Input9993 accepted. Eight read slots occupied; prefetch_alloc=0. |
| 50,103 | Core requests partial sum9993. No matching slot and no free slot; ready=0. |
| 50,103–50,122 | Request9993 waits20 cycles. Later tags9999–10003 already occupy five slots; some data has returned. |
| 50,123 | A slot becomes available; late_read_alloc=1 accepts request9993. |
| 50,142 | Core accepts the response for9993,19 cycles after demand acceptance. |

Thus the core waits39 cycles after first requesting9993, although its input was
accepted50 cycles before the request. The implementation failed to use that
advance notice for this transaction. At50,123, completed data for9999,10000 and
10001 is waiting for their later demands; none can substitute for9993.

This identifies a limitation of the current one-shot speculative allocation
and slot-retention policy, not an inherent requirement of LMEM. Scheduling
missed prefetches in work order when capacity becomes available is a concrete
follow-up design direction; no RTL change or performance claim for such a
change is made here. Increasing a FIFO alone has not been evaluated.

Evidence: `agent-tasks/fpint-gemm-shape-gap/prefetch_detail.py` and local
`captures/naive256/prefetch/result.json` (per-slot work tags and completion/demand
bits, input admission, read admission and response handshakes).
