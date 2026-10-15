# Naive FP16 x FP16 GEMM: implementation and WLOAD comparison

Date: 2026-10-14. Status: implementation and scoped VCS verification complete.
Source baseline: `8762b80e3177f74270712e0c7af1bb886334c415` plus this task's uncommitted changes.

## Implemented contract

`GEMM_NAIVE_ENABLE` enables FPINT and `GEMM_NAIVE_FP16_ENABLE` enables FPFP independently. Legacy `GEMM_NAIVE` continues to enable FPINT. A dual-capability image selects FPFP with descriptor CONTROL bit 23; mode remains fixed until the job fully drains.

FPFP uses FP16 row-major A `[M,K]` and B `[K,N]`, FP32 products/tree reduction/partial sums, and FP16 conversion only for final C. There is no FPFP transpose or quantization direction. FPFP issues A/B transfers without scale/zero transfers or dependencies. Existing naive FSM, DMA protocol, accumulator ownership/RAW forwarding and output handling are reused.

The regression app is `fpint_gemm_ffn_hw_naive --fp16-weights`. Its golden reference follows the hardware's FP32 adjacent-pair tree and accumulation order. Results must match FP16 bits, except signed zero. An independent FP64 reference reports mathematical error without relaxing the pass threshold. Output buffers are poisoned before execution.

## Capacity and bandwidth

The representative C3 v3 configuration has TH16/MXU16, 16 LMEM ports/banks, 8-byte physical requests and 1,280 KiB actual LMEM. The 2 MiB address envelope is not its capacity. Keeping 128x128x128 DMA tiles needs 224 KiB scratch: double-buffered A/B (128 KiB), C (32 KiB), and reserved FP32 partial sums (64 KiB). All intervals and bank/ACC indices passed the static audit; no tile reduction is needed. See [capacity_preflight.json](capacity_preflight.json).

| Setting | FP16 rows per weight group | Group bytes | 8-byte request lanes | Banks touched at NT=128 | Requests per touched bank |
|---|---:|---:|---:|---:|---:|
| WLOAD=1 | 1 | 32 | 4 | 4 | 1 |
| WLOAD=4 | 4 | 128 | 16 | 4 | 4 |

Physical port count/width is unchanged. The 256-byte LMEM B row stride causes four grouped rows to map to the same four banks. WLOAD=4 therefore does not imply 4x sustained bandwidth. No new swizzled layout was introduced.

## Cycle comparison

Both builds derive from `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh`, remove the exact legacy `GEMM_NAIVE` token, enable only `GEMM_NAIVE_FP16_ENABLE`, and select WLOAD=1 or 4. Both use the same seed and configured Xilinx FP32 operators, with `--perf 3`.

All rows PASS with bit-exact FPFP output. Positive reduction means WLOAD4 takes fewer cycles.

| M / K / N | WLOAD1 core | WLOAD4 core | Core reduction | WLOAD1 GEMM | WLOAD4 GEMM | GEMM reduction |
|---|---:|---:|---:|---:|---:|---:|
| 1 / 32 / 32 | 8,298 | 8,223 | 0.90% | 441 | 414 | 6.12% |
| 2 / 32 / 32 (subnormal) | 8,298 | 8,298 | 0.00% | 459 | 434 | 5.45% |
| 3 / 48 / 17 (tail) | 8,448 | 8,373 | 0.89% | 584 | 549 | 5.99% |
| 4 / 256 / 256 | 14,536 | 13,486 | 7.22% | 6,702 | 5,626 | 16.05% |

For M4/K256/N256, WLOAD4 improves GEMM cycles by **16.05%** and whole-core cycles by **7.22%**. This is a 1.19x GEMM speedup, not 4x bandwidth. Weight installations decrease from 4,096 to 1,024 groups, while the amount of FP16 operand data is unchanged.

`core cycles` includes the device program's job programming/polling. `GEMM cycles` is the reported MXU `total_cycles`. Neither is host wall time. Legacy `compute_cycles`/`mac_count` counters are zero even in the baseline and are not used for this comparison. Weight fire counts measure installed groups, not physical bank bandwidth.

## Compatibility

| Existing path, same old app and shape M1/K32/N32 | Before core / GEMM cycles | After core / GEMM cycles | Delta |
|---|---:|---:|---:|
| Naive FPINT-only | 8,620 / 554 | 8,620 / 554 | 0 |
| Improve | 7,510 / 167 | 7,510 / 167 | 0 |

Improve selected/preprocessed RTL tokens remain identical to baseline. No improve synthesis was run. The added FPFP arithmetic and transport are guarded out of improve and FPINT-only configurations. See the reports in [verification](verification).

The cycle compatibility rows intentionally reuse the pinned pre-change app to isolate RTL changes from the new software format checks. They do not assert that the extended app has identical software instruction overhead.

## Functional coverage

| Check | Result |
|---|---|
| FPFP frontend, WLOAD1 and WLOAD4 | PASS: 40 transactions each, both weight banks, directed subnormals, full FIFO and downstream backpressure |
| M1/K32/N32 random, both WLOAD values | PASS, bit exact |
| M2/K32/N32 directed subnormal operands/output, both WLOAD values | PASS, bit exact |
| M3/K48/N17 tails, both WLOAD values | PASS, bit exact |
| M4/K256/N256 multi-K/N tiles | Both PASS, all 1,024 outputs bit exact |
| M1/K384/N160 three K macro tiles, dual-capability image | PASS: core 14,236 / GEMM 6,374 cycles |
| M129/K32/N32 multi-M tiles, WLOAD4 | PASS: core 10,098 / GEMM 2,234 cycles |
| Same dual-capability image: FPFP → FPINT → FPFP | PASS for all three jobs |
| Dual image legacy FPINT QCOL + WTRANS=1 | PASS: core 9,093 / GEMM 822 cycles |
| FPFP QDIR=1/QBLK=128 vs QDIR=0/QBLK=32 | Identical output and core 8,223 / GEMM 414 cycles |
| LMEM-backed FP32 accumulator, M1/K48/N17 | PASS: core 8,373 / GEMM 525 cycles |
| Both capabilities disabled | Full-system vecadd PASS |
| Single-format unsupported request | Rejected by host before device open |
| Capability-specific instance pruning | PASS in preprocessed node/core instance sites; see [capability_instances.json](verification/capability_instances.json) |
| Software FP16 conversion/reference | PASS against host `_Float16` for all 63,488 finite half patterns; poisoned output and one-bit mismatch correctly fail |

The complete shape matrix M256/K256/N256 was replaced by orthogonal multi-K/N and multi-M cases to keep actual Xilinx-IP VCS simulation bounded. Inf/NaN arithmetic semantics and job-level multicore partitions are not established by these finite-input tests.

## Reproduction

Each configuration has its own configured build directory. For example, from `build_fpfp_wload4`:

```bash
source ./config.sh
./ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive \
  --perf 3 --args "--fp16-weights -m 4 -k 256 -n 256 --seed 1"
```

Full commands and log paths are recorded by the verification runner. Durable, fully resolved CONFIGS snapshots are in [resolved.json](verification/configs/resolved.json); source wrappers are alongside it. Rebuild host and kernel together after the appended app ABI fields change. The runtime does not currently query GEMM-format capability from the FPGA image; software and image configurations must match.

## Limits

Validation targets TH16/MXU16 with the configured Xilinx FP32 IP. Arbitrary array sizes, other FP backends, nonzero job-level M_START/N_START partitions, SLR placement, PnR area and timing are not validated. Macro-tile offsets and differing DRAM/LMEM strides are covered by the multi-tile tests. Large-M coverage uses M129/K32/N32 instead of the much more expensive M256/K256/N256 VCS workload.

The new spatial frontend contains 256 FP32 multipliers and 240 FP32 tree adders at MXU16, in addition to accumulation. These are logical operator counts, not measured LUT/DSP usage. No resource or FPGA-frequency claim follows from the VCS cycle results.

The initial integration failure was an implicit undriven wire caused by declaration order; moving `input_fire` ahead of the new instance fixed it without weakening assertions. WLOAD1's first large test hit a 300-second wall limit while simulating; the identical-code bounded retry passed (424.95 seconds of simulator CPU time), confirming that the original timeout was insufficient wall-time budget. Both attempts are retained in the verification records.
