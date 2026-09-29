# M256 MXU SLR cycle comparison

All six xrt-vcs-sim runs passed numerical verification with perf class 3.
Source commit: `f290725d1`. M=K=N=256, q32, t0, d0 (QCOL), r1; one core,
32 threads, MXU 32x32. Within each backend pair only GEMM_SLR_PIPELINE changes.

The primary metric is `PERF: ... total_cycles=...`, mapped to
`VX_CSR_MPM_GEMM_TOTAL_CYC`; it counts GEMM node active cycles, including
wait/drain, rather than host time or whole-kernel busy cycles.

| Backend | SLR OFF cycles | SLR ON cycles | ON - OFF | Change |
|---|---:|---:|---:|---:|
| improve | 24,762 | 25,274 | +512 | +2.07% |
| naive ACC ON | 38,602 | 39,111 | +509 | +1.32% |
| naive ACC OFF (LMEM PSUM) | 70,016 | 68,145 | -1,871 | -2.67% |

## Interpretation

- improve increases by 512 cycles, equal to 128 MXU commands times the four
  added transport cycles. Its compute-cycle counter also increases by 512.
- naive ACC ON increases by 509 cycles.
- naive ACC OFF decreases by 1,871 cycles. This macro also switches its
  input admission from the original prefetch threshold to per-bank returned
  PSUM reservations. Therefore this measurement includes that scheduling
  change, and does not isolate the cost of adding FFs alone. OFF/ON raw
  traffic counters match: input 16,384, weight 1,024, PSUM responses 14,336,
  accumulation reads 14,336 and writes 16,384. PSUM underflow and read/write
  conflicts are zero in both runs.

The improve total counter is enabled by nonempty controller queues or MXU
computing (`hw/rtl/core/gemm/VX_gemm_ctrl.sv:474`); naive counts job_active_q
(`hw/rtl/core/gemm/VX_gemm_ctrl_naive.sv:368`). Compare OFF/ON within a backend;
these are not identical definitions for comparisons across backends.

For reference, the MXU FSM COMPUTE-state counters are:

| Backend | OFF compute cycles | ON compute cycles | Difference |
|---|---:|---:|---:|
| improve | 19,477 | 19,989 | +512 |
| naive ACC ON | 22,565 | 23,074 | +509 |
| naive ACC OFF (LMEM PSUM) | 56,115 | 54,244 | -1,871 |

## Reproduction and evidence

Runner: [run_perf.py](run_perf.py). Full commands, configs, hashes, counters
and retained attempts: [summary.yaml](summary.yaml). Raw logs remain under
`results/<backend>_slr<0|1>/attempt*.log` (ignored build evidence).

The runner sources the captured configs in
`agent-tasks/mxu-slr-port/verification/configs`, configures six independent
`build_mxu_perf3_*` directories with XLEN64, and runs:

```sh
ci/run_black.sh xrt-vcs-sim --app APP   --args "-m 256 -k 256 -n 256 -q 32 -t 0 -d 0 -r 1" --perf 3
```

APP is fpint_gemm_ffn_hw for improve or fpint_gemm_ffn_hw_naive for naive.
The external-PSUM variant removes GEMM_NAIVE_USE_ACC_MEM. Both pipeline
states add DISABLE_FSDB; perf class 3 adds PERF_ENABLE. Trace is disabled.
Compilers are /usr/bin/gcc and /usr/bin/g++; compatible Xilinx IP/simlib
assets are shared, while simulator binaries are independent.

Both improve cases passed within the initial 300-second compile/run limit.
Four naive cases reached that limit and passed fresh runs with an 1800-second
limit, reusing only compiled build products. Timeouts remain in the evidence
and are not treated as cycle measurements. The final runner exited zero;
source hashes matched before/after every run and in the final audit.
RTL and host application sources were not modified for this measurement.
