# C4 unified GEMM MMIO evidence

Start with [the corrected results](no-prefill/RESULTS.md) and
[the current ABI](../../docs/rtl/core/VX_gemm_unified_mmio.md).
The current implementation initializes TMEM OBUF once; it has no per-GEMM
output prefill. The initial results below are retained as historical evidence.

- [Corrected verification handoff](no-prefill/verification-handoff.md)
- [Initial unified-MMIO results](RESULTS.md)
- [Scoped MMIO resource comparison](mmio-cost/README.md)
- [Serializer test request](mmio-serialization-test-request.md)

Markdown summaries, specifications and reproduction scripts are versioned.
Per-run JSON, logs, checkpoints, simulator binaries and copied/preprocessed RTL
remain local evidence and are not included in these commits. Some links in
reports consequently refer to local generated receipts. Runners preserve this
machine's explicit build/worktree paths; inspect those paths before reuse.

For changed RTL, ensure the full-core simulator is rebuilt: the existing
Makefile can miss changes in child modules discovered through library search.
The corrected verification handoff documents how the stale executable was
excluded and the accepted image's recompilation and hash were verified.
