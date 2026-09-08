# AXI reads in the long-K controller window

2026-09-09, one standard-binary replay with non-driving controller and AXI
observers in isolated `archived-document-work-bus-trace`. Output PASS and
11394 cycles/6577 instructions match observer-free guarded-add. Before/after
hash checks pass. No RTL/model parameter change or hardware run this step.

`inspect_work_bus.py` pairs requests by port/ID in AXI ordering, checks burst
length/RLAST and rejects malformed/unknown events, orphan responses, time
reversal and outstanding reads at trace end. Controller event validation is
reused. Five synthetic bus tests pass. Both observer caps were not reached;
the controller's1287 events remain complete, and no observer fatal occurred.

The full trace pairs1881 reads. Within the controller start-to-done window:

-1665 AR requests:1024 two-beat bursts and641 one-beat bursts.
-2689 R beats accepted: ports0/1 each384, ports2/3/4/6/7 each320, port5 has321.
-AR counts by port:0/1 each256,2/3/4/6/7 each192, port5 has193.
-AR-to-first-R latency: min180ns, median180ns, max190ns.
-Union of read-outstanding intervals clipped to the controller window:29.94us.

These observations show this workload uses short bursts rather than a single
long saturated stream. Thus passing long-burst peak bandwidth tests alone does
not establish its timing fidelity. They do not prove that physical HBM latency
is the hardware gap's cause. The measured AXI delay includes model timing,
CDC and publication effects; the29.94us outstanding union overlaps execution
and is not a stall total. Reads can include core traffic during the invocation.
No write-channel analysis, hardware AXI trace, or source-readiness correlation
has been completed by this report. Do not claim a hardware bandwidth measurement.

Evidence:

- `work-bus-results.json`: paired reads, controller checks, per-port counts.
- `build_hbm_reference_document/work_bus_longk_1{,_simv}.log`
- `build_hbm_reference_document/work_bus_longk_1_before.sha256`
- `build_hbm_reference/sim/xrtsim_vcs/work_bus_trace_build.log`

Build74184/run18340 are terminal; launcher restored old clean reference links.
Next assess short-burst latency sensitivity separately from service-rate
ceilings, and correlate input readiness with reads before assigning causality
or fitting a profile. Documentation profile remains unchanged and uncalibrated.
