# Non-driving startup bus trace (2026-09-08 23:01 KST)

A fresh `archived-document-startup-trace` stage uses the same RAM exceptions,
archived DUT and guarded IP setup, plus task-local `reference_startup_observer.sv`.
The observer logs accepted AR/R handshakes, core reset release and MCYCLE CSR
read events; it does not drive DUT state. It has a fatal trace cap rather than
silently truncating read requests. No hardware job was run for this trace.

The software phase diagnostic at one poll produces exactly the observer-free
values: first snapshot2684, return3592, standard cycle snapshot4370, instrs6005.
This validates the observed timing for this run, not all observer permutations.
Temporary launch symlinks were restored to `archived-document-guarded-mul`.

Before the first snapshot:

- 182 AXI read transactions accepted (199 over the whole run).
- AR-to-first-R acceptance latency: min180ns, median180ns, max220ns.
- Core release to first snapshot:26.85us (one boundary edge beyond2684 cycles).
- Union of intervals with at least one tracked read outstanding:6.84us.
- Port7 accounts for169 startup reads; the remaining13 span ports0..6.
  ID distribution is dominated by IDs3,7,...,63. This concentration is a
  measurement, not yet a decoded attribution of every request to stack/TLS.

These latency values include AXI/model transport timing, not only DRAM.
The interval union is not CPU stall time: compute may overlap outstanding
requests, and cache/pipeline work can stall without a pending external read.
Likewise, summing per-request latencies would double-count concurrent traffic.
No matching hardware AXI trace exists, so this alone cannot assign the measured
hardware startup gap to a particular latency or switch bottleneck.

Raw host/sim logs: `build_hbm_reference_document/phase_startup_trace{,_simv}.log`.
`startup-trace-results.json` preserves paired request addresses/IDs/ports and
snapshot boundaries. `inspect_startup_trace.py` checks request-response pairing,
beat counts/RLAST, drained queues and three expected snapshots; malformed
X/control transactions remain covered by the existing DUT/AXI guards.

Next decode the concentrated startup accesses or use a separately paired
dependent-load software test to bound kernel-visible memory latency. Keep the
documentation profile frozen; do not add1500 cycles as an unexplained offset.
The requested final error tolerance is awaiting user input before held-out
acceptance evaluation; independent diagnostics and remaining verification can
continue meanwhile.
