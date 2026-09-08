# Cycle-counter boundaries (2026-09-08 22:50 KST)

The reported cycle value is a device-side CSR snapshot, not elapsed host time
to AP_IDLE and not a counter sampled live by the host after completion.

## RTL and binary evidence

- Archived `VX_schedule.sv:146` clears `cycles` on core reset. Lines170-171
  increment it only while `busy`. Lines248-258 register busy from active warps
  or pending instructions. Startup stalls while a warp is active are counted;
  reset cycles and an inactive scheduler are not.
- Archived `VX_csr_data.sv:143` maps CSR0xB00 to scheduler cycles; 0xB02 maps
  retired instructions. The same archived module is used by reference VCS.
- The hardware and VCS `kernel.elf` hashes match:
  `445fd7921a633204693b5b8f79161c24acedf8baf212f580e697fd0f75c05846`.
  Actual disassembly is `build_hbm_reference/reference_counter_disassembly.log`.
- `_Exit` calls `vx_perf_dump` before exit-code store, fence and warp disable.
  In that binary, linked address0x800007f0 reads mcycle and0x800007f4 stores
  the result. Subsequent instructions read minstret and other counters.
  These are linked ELF addresses, not an assertion about relocated runtime PCs.
- `kernel/src/vx_perf.c` saves CSR0xB00 at IO_MPM_ADDR. Runtime
  `runtime/xrt/vortex.cpp:1110` downloads/caches that saved memory; it does not
  substitute host timestamps. `runtime/stub/utils.cpp:295` reads those values
  and reports the maximum core cycle count (this candidate has one core).

## Interpretation

Included: active-core startup register/TLS initialization, BSS memset,
constructors if enabled, application execution, exit path through the first
mcycle read, and all instruction/data stalls before that snapshot.

Excluded from the saved value: the cycle-value store itself, subsequent
performance dump stores, final fence/drain/warp shutdown after the read,
host AP_IDLE polling delay, BO download time and VCS process wall time.
Cycle and instruction snapshots are sequential, not atomic; do not treat their
ratio as an exactly simultaneous hardware event measurement.

This rules out simply adding host polling time to explain the observed
~1500-cycle poll-only difference. It does not prove host traffic cannot
indirectly contend with execution, or prove cache/startup stalls explain the
whole difference. Hardware and model final-drain behavior still matters for
correctness even though post-snapshot drain time is outside this cycle metric.

The archived CSR decoder has no detailed cache/stall performance cases: its
0xB03-and-up range reaches the default handling. Enabling a host profiling
option cannot add the omitted hardware counters. Do not synthesize new RTL
to obtain them under this task. Further attribution can use a separate
software-only diagnostic binary with phase CSR snapshots on the same xclbin,
paired with VCS observations; keep such results distinct from the unchanged
benchmark binary and from final held-out acceptance results.
