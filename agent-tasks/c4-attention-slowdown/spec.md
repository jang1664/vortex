# C4 FlashAttention slowdown diagnosis

Determine why the current resident attention is slower than separate QK,
softmax and PV on the same 100 MHz image. Split SIMD cycles into initialization,
online softmax, accumulation and finalization, and measure decoder input
padding directly. Preserve numerical checks and compare identical workloads.

Scope: software-only diagnostic counters and controlled experiments. No RTL,
PnR, clock, config or numerical-threshold changes. Hardware uses the existing
unified-MMIO image through configured ci/run_black.sh hw with its alias.

Source baseline: f0305e136402f6ee52a4a829be78a28ae7302cee

Snapshots and raw runs stay local; report measured facts separately from
inferences. Experimental variants are not production performance claims.
