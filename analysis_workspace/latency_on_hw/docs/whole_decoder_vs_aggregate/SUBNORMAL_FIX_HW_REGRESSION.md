# Subnormal fix: C1–C4 decoder hardware regression

New fix_sub_norm images; deterministic seed 20260831, original IEEE references and unchanged final-output gates.

| Candidate | Model | Case | Result | Violations | Relative L2 (%) | Max abs |
|---|---|---|---|---:|---:|---:|
| C1 | llama3-8b | prefill32 | PASS | 1 / 131072 | 0.041089 | 0.00390625 |
| C1 | llama3-8b | prefill1024 | PASS | 30 / 4194304 | 0.045443 | 0.00390625 |
| C1 | llama3-8b | decode1024 | PASS | 0 / 4096 | 0.041921 | 0.0009765625 |
| C1 | llama2-7b | prefill32 | PASS | 1467 / 131072 | 0.103511 | 0.0126953125 |
| C1 | llama2-7b | prefill1024 | PASS | 1581 / 4194304 | 0.049127 | 0.0126953125 |
| C1 | llama2-7b | decode1024 | PASS | 0 / 4096 | 0.039307 | 0.0009765625 |
| C2 | llama3-8b | prefill32 | PASS | 1 / 131072 | 0.041128 | 0.00390625 |
| C2 | llama3-8b | prefill1024 | PASS | 30 / 4194304 | 0.045102 | 0.00390625 |
| C2 | llama3-8b | decode1024 | PASS | 0 / 4096 | 0.042204 | 0.0009765625 |
| C2 | llama2-7b | prefill32 | PASS | 1451 / 131072 | 0.103541 | 0.0126953125 |
| C2 | llama2-7b | prefill1024 | PASS | 1567 / 4194304 | 0.049137 | 0.0126953125 |
| C2 | llama2-7b | decode1024 | PASS | 0 / 4096 | 0.039304 | 0.0009765625 |
| C3 | llama3-8b | prefill32 | PASS | 1 / 131072 | 0.044294 | 0.00390625 |
| C3 | llama3-8b | prefill1024 | PASS | 42 / 4194304 | 0.046322 | 0.00390625 |
| C3 | llama3-8b | decode1024 | PASS | 0 / 4096 | 0.047710 | 0.001220703125 |
| C3 | llama2-7b | prefill32 | PASS | 1464 / 131072 | 0.104603 | 0.0126953125 |
| C3 | llama2-7b | prefill1024 | PASS | 1587 / 4194304 | 0.049895 | 0.0126953125 |
| C3 | llama2-7b | decode1024 | PASS | 0 / 4096 | 0.038825 | 0.0009765625 |
| C4 | llama3-8b | prefill32 | PASS | 1 / 131072 | 0.044294 | 0.00390625 |
| C4 | llama3-8b | prefill1024 | PASS | 42 / 4194304 | 0.046322 | 0.00390625 |
| C4 | llama3-8b | decode1024 | PASS | 0 / 4096 | 0.047710 | 0.001220703125 |
| C4 | llama2-7b | prefill32 | PASS | 1464 / 131072 | 0.104603 | 0.0126953125 |
| C4 | llama2-7b | prefill1024 | PASS | 1587 / 4194304 | 0.049895 | 0.0126953125 |
| C4 | llama2-7b | decode1024 | PASS | 0 / 4096 | 0.038825 | 0.0009765625 |

Full results: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/hw/syn/xilinx/xrt/.pnr_monitor/fix_sub_norm_20261009_local/decoder_results.json`.
