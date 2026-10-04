# LLM kernel regression

Gate: **FAIL**

| Candidate | Kernel | Shape | Phase | Status | Cycle | Log |
|---|---|---|---|---|---:|---|
| C1 | elmul | configured | static | PASS |  | [C1.elmul.configured.static.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C1.elmul.configured.static.log) |
| C4 | elmul_layout_fused | configured | static | PASS |  | [C4.elmul_layout_fused.configured.static.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C4.elmul_layout_fused.configured.static.log) |
| C1 | elmul | decode | correctness | PASS | 27951 | [C1.elmul.decode.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C1.elmul.decode.correctness.log) |
| C4 | elmul_layout_fused | decode | correctness | PASS | 42992 | [C4.elmul_layout_fused.decode.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C4.elmul_layout_fused.decode.correctness.log) |
| C1 | elmul | prefill | correctness | PASS | 58688 | [C1.elmul.prefill.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C1.elmul.prefill.correctness.log) |
| C4 | elmul_layout_fused | prefill | correctness | PASS | 79526 | [C4.elmul_layout_fused.prefill.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C4.elmul_layout_fused.prefill.correctness.log) |
| C1 | elmul | tail_rows | correctness | PASS | 61389 | [C1.elmul.tail_rows.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C1.elmul.tail_rows.correctness.log) |
| C4 | elmul_layout_fused | tail_rows | correctness | PASS | 79571 | [C4.elmul_layout_fused.tail_rows.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C4.elmul_layout_fused.tail_rows.correctness.log) |
| C1 | elmul | decode | benchmark | PASS | 27928 | [C1.elmul.decode.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C1.elmul.decode.benchmark.log) |
| C4 | elmul_layout_fused | decode | benchmark | PASS | 42451 | [C4.elmul_layout_fused.decode.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C4.elmul_layout_fused.decode.benchmark.log) |
| C1 | elmul | prefill | benchmark | PASS | 60666 | [C1.elmul.prefill.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C1.elmul.prefill.benchmark.log) |
| C4 | elmul_layout_fused | prefill | benchmark | PASS | 79798 | [C4.elmul_layout_fused.prefill.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C4.elmul_layout_fused.prefill.benchmark.log) |
| C1 | elmul | tail_rows | benchmark | PASS | 61207 | [C1.elmul.tail_rows.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C1.elmul.tail_rows.benchmark.log) |
| C4 | elmul_layout_fused | tail_rows | benchmark | PASS | 79352 | [C4.elmul_layout_fused.tail_rows.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/elmul_stride/C4.elmul_layout_fused.tail_rows.benchmark.log) |

| Pair | Standalone cycle | Fused cycle | Overhead | Limit | Status | Reason |
|---|---:|---:|---:|---:|---|---|
| elmul/decode | 27928 | 42451 | 52.00% | 50% | FAIL | overhead exceeds 50% |
| elmul/prefill | 60666 | 79798 | 31.54% | 50% | PASS |  |
| elmul/tail_rows | 61207 | 79352 | 29.65% | 50% | PASS |  |
