# Empty-prefix attention worker regression

This test invokes the actual initialize, online-softmax, accumulate, and finalize
wrappers from `../flash_attn/kernel.cpp`. It includes that translation unit with
its main renamed; it does not copy the softmax algorithm or change the public
attention mask ABI. The production host API always includes key zero, so this
test supplies an otherwise unreachable initially empty prefix directly to the
workers through the existing `vx_flash_attention_args_t`.

One device launch checks two phases without reinitializing between them:

1. `kv_length=0`, tile zero: all probabilities, alpha, sum, accumulator and final
   output must be zero; the row maximum must remain negative infinity.
2. `kv_length=256`, tile one: 128 valid equal scores per row make probabilities
   exactly one and sum exactly 128. Known signed dyadic FP32 partial outputs
   must become the accumulator, with alpha zero and finite `partial / 128`
   final output. The first valid block must update the maximum once.

The host independently checks every logical state/output value, plus all padded
probability entries. M1 and M4 use the production eight-row padded layout.
Scores, probabilities, state, partials and O reside in LMEM. Existing worker
publication is retained; an additional test-only publication precedes diagnostic
readback of LMEM O. HBM snapshots are explicitly test-only diagnostics, using
the existing debug-score address field. They are not production traffic evidence.
The test does not submit GEMM or SRAM-DMA commands.

Use a separately configured build and source `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh` after
the TVM environment. Run from that build with the repository wrapper:

```sh
ci/run_black.sh xrt-vcs-sim --app flash_attn_mask --args "-m 1" \
  --configs-extra "-DDISABLE_FSDB -DDEBUG_LEVEL=0"
ci/run_black.sh xrt-vcs-sim --app flash_attn_mask --args "-m 4" \
  --configs-extra "-DDISABLE_FSDB -DDEBUG_LEVEL=0"
```

Omit the generic `--debug` option. The host keeps a finite 1800000 ms wait.
Control-hart `MASK_PHASE` messages identify completed worker/fill/snapshot
boundaries and device-cycle stamps (`cycle_hi * 2^32 + cycle_lo`). These sparse
test-only diagnostics distinguish completed stages from a live but stalled
process when a console observer is present; they are not production latency
measurements. The current XRT-VCS path does not decode `IO_COUT`, so these
messages are not visible in host stdout without a passive console observer.
Host completion and independent numerical checks remain the pass criteria.
The original 300000 ms
attempt timed out without phase evidence, which did not establish either
functional progress or a deadlock. The longer cap preserves the full workload
and all numerical checks.
Success requires the exact independent checks and `PASSED` for both row counts;
there are no tolerance changes or production validation bypasses.
