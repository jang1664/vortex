# MMIO Stall Analysis — Empirical Results

Source: `build/sim/xrtsim_vcs/vcs_cosim.fsdb`
Window: 78 µs … 1280 µs (covers full GEMM-occupied period of `fpint_gemm_ffn_hw_improve`)
Clock: 100 MHz (period = 10 ns = 10000 ps)

Run:
```
PYTHONPATH=tools python3 tools/mmio_analysis/analyze_mmio_stall.py \
    --fsdb build/sim/xrtsim_vcs/vcs_cosim.fsdb --bt 78us --et 1280us
```

## TL;DR — the prior RTL-stall hypothesis was wrong

Previous static-RTL analysis claimed MMIO stores to the GEMM stream port stall
4–10 cycles each because of `rsp_holding`, the 4-deep parent queue, or
`occupied_q` gating. **The waveform shows none of that fires in this workload.**

| Metric | Value | Interpretation |
|---|---:|---|
| MMIO write transactions | 1020 | every `stream_send` |
| MMIO read transactions  | 2 | `mmio_read32` calls |
| **MMIO wait cycles (valid→ready)** | **0 cyc for all 1022 (100%)** | LSU never blocked on the MMIO path |
| **Stall ratio (valid && !ready) / valid** | **0.0 %** | the GEMM frontend always accepts in 1 cycle |
| due to `rsp_holding=1` | 0 cyc | never gated |
| due to `occupied_q=0` | 0 cyc | never unallocated |
| LSU mem path stall ratio (for comparison) | 4.7 % | the *cached* path actually stalls more |

The MMIO control interface is the **least** congested path the LSU has.

## What the 4–10 cycle gaps actually are

The gap distribution between consecutive accepted MMIO writes (kernel's natural
issue cadence):

```
 2cyc |   24
 7cyc |   60   ←┐ dominant short-gap modes
10cyc |   63   ←┘
16cyc |   59
26cyc |   79
... long tails for sync points
```

Mean 117 cyc, median 66 cyc — but the modal short gaps are 7 / 10 / 16 cyc,
which exactly match the "4–10 cycle stall between activations" the user
observed at the scheduler.

A direct waveform sample at 104.6 µs:

```
104.645 µs  req_valid 0→1    (store accepted same cycle, req_ready already 1)
104.655 µs  req_valid 1→0
104.785 µs  req_valid 0→1    13-cycle gap
104.795 µs  req_valid 1→0
104.835 µs  req_valid 0→1    4-cycle gap
104.845 µs  req_valid 1→0
```

`req_ready` stays high throughout. There is no MMIO backpressure. Every gap
is **filled by RISC-V instructions on the warp** (address arithmetic, loads
from `arg`, branches, scoreboard waits on the loaded value, etc.) before the
next `stream_send` can issue.

## Why writes show ~57k-cycle "rsp latency"

The `MMIO write rsp latency` mean of ~57k cycles is **not** an LSU stall —
it is the GEMM frontend deferring the *acknowledgement* until the work is
done (especially for `make_wait` semantics, which only return when their
target counter is reached). The LSU does not wait for these responses to
issue more stores: writes are posted, as evidenced by req_ready remaining
high and 1020 stores all accepted at 0 wait cycles.

## Conclusion

The 4–10 cycle "scheduler stalls" the user reports are **not caused by MMIO
backpressure**. The MMIO path is fully one-cycle-accept. The gaps are entirely
the cost of running scalar control code (a single thread on a SIMT pipeline)
between MMIO stores: a few RISC-V ops per `stream_send`, each occupying the
sole issue slot with no second warp to swap in.

This validates the earlier intuition: the bottleneck is **single-thread
throughput on a SIMT pipeline**, not the GEMM frontend handshake. Therefore:

- Adding posted-write FIFOs / removing `rsp_holding` will not help — they are
  already non-issues in this workload.
- The right fix is in the warp-issue path: scalar/uniform co-issue (GCN-style
  scalar unit), 1-thread CPU-mode (SIMT-X-style), or restructuring the kernel
  to spawn multiple producer warps so the scheduler has eligible warps to
  cover the inter-store RISC-V instructions.

## Method

Signals captured per ~1.2 ms window:

- `core/gemm_ctrl_if[0]/req_valid`, `req_ready`, `rsp_valid`, `rsp_ready`,
  `req_data.rw` — the LSU↔GEMM-frontend handshake
- `core/gemm_node/u_gemm_job_frontend/rsp_holding`, `occupied_q` — the gating
  signals named in the static analysis
- `core/lsu_mem_if[0]/req_valid`, `req_ready`, `rsp_valid`, `rsp_ready` —
  baseline cached-LSU path

Per accepted transaction we record `valid_rise → req_accept` (wait),
`req_accept → rsp_done` (response), and `accept → next accept` (gap). Stall
attribution sums simulation time where `req_valid && !req_ready` is true and
splits it by the state of `rsp_holding` / `occupied_q`.

The script is `tools/mmio_analysis/analyze_mmio_stall.py`. It uses the
`fsdb_cli` Python API (`fsdb.events`, `fsdb.first_high_window`, etc.) so it
works directly off the FSDB without manual `fsdbreport` invocations.
