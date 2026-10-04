# Inflight write-depth experiment fixtures

Production default depth remains 16. Append `-DAXI_WRITE_PENDING_SIZE=N` to the
sourced hardware configuration for an adapter default override. Explicit module
parameter overrides continue to take precedence.

`axi_write_depth_monitor.sv` is simulation-only bind instrumentation. Add it to
the VCS source list; never to production synthesis. Final `RAW_DEPTH_STATS` lines
include depth, instance path, AW/B counts, maximum and summed occupancy, full
time, slot-unavailable time, and read scan/wait activity. Counters accumulate
active cycles across resets. `slot_unavailable_cycles` is **not** write-demand
stall time: a helper does not receive an upstream write-demand signal. Circular
allocation can leave its next slot unavailable while other slots are free.

`tb_write_depth_sweep.sv` reuses `axi_adapter_case` and its request/data/address,
AW/W pairing, credit bound and full-drain checks. Eight concurrent cases have one
physical HBM port, depth 16/32/64/128/129/130/256/512, and 2048 continuous writes each.
B becomes eligible after 128 model cycles from paired AW/W acceptance, with at
most one B per cycle. AWREADY/WREADY remain high. This deliberately removes
unrelated memory stalls so the occupancy limit determines throughput.

`WRITE_DEPTH_BENCH` reports a fixed 1024-cycle window (cycles 513 through 1536),
AW/W and input acceptance counts, maximum occupancy, full cycles and actual
cache-request backpressure under continuous write demand. Calculate write
throughput as `window_aw / window_cycles`; multiply by 64 for bytes/cycle.
Large depths must sustain one write per cycle in the measurement window; small
depths must reach capacity. Every case checks all 2048 writes and their B drain.
The AXI handshake edge after B eligibility and conservative slot reuse add
small control latency beyond the nominal 128-cycle model parameter. Depths 129
and 130 probe the boundary between the 128- and 256-entry results; non-power-of-two
table depths are supported. Saturation here is specific to this synthetic
128-cycle B-latency stream, not a generally optimal hardware table size.

From the repository root, after sourcing the intended `configs/` file, create
the unittest subdirectory in an already configured independent build and copy
this Makefile into it. Do not reconfigure a build with experiment-specific VCS
Makefile changes. Then invoke:

```sh
python tools/verify_rtl.py unittest --path build_axi_raw_port/hw/unittest/axi_write_depth_sweep --sim vcs
```

The existing adapter regression should also pass:

```sh
python tools/verify_rtl.py unittest --path build_axi_raw_port/hw/unittest/axi_adapter --sim vcs
```

The synthetic stream measures an adapter write-pressure limit. It does not
predict end-to-end softmax latency or physical memory bandwidth.
