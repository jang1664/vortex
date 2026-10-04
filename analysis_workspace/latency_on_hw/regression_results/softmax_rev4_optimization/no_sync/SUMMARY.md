# LLM kernel regression

Gate: **PARTIAL_PASS**

| Candidate | Kernel | Shape | Phase | Status | Cycle | Log |
|---|---|---|---|---|---:|---|
| C1 | softmax | configured | static | PASS |  | [C1.softmax.configured.static.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C1.softmax.configured.static.log) |
| C4 | softmax_layout_fused | configured | static | PASS |  | [C4.softmax_layout_fused.configured.static.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C4.softmax_layout_fused.configured.static.log) |
| C1 | softmax | decode | correctness | PASS | 31250 | [C1.softmax.decode.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C1.softmax.decode.correctness.log) |
| C4 | softmax_layout_fused | decode | correctness | PASS | 36292 | [C4.softmax_layout_fused.decode.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C4.softmax_layout_fused.decode.correctness.log) |
| C1 | softmax | prefill | correctness | PASS | 128942 | [C1.softmax.prefill.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C1.softmax.prefill.correctness.log) |
| C4 | softmax_layout_fused | prefill | correctness | PASS | 127181 | [C4.softmax_layout_fused.prefill.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C4.softmax_layout_fused.prefill.correctness.log) |
| C1 | softmax | tail_columns | correctness | PASS | 74480 | [C1.softmax.tail_columns.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C1.softmax.tail_columns.correctness.log) |
| C4 | softmax_layout_fused | tail_columns | correctness | PASS | 76992 | [C4.softmax_layout_fused.tail_columns.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C4.softmax_layout_fused.tail_columns.correctness.log) |
| C1 | softmax | decode | benchmark | PASS | 31119 | [C1.softmax.decode.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C1.softmax.decode.benchmark.log) |
| C4 | softmax_layout_fused | decode | benchmark | PASS | 36304 | [C4.softmax_layout_fused.decode.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C4.softmax_layout_fused.decode.benchmark.log) |
| C1 | softmax | prefill | benchmark | PASS | 130689 | [C1.softmax.prefill.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C1.softmax.prefill.benchmark.log) |
| C4 | softmax_layout_fused | prefill | benchmark | PASS | 126148 | [C4.softmax_layout_fused.prefill.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C4.softmax_layout_fused.prefill.benchmark.log) |
| C1 | softmax | tail_columns | benchmark | PASS | 73096 | [C1.softmax.tail_columns.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C1.softmax.tail_columns.benchmark.log) |
| C4 | softmax_layout_fused | tail_columns | benchmark | PASS | 76607 | [C4.softmax_layout_fused.tail_columns.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/no_sync/C4.softmax_layout_fused.tail_columns.benchmark.log) |

| Pair | Standalone cycle | Fused cycle | Overhead | Limit | Status | Reason |
|---|---:|---:|---:|---:|---|---|
| softmax/decode | 31119 | 36304 | 16.66% | 30% | PASS |  |
| softmax/prefill | 130689 | 126148 | -3.47% | 30% | PASS |  |
| softmax/tail_columns | 73096 | 76607 | 4.80% | 30% | PASS |  |
