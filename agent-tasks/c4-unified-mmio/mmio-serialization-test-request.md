# Scalar MMIO verification request

Use the task's C4 SRAM-fusion config and a configured XLEN=64 build directory.
Reconfigure after adding the new unittest and regression directories. Source
the config before builds. Use `/usr/bin/gcc` and `/usr/bin/g++` for unit host
compilation. The unit Makefile explicitly defines `XLEN_64`; the configured
build's XLEN does not otherwise propagate into this standalone VCS command.

## Directed unit

Run from the configured build's `hw/unittest/mmio_serializer`:

```sh
make compile
make run
```

Require `TEST PASSED scalar MMIO`, no fatal/assertion, and successful process exit.
The chain includes the serializer, the existing scalar SLR transport, and the
ordinary GEMM frontend/register bank. Check all four sparse-lane allocations,
all 16 descriptor writes/reads, byte-enable preservation, deterministic shared
register ordering, delayed publication response, completion-error lifetime,
and reset recovery. Preserve any failure logs and report the first failure.

## Real LSU integration

Run from the configured build using the required wrapper:

```sh
ci/run_black.sh xrt-vcs-sim --app mmio_serialization
```

Require `PASSED`, `MMIO_SERIALIZATION ... errors=0`, all expected descriptor
slots allocated exactly once, and no RTL assertion. This app intentionally
issues one 16-lane warp. It does not launch malformed GEMM jobs: CONTROL remains
invalid while ordinary descriptor words, global allocation, capability, and
publication are exercised. Report the measured kernel cycle count. This app
is a correctness workload for the new ABI; compare application latency using
the separate frozen-baseline workloads requested by the parent task.
