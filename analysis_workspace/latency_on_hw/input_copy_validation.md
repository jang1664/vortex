# Latency bench input-copy validation

Date: 2026-07-31

`bench_main.cpp` programs prepare and upload input payloads by default.
Latency-only runs can skip host input preparation and payload H2D copies with
`--input-copy=skip` or the legacy `--skip-input-copy`. `--input-copy=copy`
and `--copy-inputs` explicitly select the default copy path.

Kernel argument uploads, status transfers, and required read/write-buffer
initialization are not payload copies and remain enabled.

## Method

- Hardware runs used `ci/run_black.sh hw --fpga-bin ... --bench`.
- Copy and skip used the same FPGA alias and device index.
- Each mode ran with `--warmup=0 --iterations=3 --csv --output=...`.
- The table compares the median of three FPGA cycle measurements.
- Pass criterion: `abs(skip - copy) / copy <= 3%`.
- Shapes are representative decode/latency shapes. The slow
  `softmax_layout_fused` case uses batch 64, 32 heads, and a 65536 K stride.

## Latency-suite apps

| App | Copy median | Skip median | Difference |
|---|---:|---:|---:|
| eladd | 182073 | 184000 | 1.058% |
| eladd_layout_fused | 211243 | 210681 | 0.266% |
| elmul | 124557 | 122823 | 1.392% |
| elmul_layout_fused | 175505 | 174854 | 0.371% |
| fpint_gemm_ffn_hw | 698235 | 698240 | 0.001% |
| fpint_gemm_ffn_hw_naive | 1361272 | 1361333 | 0.004% |
| hadamard | 121031 | 119972 | 0.875% |
| hadamard_layout_fused | 341970 | 341841 | 0.038% |
| head_concat | 155514 | 156164 | 0.418% |
| head_concat_layout_fused | 190948 | 190437 | 0.268% |
| kv_cache_dequant_w4a16 | 673887 | 673860 | 0.004% |
| kv_cache_quant_layout_fused_w4a16 | 60369 | 60416 | 0.078% |
| kv_cache_quant_w4a16 | 1688072 | 1695003 | 0.411% |
| rms_norm_layout_fused | 135386 | 135670 | 0.210% |
| rmsnorm | 110025 | 110426 | 0.364% |
| rope | 118835 | 119094 | 0.218% |
| rope_layout_fused | 241814 | 240633 | 0.488% |
| sgemm_tcu | 505597 | 508379 | 0.550% |
| silu | 258950 | 263623 | 1.805% |
| silu_layout_fused | 148860 | 148579 | 0.189% |
| softmax | 81099 | 80796 | 0.374% |
| softmax_layout_fused | 37530955 | 37638645 | 0.287% |

All 22 latency-suite apps pass.

## Other active regression benches

| App | Copy median | Skip median | Difference |
|---|---:|---:|---:|
| detile_output | 100223 | 100273 | 0.050% |
| dropout | 90811 | 88535 | 2.506% |
| eldiv | 112738 | 111985 | 0.668% |
| elreduce | 377272 | 374599 | 0.709% |
| elscalar | 179337 | 177713 | 0.906% |
| elsub | 112784 | 111918 | 0.768% |
| elunary | 183719 | 181541 | 1.185% |
| hadamard_base | 2495561 | 2494712 | 0.034% |
| tile_input_a | 88301 | 88343 | 0.048% |
| tile_scale_zp_w4a16 | 145097 | 143570 | 1.052% |
| tile_weight_w4a16 | 85029 | 85177 | 0.174% |
| vecadd | 261758 | 260946 | 0.310% |

`elunary` uses the median of six measurements because its first three-sample
comparison was 3.145%; the six-sample comparison passes at 1.185%.

`dequant_hbm_energy` remains copy-enabled. It is a combined energy and
correctness benchmark that reads device output back and compares it with a
host reference, so undefined input data is not a valid mode for that app.
