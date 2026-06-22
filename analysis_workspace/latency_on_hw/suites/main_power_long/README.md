# main_power_long

This suite is a long-shape companion to `suites/main_power` for recovering
power measurements on very fast KV quantization kernels.

The C4 fused prefill workload uses `prefill_seq_len=16384` so
`kv_cache_quant_layout_fused_w4a16` runs long enough to produce power samples.
Run it with an app filter unless you intentionally want all C4 fused kernels:

```bash
./make_cases.sh --input suites/main_power_long --output generated_suites/main_power_long
STAGES=prefill SKIP_EXISTING=1 ./run_hw.sh --input generated_suites/main_power_long --output outputs_main_power_long \
  --no-latency --retry --retry-timeout-growth 2 \
  --power-auto-duration --power-max-iterations 3 \
  --filter "app==kv_cache_quant_layout_fused_w4a16"
```

Generation KV quantization still has app args with `-k 1`, so increasing
`gen_kv_len` does not lengthen the measured kernel. For generation power, use
a larger `--power-max-iterations` or add a benchmark-side repeat path.
