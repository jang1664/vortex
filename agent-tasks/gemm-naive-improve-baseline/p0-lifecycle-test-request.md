# P0 lifecycle regression test request

- Test type: new blackbox regression application.
- App: `fpint_gemm_lifecycle`.
- Simulator: xrt-vcs-sim via `ci/run_black.sh` from configured builds.
- Backends: source `agent-tasks/fpint-gemm-latency-compare/improve.sh` or
  `agent-tasks/fpint-gemm-latency-compare/naive.sh` from the source root first.
- Parameters: no application arguments; fixed M3/K64/N64, QBLK32, QCOL,
  WTRANS0, three tagged generations, one node, one `vx_start`.
- Observation define: `-DGEMM_LATENCY_OBSERVER`; preserve all baseline settings.
- Compiler: `/usr/bin/gcc` and `/usr/bin/g++` for host compilation.
- Modified sources: only new `tests/regression/fpint_gemm_lifecycle/` files.
- Required result: host `TEST PASSED`, six ordered lifecycle markers, actual
  controller observer job IDs 0/1/2 in the same epoch, with no intervening reset
  in FSDB. Confirm each `LIFECYCLE_VERIFIED` precedes the next descriptor start.
- Stop condition: any device compare failure stops subsequent descriptor
  submission. Host requires completed=3 and checks every generation's outputs.
- Evidence scope: repeated idle-to-active operation without reset, with fresh
  A/W/S/Z and poisoned separate external outputs. Existing production scratch
  buffers are reused; no extra LMEM allocation or RTL change.

Implementation directly includes the existing backend descriptor helper. It
does not copy or replace that helper and does not touch either production app.
Host references use the existing shared test-vector oracle and physical weight
decoder. A device comparison after the descriptor completion uses ordinary
loads plus a memory fence, with no retry loop. A visibility failure is reported,
not converted into a delayed successful read. Physical HBM completion remains a
separate gate even if these coherent device reads succeed.

Preparation validation completed:

- Both backend host translation units pass `/usr/bin/g++ -fsyntax-only` with
  their sourced configurations and corresponding generated VX_config.h.
- Both backend kernel translation units compile to RISC-V object files using
  the configured build's compiler flags and LP64F profile. Logs are
  `p0-verification/lifecycle-improve-compile.log` and
  `p0-verification/lifecycle-naive-compile.log`.
- Initial kernel object compilation exposed the production conditional print
  header; adding `vx_print.h` to the new wrapper fixed that error. The remaining
  warning is the unused link-only `-nostartfiles` option during object compile.
- The original printf-only app passed both blackboxes with epoch 1 and jobs
  0/1/2, but its six device UART messages were absent from the captured logs.
  The updated durable timestamp variant requires a fresh run on both backends.

The parent agent owns full blackbox execution, waveform inspection, and STATUS
updates. This directed foundation does not cover QROW, MXU32, multi-node jobs,
large shapes, active resets, or performance gates.


## Rerun request: durable device trace

The same command/configuration now returns `start_cycles[3]` and
`verified_cycles[3]` written by the device into its argument buffer. The host
prints six `LIFECYCLE_START`/`LIFECYCLE_VERIFIED` records with `device_cycle` and
fails unless all starts are nonzero and `start[j] < verified[j] < start[j+1]`.
The six numbers come from RV64 MCYCLE reads with compiler memory barriers,
recorded before the existing descriptor helper and after all output comparisons.
They are core cycle counts, not GEMM observer edge indices. No additional
waiting, retry, or kernel launch was added; device printf calls were removed.

Required rerun evidence remains host PASS plus same-epoch actual-node observer
jobs 0/1/2 and FSDB reset continuity. Additionally retain the six host-printed
device timestamps and their checked strict ordering. Both host syntax checks
and both kernel object compiles pass after this update; logs are
`p0-verification/lifecycle-{improve,naive}-trace-compile.log`.

Missing marker diagnosis is bounded: captured logs contain the host PASS but
no original device markers, while production `vx_printf` uses `vx_serial` and
memory-mapped `vx_putchar`. The precise UART transport/capture fault was not
proven. This change makes order evidence independent of that path without
changing production RTL, production kernels, or the descriptor helper.
