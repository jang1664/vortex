# Remove per-GEMM output prefill

Status: confirmed by the user request to correct the unnecessary copy and revalidate.

Remove S_COPY_PREFILL/S_WAIT_PREFILL and the automatic LMEM-output-to-TMEM copy from the unified SRAM sequencer. Keep the scalar MMIO ABI, input copy, output copyback, publication and physical completion safeguards. No new flags, register bank, reset relay or TMEM crossbar.

FlashAttention explicitly initializes TMEM OBUF once using the existing copy-only descriptor after run_initialize, then reuses its initialized padding. Active output elements are overwritten by each GEMM. Whole padded output copying remains; caller owns/initializes scratch and padding rather than implicitly preserving arbitrary old LMEM destination bytes. Update software accounting from 5*T to 3*T+1 and restore matching byte counts. No unrelated optimization.

Directed node tests must seed TMEM padding once, poison LMEM destination with distinct bytes, verify active results and padding across reuse, and directly count DMA commands to demonstrate zero automatic output prefill. Preserve invalid-job/no-traffic and physical completion checks. Run FP16/FP32 through verify_rtl.py, then matching five xrt-vcs-sim attention workloads and two short FP32 overflow probes through ci/run_black.sh. Compare against frozen original baseline and prior unified implementation. Existing serializer/early-return tests are already passed; rerun only if affected paths warrant it. No PnR or broad new physical verification.
