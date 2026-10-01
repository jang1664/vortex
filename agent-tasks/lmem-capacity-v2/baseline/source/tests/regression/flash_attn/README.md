# C4 FlashAttention regression

This regression validates one 128-key, 128-dimensional W4A16/KV4 attention
tile on the C4 FPGA configuration.

The device kernel submits the QK GEMM descriptor and consumes its four
32-column output tiles through the improve-GEMM output-progress MMIO register.
It updates scaled online softmax as each tile becomes visible and writes the
probability tile directly in GEMM-A layout. After all softmax workers join, the
control hart executes one fence and submits a temporally separate PV GEMM
descriptor in the same kernel. The PV result is accumulated in FP32 and
normalized to FP16.

The host reference reproduces the accelerator's FP16 GEMM rounding and checks
scores, probabilities, the per-tile partial, online max/sum state, accumulator,
and final output. Both causal and non-causal modes are supported.

Run from a configured build directory:

```sh
ci/run_black.sh hw --fpga-bin C4 --app flash_attn --args "-m 16 -n 128"
ci/run_black.sh hw --fpga-bin C4 --app flash_attn --args "-m 16 -n 128 -c"
ci/run_black.sh hw --fpga-bin C4 --app flash_attn --args "-m 16 -n 128 -P"
```

`-P` is a PV-only diagnostic. The host uploads the reference probability tile
and makes PV the first descriptor, which separates PV arithmetic and layout
errors from back-to-back descriptor-state errors.

## Current boundary

The regression intentionally accepts exactly one KV tile. The deployed C4
image retains improve-GEMM synchronization-register values after a descriptor
finishes. Consequently, the second descriptor's WAIT commands can consume the
first descriptor's completion values before the second descriptor's own DMA
notifications arrive. The source RTL now clears this state on accepted
`OP_CLEAR`, and `hw/unittest/gemm_node_improve` covers two different descriptors
without an intervening reset. A rebuilt C4 image containing that RTL change is
required before the full QK/softmax/PV test can pass on FPGA; PV-only remains a
useful check on the currently deployed image.

Multi-KV-tile attention is still follow-up work. It needs per-tile K/V address
progression and online-softmax rescaling coverage beyond the single 128-key
tile used here.
