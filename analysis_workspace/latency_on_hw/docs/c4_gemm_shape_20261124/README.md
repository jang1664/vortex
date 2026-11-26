# C4 FP-INT GEMM shape measurements

The M sweep uses the U55C C4 rev8 alias `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fix_sub_norm` at 100 MHz, the current worktree at HEAD `4b5891823`, and the configured build's hardware bench. Each CSV row represents one hardware invocation. The latency columns are host-observed kernel timing in microseconds. The final PERF cycle counter is recorded separately. Runs with 10 timed iterations used 3 warmups. Runs with 2 timed iterations used 1 warmup.

From the configured build directory, each invocation used:

```sh
ci/run_black.sh hw --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fix_sub_norm \
  --bench --app fpint_gemm_ffn_hw \
  --args "-m $allocated_m -n 4096 -k 4096 -q 32 -t 0 -d 0 --target-m $target_m --warmup=$warmup --iterations=$iterations"
```

The allocated M is the effective M rounded up to 8 rows. Historical comparisons use successful C4 rows for the same kernel and flags in the two Llama rev8_v2 raw databases. The plot uses their M=1024, N=K=4096 FPGA timing (675.058 ms) as the large-M reference. New bench timing includes host launch/wait overhead. The ±5% band is a prediction tolerance, not a confidence interval.
