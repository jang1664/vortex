# Long-K software phase diagnostic

2026-09-08 exploratory single paired execution; not acceptance statistics.
Task-local `gemm_phase/phase_host.cpp` includes the unchanged benchmark host,
preserving deterministic inputs and full output verification. Only the argument
buffer allocation grows by the two existing diagnostic cycle fields. Host
readback prints those fields after completion. The device program reuses
`phase_diag/phase_kernel.cpp`: snapshots surround the unchanged kernel main.
This is a different diagnostic binary/layout from the standard benchmark.

The first VCS launch failed only in diagnostic trailer readback: a non-cacheline
aligned device offset is rejected by `runtime/xrt/vortex.cpp:821`. The corrected
host reads the full extended argument structure from offset0. Original runtime,
benchmark sources and hardware RTL were not changed. Failed first-run log is
preserved, not counted as an output-verified phase sample.

Corrected host/device binaries match between configured reference and hardware
builds. Host SHA256 `7e8606c063154a39b51c23b0c660effeb0b89799a65440ee5f5907f208cb49c6`;
kernel SHA256 `817d10f3986661d484c38544b211bc2b98796f5cb0227ebfecede1ae6721af25`.
The kernel hash also matches the earlier poll-only diagnostic; here the original
host supplies actual GEMM buffers and QDIR0 instead of the poll-only sentinel.

Args: `-m 16 -n 16 -k 4096 -q 32 -r 1`. Both runs verify all outputs and pass.

| Boundary/interval (cycles) | Document VCS | Hardware job4914 | HW minus VCS |
| --- | ---: | ---: | ---: |
| First main snapshot | 2684 | 4090 | 1406 |
| Original main body | 8150 | 12190 | 4040 |
| After body to reported mcycle | 778 | 824 | 46 |
| Reported total | 11612 | 17104 | 5492 |

Return snapshots are10834 and16280. This localizes most of the extra long-K
gap inside the original main body, separately from the pre-main gap already
seen with polling. The body includes descriptor setup, DMA/GEMM execution and
software polling; it is not isolated compute or HBM time. Instruction counts
are6596 versus6902, consistent with differing polling duration but not proof of
an exact instruction-by-instruction match. One sample per side does not establish
phase variability. No latency/bandwidth fitting or arbitrary offset is justified
by this observation alone.

Hardware post-report confirms candidate UUID, DATA100/HBM450MHz, HEALTHY;
no new xclbin. VCS uses observer-free guarded-add stage and copied wrapper;
hardware uses unchanged wrapper with the `temp` alias under Slurm. Sessions
40500 and99541 are terminal. Original clean VCS links restored by launcher.

Raw evidence:

- `build_hbm_reference_document/gemm_phase_document_k4096_2{,_simv}.log`
- `build_hbm_reference_document/gemm_phase_document_k4096_2_before.sha256`
- `build_hbm_hardware_reference/hardware-smoke-4914/gemmphasek4096.log`
- `build_hbm_hardware_reference/hardware-smoke-4914/after.json`

Next separate descriptor/software overhead from the DMA/GEMM wait interval
using existing software-visible events/counters, preserving the existing image.
Repeat paired phase measurements before treating these differences as stable.
