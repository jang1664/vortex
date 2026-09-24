# Output double-buffering verification evidence

The authoritative full-flow waveform is
`vcs_cosim_stall_final_m1_n288_k160.fsdb`. It was produced by a configured
WLOAD8 `xrt-vcs-sim` run with M/N edge tiles, multiple K tiles, three output
tiles, and 70/30 Markov request/response stalls. The host numerical check
passed; see `simv_stall_final_m1_n288_k160.log` and `fsdb_metrics.json`.

Key FSDB observations:

- MXU active: 720 cycles; ACC2LMEM active: 99 cycles; overlap: 44 cycles
  (`44.444%` of ACC drain hidden by MXU).
- DMA_ST active: 1020 cycles; MXU/DMA_ST overlap: 315 cycles (`30.882%`).
  This is an observation only and does not remove the known single-global-DMA
  serialization of an output store versus a following input load.
- Different-group output-read opportunities/accepts: `5/5` cycles.
- Same-group accepted accesses: `0`; same-group conflict attempts in this
  natural schedule: `0`. Directed unit tests separately exercise blocking at
  every compute pipeline stage.
- Exact dependency waits: `RID_ACC_FREE=0` cycles in this schedule and
  `RID_O=262` cycles. The zero ACC wait is expected here because the previous
  group drain completed before reuse; the directed controller test proves the
  delayed-completion blocking and same-cycle bypass cases.
- At 81.875 us, before invocation counters reset, `RID_O=9` equals nine
  issued DMA_ST commands, both ACC release counters equal their issue counts
  (`{5,4}`), all child command/inflight queues are empty, and compute busy is
  zero.

Reproduce the extraction from the repository root with:

```bash
PYTHONPATH=tools /usr/bin/python3 \
  agent-tasks/gemm-output-double-buffering/analyze_output_dbuf_fsdb.py \
  agent-tasks/gemm-output-double-buffering/evidence/vcs_cosim_stall_final_m1_n288_k160.fsdb
```
