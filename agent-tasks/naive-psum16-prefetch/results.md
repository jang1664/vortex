# PSUM16 prefetch admission results

## Implementation

Only `VX_gemm_acc_lmem.sv` and `VX_gemm_node_naive.sv` changed. Both modules
are guarded by `GEMM_NAIVE`.

The adapter reserves a read slot on every accepted input requiring PSUM.
Its admission output requires available transaction capacity and, for a PSUM
read, an available read slot. The existing naive Input admission connection
uses this output. The admission decision does not depend on the Input
acceptance pulse. Already accepted work can drain while Input is stalled.
An assertion checks that every accepted read reserves its prefetch.

The adapter has 16 tagged read/data slots and the physical response join has
16 assembly slots. The separate response transport FIFO remains two entries.
Response ordering and data storage retain the existing tagged implementation;
this iteration does not introduce a new FIFO-only or dual-port RAM design.

## Verification setup

- App: `fpint_gemm_ffn_hw_naive`.
- Mode: `ci/run_black.sh xrt-vcs-sim --perf 3`.
- Config: `configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh` plus the
  existing simulation-only `GEMM_LATENCY_OBSERVER`.
- Geometry: TH16, MXU16x16, K=N=512; M=4 and M=256.
- Arguments: `-m M -k 512 -n 512 -q 32 -t 0 -d 0 -r 1`.
- Build: `build_naive_input_contexts_verify`, reconfigured before testing;
  M4 forces a simulator rebuild and M256 reuses that executable.
- Waveforms disabled. No fine reset tests or synthesis.
- `run.py` uses the established wrapper runner, captures source hashes, and
  applies `tools/verify_rtl.py` pass/failure checks to captured logs.

## Improve preservation

`check-improve.py` checks the entire tracked RTL diff is limited to the two
naive modules and preprocesses their HEAD/current revisions with the improve
TH16/MXU16 config. All four comparisons (two modules, PERF off/on) pass: both
revisions preprocess to empty. All other tracked RTL is unchanged. This is
an RTL exclusion check; no synthesized cost estimate or new improve run is
used. The prior improve cycle measurements remain the reference.

## Measurements

Both cases passed with wrapper/runner exit code zero, deterministic
`verify_rtl.py` PASS checks, no strict failure markers, and no source changes
during either run. RTL admission assertions were enabled in simulation.

| M | Previous naive GEMM | PSUM16 naive GEMM | Saved cycles | Reduction |
|---:|---:|---:|---:|---:|
| 4 | 25,547 | 19,981 | 5,566 | 21.79% |
| 256 | 1,315,844 | 676,378 | 639,466 | 48.60% |

| M | Previous naive core | PSUM16 naive core | Saved cycles | Reduction |
|---:|---:|---:|---:|---:|
| 4 | 32,154 | 26,529 | 5,625 | 17.49% |
| 256 | 1,322,379 | 682,929 | 639,450 | 48.36% |

GEMM cycles measure configuration acceptance through first completion-valid;
core cycles include kernel setup. The previous naive measurements are from
the committed pre-change reference documented in
`agent-tasks/gemm-naive-improve-baseline/p5-final-pass/`.

The unchanged improve GEMM reference is 6,449 cycles for M4 and 272,870 for
M256. The naive/improve GEMM ratio is now 3.098x at M4 and 2.479x at M256.
These runs measure the combined capacity/admission change; they do not
separately attribute the improvement to either component.

Raw manifests, captured wrapper/simulator logs, deterministic checks, and
preprocessing evidence are stored under the ignored `runs/` directory.
