# P0 completed-job lifecycle evidence

Both backends pass the new `fpint_gemm_lifecycle` blackbox in xrt-vcs-sim
at th16/MXU16, M3/K64/N64, QCOL/WTRANS0. One `vx_start` executes three
different tagged generations through the unchanged production descriptor
helper. Each output is initially NaN-poisoned. The device verifies all 192
logical outputs at 0.001 tolerance before submitting the next job; the host
also verifies all three outputs after completion. Both captures have unchanged
source hashes during execution.

| Backend | Job | Device start MCYCLE | Device verification MCYCLE | FSDB epoch | Normalized GEMM cycles |
|---|---:|---:|---:|---:|---:|
| improve | 0 | 3,111 | 69,782 | 1 | 298 |
| improve | 1 | 70,327 | 136,862 | 1 | 298 |
| improve | 2 | 137,389 | 203,922 | 1 | 298 |
| naive | 0 | 3,133 | 71,134 | 1 | 1,482 |
| naive | 1 | 71,648 | 139,488 | 1 | 1,477 |
| naive | 2 | 139,981 | 207,819 | 1 | 1,477 |

Each `verified[j] < start[j+1]`. These are volatile device-written timestamps
read back by the host, not the host log emission times. The independent
controller FSDB extractor observes jobs 0/1/2 in one reset epoch and matches
all observer endpoints exactly. MCYCLE values and observer edge indices have
different origins; they are not directly subtracted. The substantial software
comparison intervals are not GEMM execution latency or a performance baseline.

Evidence is in `p0-baseline/{improve,naive}-lifecycle-trace/`, with compact
checks and evidence hashes in `p0-lifecycle-{improve,naive}-results.json`.
Reproduce the final checks with:

```sh
python3 agent-tasks/gemm-naive-improve-baseline/p0-lifecycle-verify.py agent-tasks/gemm-naive-improve-baseline/p0-baseline/improve-lifecycle-trace --output agent-tasks/gemm-naive-improve-baseline/p0-lifecycle-improve-results.json
python3 agent-tasks/gemm-naive-improve-baseline/p0-lifecycle-verify.py agent-tasks/gemm-naive-improve-baseline/p0-baseline/naive-lifecycle-trace --output agent-tasks/gemm-naive-improve-baseline/p0-lifecycle-naive-results.json
```

The initial `*-lifecycle/` captures also passed numerical and same-epoch checks,
but device printf markers were absent. They remain preserved; the final trace
does not depend on UART delivery. The exact missing-print transport cause is
not established. For those initial custom-app manifests, the runner's nominal
`repeat=1`/`tagged=false` fields did not describe the app-owned workload; the
source and `LIFECYCLE_SINGLE_START` message establish three tagged generations.
Final trace manifests explicitly identify the app-owned parameter source.

This establishes completed-job reuse without reset for this directed shape.
It does not establish active reset support, arbitrary-stall correctness,
QROW/MXU32 lifecycle coverage, the redesigned context protocol, or performance
acceptance. Distinct external buffers are test operands, while existing
physical LMEM/TMEM scratch regions are reused without added capacity.
