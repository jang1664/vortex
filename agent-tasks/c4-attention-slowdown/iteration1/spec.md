# FlashAttention software improvement, iteration 1

Confirmed by user: combine only techniques whose individual hardware experiments
completed correctly, then compare against separate QK + softmax + PV. This is
one bounded improvement iteration, not a request to keep optimizing indefinitely.

Apply constant 128-wide output address arithmetic, compile-time resident online
softmax specialization, and reuse of the existing full-warp reduction helper.
Preserve the legacy progress-based path. Exclude the failed wide padding copy.
No RTL, DMA protocol, bitstream, clock, synchronization or tolerance changes.

Measure FP16 resident versus legacy using the same rebuilt decoder, 100 MHz
unified-MMIO image, inputs, and three profile passes for KV17/cap32,
KV129/cap256 and prefill128. Retain the preceding diagnostic baseline for the
before/after comparison. Check final CPU output and matching attention inputs
and output boundaries; exercise standalone legacy plus resident FP16/FP32
multitile/causal-tail behavior affected by the shared worker changes.

Retain the phase counters and write a small comparison report as the starting
point for the next iteration. Raw hardware results remain under ../runs/iteration1.
