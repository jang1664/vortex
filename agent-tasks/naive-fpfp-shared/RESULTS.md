# Independent FPINT/FPFP naive geometry

Status: implemented and verified with VCS, 2026-10-14.

Four frontend unit configurations, nine host geometry checks, and 21 successful
integration reports (including reruns) are recorded in
[`verification/FINAL_SUMMARY.json`](verification/FINAL_SUMMARY.json).

## Interface and architecture

| Setting | FPINT | FPFP |
|---|---|---|
| Capability | `GEMM_NAIVE_ENABLE` | `GEMM_NAIVE_FP16_ENABLE` |
| Reduction width | `MXU_ROW` | `FPFP_MXU_ROW` |
| Output width | `MXU_COL` | `FPFP_MXU_COL` |
| Weight rows per transfer | `MXU_WLOAD_NUM` | `FPFP_MXU_WLOAD_NUM` |
| Job selection | CONTROL bit23 = 0 | CONTROL bit23 = 1 |

FPFP parameters default to their corresponding legacy parameters. A single
mode-aware FSM schedules one complete job at a time. A pending descriptor does
not change the active job's mode, dimensions, or memory ownership. Assertions
check dispatch and completion against operand executors, compute pipelines and
physical LMEM write drain. Existing cache/DMA completion semantics are retained.

The arithmetic frontends and weight registers remain separate. Operand DMA,
FP32 accumulation/forwarding, final FP16 conversion and output infrastructure
are shared. The input and ACC buses use the maximum dimensions among enabled
formats. Physical ACC microtile slots use the larger COL, so narrower results
cannot overlap neighboring partial sums. Output gathering copies only logical
columns into compact row-major DRAM.

Internal ACC gathering uses the existing misaligned DMA implementation only
when enabled COL values differ. The LMEM ACC backend instead issues one trimmed
external descriptor per output microtile in that configuration. Equal-COL and
FPINT-only paths retain their prior behavior.

## Capacity and limits

For FPINT16x16 + FPFP8x8 and 128-element DMA tiles, an FPFP job's software scratch
is 320 KiB, versus 224 KiB for equal COL widths. At QBLK32 the INT4 job uses
276 KiB; the three-job queued regression reserves 916 KiB total. These are
scratch requirements, not synthesis resource measurements.

FPFP ROW/COL must be powers of two, at least four for the native 8-byte port,
and divide the 128-element DMA tiles. WLOAD must divide FPFP ROW and its grouped
weight transfer must fit the configured physical ports. The shared ACC column
width must fit the current port mapping; COL32 needs at least 32 LMEM ports.
FPINT retains its existing supported square geometry. FPFP has no transpose,
scale, zero-point, QROW or QCOL operation.

Normal descriptor capacity remains one. Queued verification selects
`JOB_MMIO_NUM_ENTRIES=4`; `--queued-formats` rejects configurations below three
entries before opening the device. Four entries fit the current MMIO windows;
this change does not establish arbitrary descriptor capacities.

## Verification

All integration runs use configured isolated build directories, sourced
configurations, and `ci/run_black.sh xrt-vcs-sim --perf 3`. FPFP outputs are
checked bit-for-bit against the matching FP32 reduction/accumulation order with
final FP16 rounding (signed zeros are treated as equal). FPINT keeps its
existing numerical tolerance. Output buffers are poisoned before execution.

The queued test submits FPFP/FPINT/FPFP within one kernel launch, requires at
least two entries to remain pending after submission, and verifies three
separate outputs. Separate host launches alone would not prove exclusion with
pending work.

| Dual FPINT / FPFP geometry | Staged queued shape (M,K,N) | Pending mask | Core cycles | GEMM cycles | Outputs |
|---|---|---|---:|---:|---|
| 16x16 / 8x8 | 3,32,17 | `0x7` | 11,550 | 1,679 | All three PASS |
| 16x16 / 32x8 | 3,32,17 | `0x7` | 11,474 | 1,647 | All three PASS |
| 16x16 / 8x32, 32 LMEM ports | 3,32,33 | `0x7` | 11,482 | 1,639 | All three PASS |

Each row covers FPFP -> FPINT -> FPFP in one kernel. Core cycles include
regression submission/polling and checks; these three-job counts are not a
single-GEMM latency benchmark. All outputs in these tests were bit exact.

Additional coverage includes FPFP8x16 WLOAD1/4, odd N tails, FP16 subnormal
operands, K/N spanning multiple DMA tiles, different-COL LMEM ACC output,
FPFP-only independent parameters with dormant legacy32x32 dimensions, and
FPFP-only4x4 M3 K12 N5 (core8,268 / GEMM371), and four arithmetic frontend
unit configurations with backpressure. Host compile
checks reject invalid powers, sub-word dimensions, invalid WLOAD and insufficient
physical ports.

For a matched dual16x16/8x16 FPFP workload, M2 K136 N144:

| FPFP WLOAD | Core cycles | GEMM cycles |
|---:|---:|---:|
| 1 | 11,508 | 3,586 |
| 4 | 11,283 | 3,365 |

WLOAD4 reduces GEMM cycles by 6.16% in this case. Both runs use the same final
app and input/reference configuration; the FPINT WLOAD remains unchanged.

Compatibility checks use the captured old app to isolate RTL behavior from
new regression-mode software overhead:

| Existing configuration, M1 K32 N32 | Before core/GEMM | After core/GEMM | Delta |
|---|---:|---:|---:|
| FPINT-only | 8,620 / 554 | 8,620 / 554 | 0 |
| Improve | 7,510 / 167 | 7,510 / 167 | 0 |
| FPFP-only16x16 WLOAD1 | 8,298 / 441 | 8,298 / 441 | 0 |
| FPFP-only16x16 WLOAD4 | 8,223 / 414 | 8,223 / 414 | 0 |

FPINT-only and improve preprocessed RTL token hashes exactly match the baseline.
No improve synthesis/resource matching was used.

Detailed machine-readable reports are under `verification/`; iteration failures
and fixes are recorded in `STATUS.yaml`. Initial attempts that did not establish
pending overlap are coverage misses, not passing queued tests. An existing
`vxbin.py` shared temporary-path race was avoided by serializing final kernel
conversion and auditing each binary payload against its own ELF.



The final audit matched all 12 successful build directories' current kernel
payloads to their own ELF files. Test-owned simulators have exited. Verification
is limited to RTL simulation; resource usage and timing closure require a
separate synthesis/PnR exercise. No commits or hardware-image changes were made.
