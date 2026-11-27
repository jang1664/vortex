# KIVI layout-fused quantization on U55C

This experimental application is a copy of the layout-fused benchmark and its CPU golden test. Use `kivi_quant_layout_fused` to select it. It shares the quantization helpers and argument layout with the original implementation. Existing Qwen benchmark suites still select the original application.

The optimized path targets Qwen3-8B's 128-channel heads, INT4 group size 32, 128-element DMA tiles and 16×16 microtiles. Each worker owns the packed bytes for two K channels. During decode, the worker stages the new FP16 values before scanning its channels' current group. Four 16-thread warps can therefore cover all 64 pairs concurrently. The kernel computes each channel pair's Q-ROW metadata locations once and writes both required replicas. Packed K bytes advance eight bytes per token inside a microtile. For V, a worker handles a 32-channel group by reading two 16-channel segments of the GEMM output and writing two packed segments. Other supported layouts use the copied generic path.

## Reproduce a decode K comparison

Use a configured build directory and the same physical U55C for all three applications. For the run below the alias was `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fix_sub_norm` and the device opened by XRT was `0000:3d:00.1`. Inside its Slurm allocation, run the following from the build directory.

```bash
alias_name=improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fix_sub_norm
key="-k 32 -n 128 -q 32 -d 0 -t 1 --quant-mode kivi_int_zp"
tiled="$key --source-transposed --gemm-qdir 1 --cache-update append"
timing="--warmup=1 --iterations=3 --csv"

ci/run_black.sh hw --fpga-bin "$alias_name" --app kivi_quant_layout_fused \
  --args "$tiled --cache-capacity 384 --cache-position 159"
for app in kv_cache_quant_layout_fused_w4a16 kivi_quant_layout_fused; do
  ci/run_black.sh hw --fpga-bin "$alias_name" --app "$app" --bench \
    --args "$tiled --cache-capacity 65536 --cache-position 1055 $timing --output=/tmp/kivi_$app.csv"
done
ci/run_black.sh hw --fpga-bin "$alias_name" --app kv_cache_quant_w4a16 --bench \
  --args "$key --kivi-update-key $timing --output=/tmp/kivi_dense.csv"
```

Compare the median of the three timed `PERF: cycles` samples. The golden test checks the complete packed weight, scale and zero-point buffers, including untouched sentinel bytes. It also checks the FP16 row retained for the next K update.

For the full paired sweep, run `python3 ../tests/regression/kivi_quant_layout_fused/compare.py /absolute/path/to/new-results` from the configured build directory inside the board allocation.

## Measured results

Same U55C and C4 fix_sub_norm image for standalone and fused kernels. Each result uses the median of three device-cycle samples after one warmup. [All 46 paired measurements](measurements.tsv) use the fused/standalone ratio. The size column gives active group length for decode K, source rows for decode V, and sequence length for prefill.

| Operation | Tested sizes | Fused/standalone range |
|---|---|---|
| Decode K append | 1–32, every length | 0.917–1.216 |
| Decode V append | 8 and 64 source rows | 0.794–0.796 |
| Prefill K | 1K to 32K, powers of two | 0.769–0.777 |
| Prefill V | 1K to 32K, powers of two | 1.172–1.176 |

For a full 32-token decode K group, the original fused kernel took 611,383 cycles and increasing parallelism alone reduced this to 281,723 cycles. The final implementation took 128,554 cycles, compared with 140,129 for its paired standalone run. Across a complete 32-step group the ratio of summed device cycles was 0.997. All 50 CPU-golden comparisons passed. They cover all decode K group lengths, both decode V source shapes, representative prefill and partial tiles, and four additional input patterns at three K lengths.

Raw device logs are in `/mnt/nfs-vlsi/jaeyongjang/kivi_quant_ab.3pMRyGyD` (baseline and warp-only) and `/mnt/nfs-vlsi/jaeyongjang/kivi_quant_full.QPbv6uJn` (final).
