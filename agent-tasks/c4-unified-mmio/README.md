# C4 unified GEMM MMIO evidence

Start with [the corrected results](no-prefill/RESULTS.md) and
[the current ABI](../../docs/rtl/core/VX_gemm_unified_mmio.md).
The current implementation initializes TMEM OBUF once; it has no per-GEMM
output prefill. The initial results below are retained as historical evidence.

- [Corrected verification handoff](no-prefill/verification-handoff.md)
- [Initial unified-MMIO results](RESULTS.md)
- [Scoped MMIO resource comparison](mmio-cost/README.md)
- [Serializer test request](mmio-serialization-test-request.md)
- [100 MHz PnR result](pnr/20261030_unified_mmio_r1/RESULTS.md)
- [Nine-case FPGA functionality result](hardware/20261031_unified_mmio_r1/RESULTS.md)
- [FlashAttention versus separate QK/softmax/PV](hardware/20261031_attention_comparison/RESULTS.md)
- [Generated files excluded from Git](IGNORE.md)

The current image closes timing at 100 MHz and passes the recorded hardware
checks. It does not improve attention latency in the three measured decoder
workloads: resident FP16 is 3.60–7.45 times slower than the separate operation
sum; FP32 is 3.82–7.69 times slower. See the comparison for exact workloads,
three-repeat medians, phase counters and numerical checks.

Markdown summaries, specifications and reproduction scripts are versioned.
Per-run JSON, logs, checkpoints, simulator binaries and copied/preprocessed RTL
remain local evidence and are not included in these commits. Some links in
reports consequently refer to local generated receipts. Runners preserve this
machine's explicit build/worktree paths; inspect those paths before reuse.

For changed RTL, ensure the full-core simulator is rebuilt: the existing
Makefile can miss changes in child modules discovered through library search.
The corrected verification handoff documents how the stale executable was
excluded and the accepted image's recompilation and hash were verified.
