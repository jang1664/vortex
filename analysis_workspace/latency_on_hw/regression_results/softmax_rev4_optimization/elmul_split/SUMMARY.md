# LLM kernel regression

Gate: **PARTIAL_PASS**

| Candidate | Kernel | Shape | Phase | Status | Cycle | Log |
|---|---|---|---|---|---:|---|
| C1 | elmul | configured | static | PASS |  | [C1.elmul.configured.static.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C1.elmul.configured.static.log) |
| C4 | elmul_layout_fused | configured | static | PASS |  | [C4.elmul_layout_fused.configured.static.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C4.elmul_layout_fused.configured.static.log) |
| C1 | elmul | decode | correctness | PASS | 28591 | [C1.elmul.decode.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C1.elmul.decode.correctness.log) |
| C4 | elmul_layout_fused | decode | correctness | PASS | 34714 | [C4.elmul_layout_fused.decode.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C4.elmul_layout_fused.decode.correctness.log) |
| C1 | elmul | prefill | correctness | PASS | 60938 | [C1.elmul.prefill.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C1.elmul.prefill.correctness.log) |
| C4 | elmul_layout_fused | prefill | correctness | PASS | 68221 | [C4.elmul_layout_fused.prefill.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C4.elmul_layout_fused.prefill.correctness.log) |
| C1 | elmul | tail_rows | correctness | PASS | 60234 | [C1.elmul.tail_rows.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C1.elmul.tail_rows.correctness.log) |
| C4 | elmul_layout_fused | tail_rows | correctness | PASS | 84001 | [C4.elmul_layout_fused.tail_rows.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C4.elmul_layout_fused.tail_rows.correctness.log) |
| C1 | elmul | decode | benchmark | PASS | 28023 | [C1.elmul.decode.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C1.elmul.decode.benchmark.log) |
| C4 | elmul_layout_fused | decode | benchmark | PASS | 34657 | [C4.elmul_layout_fused.decode.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C4.elmul_layout_fused.decode.benchmark.log) |
| C1 | elmul | prefill | benchmark | PASS | 60383 | [C1.elmul.prefill.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C1.elmul.prefill.benchmark.log) |
| C4 | elmul_layout_fused | prefill | benchmark | PASS | 68101 | [C4.elmul_layout_fused.prefill.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C4.elmul_layout_fused.prefill.benchmark.log) |
| C1 | elmul | tail_rows | benchmark | PASS | 61259 | [C1.elmul.tail_rows.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C1.elmul.tail_rows.benchmark.log) |
| C4 | elmul_layout_fused | tail_rows | benchmark | PASS | 84668 | [C4.elmul_layout_fused.tail_rows.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_split/C4.elmul_layout_fused.tail_rows.benchmark.log) |

| Pair | Standalone cycle | Fused cycle | Overhead | Limit | Status | Reason |
|---|---:|---:|---:|---:|---|---|
| elmul/decode | 28023 | 34657 | 23.67% | 50% | PASS |  |
| elmul/prefill | 60383 | 68101 | 12.78% | 50% | PASS |  |
| elmul/tail_rows | 61259 | 84668 | 38.21% | 50% | PASS |  |
