# Three GEMM invocations within one kernel launch

This directed application submits M3/K64/N64, QBLK32, QCOL, WTRANS0 three times
on core/node zero. It takes no arguments. `GEMM_NAIVE` selects the LMEM backend;
otherwise it uses improve. Use the corresponding th16/MXU16 configuration.

The new host and kernel translation units include their production equivalents
with `main` renamed. The wrapper calls the original `run_gemm_job_once` helper,
including actual descriptor allocation, programming, and completion polling.
It does not change production source files, force RTL state, alter MSCRATCH
between jobs, or invoke `vx_start` more than once.

Each generation has a different A, packed W, S, Z, reference, and separate
external output buffer. A host check rejects unchanged operand families or
reference arrays. All three generations are uploaded before the single launch.
References come from the production shared `test_vectors.h` oracle, decoding
the packed weights, and remain immutable. Every output starts with FP16 NaN
poison. The jobs reuse the same production LMEM/TMEM scratch addresses.

After the original descriptor wait returns, the device fences and validates
every real output against its immutable reference. A mismatch stops submission
of subsequent jobs. The FP16 comparison uses relative tolerance 0.001 for a
nonzero reference, absolute tolerance 0.001 for zero, and rejects nonfinite
mismatches. Device reads do not poll until correct or hide stale output by
retrying. The host then checks every output again and requires all three device
verification records to have completed successfully.

The device writes RV64 MCYCLE timestamps into the returned argument buffer
immediately before each descriptor helper call and immediately after every
output passes verification. Volatile stores and compiler memory barriers retain
these records. Host validation requires `start[j] < verified[j] < start[j+1]`,
nonzero starts, and three completed jobs. It prints the durable trace after the
launch finishes; printing does not occur on the device or insert waits. These
are Vortex core cycle timestamps, not normalized GEMM clock endpoints.

Expected host trace ordering (timestamps shown symbolically):

```
LIFECYCLE_START job=0 device_cycle=S0
LIFECYCLE_VERIFIED job=0 device_cycle=V0
LIFECYCLE_START job=1 device_cycle=S1
LIFECYCLE_VERIFIED job=1 device_cycle=V1
LIFECYCLE_START job=2 device_cycle=S2
LIFECYCLE_VERIFIED job=2 device_cycle=V2
```

Run with `ci/run_black.sh xrt-vcs-sim --app fpint_gemm_lifecycle` from a freshly
configured build after sourcing the appropriate configuration from the source
root. Enable `GEMM_LATENCY_OBSERVER` for invocation identities. Archive logs and
FSDB; require the actual node's observer records to stay in the same epoch
(normally epoch 1) with invocation job IDs 0, 1, and 2. MMIO entry reuse or its
generation number alone does not prove that reset was absent.

This is a lifecycle correctness test, not a latency measurement. Device
validation introduces deliberate gaps between descriptors. It does not prove
active-work reset support, multi-node behavior, all traversal shapes, physical
HBM visibility, QROW, or local payload-fault coverage. Three successful host
launches are not a substitute for this test's single-launch evidence.

The original printf-only wrapper passed both backend blackboxes, but neither
wrapper nor simulator logs captured its six device UART messages. `vx_printf`
routes through `vx_serial` and memory-mapped `vx_putchar`, so it is not a durable
host-visible trace. The exact missing-UART transport cause has not been proven.
The returned timestamp records remove that reporting dependency.
