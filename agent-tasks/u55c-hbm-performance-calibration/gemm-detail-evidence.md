# Descriptor versus completion-wait diagnostic

2026-09-08, single paired exploratory run. Existing xclbin only; no RTL changes.
`gemm_detail/phase_kernel.cpp` is a diagnostic copy of the original kernel with
29 inserted lines and one renamed main declaration. The additions capture
cycles before/after `program_job_regs`, after `wait_job_done`, and around main.
Original kernel SHA256:
`403c9501e5a9eb216ec6480c68f2edb8aa5581aa6968ea2b566be0d1d0105ff8`.
The original host/data generation/output verification is included unchanged;
argument trailer allocation/readback is diagnostic-only. Intended scope is
one core and one iteration, not a general multi-job trace collector.

Both builds produced identical host and device binaries:

- host: `5139a9cf4c9d125b995855296e417625009c505b4f9a02efc4f63bdc5f3c2375`
- kernel: `f7af63637592ee9b4d15dd58c56146d9adee028bb24b93595572c05045c36746`

Args `-m 16 -n 16 -k 4096 -q 32 -r 1`; both output checks PASS.

| Measured interval, cycles | Document VCS | U55C job4915 | HW minus VCS |
| --- | ---: | ---: | ---: |
| Entry snapshot | 2673 | 4083 | 1410 |
| Entry to descriptor programming | 2507 | 2616 | 109 |
| Descriptor programming | 1008 | 1046 | 38 |
| After programming to completion observed | 4339 | 8039 | 3700 |
| Completion observed to main return snapshot | 456 | 481 | 25 |
| Return snapshot to reported mcycle | 775 | 841 | 66 |
| Total reported cycles | 11758 | 17106 | 5348 |

Absolute before-program/after-program/after-wait snapshots:
VCS5180/6188/10527, hardware6699/7745/15784. Return snapshots10983/16265.
Most of the additional in-main difference is in the completion-wait interval,
not descriptor setup. This interval includes overlapped DMA and compute plus
software polling and completion observation; it is **not** isolated HBM time.
`program_job_regs` ends with the CONTROL start store. Compiler memory barriers
bound source-level placement but add no device completion fence, so the sample
after programming is not a proven hardware AXI start-acceptance timestamp.

The diagnostics add instructions/register pressure and trailing stores; total
cycles differ from the original benchmark and prior diagnostic. These intervals
cannot be subtracted from the original benchmark as calibrated correction terms.
One sample per side does not establish variability; repeat before relying on
fine-grained differences. Post-report confirms candidate UUID, HEALTHY and
DATA100/HBM450MHz; no continuous throttling evidence.

Evidence:

- `build_hbm_reference_document/gemm_detail_document_k4096_1{,_simv}.log`
- `build_hbm_reference_document/gemm_detail_document_k4096_1_before.sha256`
- `build_hbm_hardware_reference/hardware-smoke-4915/gemmdetailk4096.log`
- `build_hbm_hardware_reference/hardware-smoke-4915/after.json`

Build54247, VCS87496 and hardware31427 are terminal. Clean original reference
launch links restored. No model parameters changed. Next narrow the wait gap
using simulation-side DMA/compute overlap/traffic evidence, and inspect which
existing hardware progress fields can provide a corresponding observation
without adding hardware counters or changing the xclbin.
