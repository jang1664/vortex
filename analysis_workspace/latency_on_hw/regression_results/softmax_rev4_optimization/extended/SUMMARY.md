# LLM kernel regression

Gate: **PARTIAL_PASS**

| Candidate | Kernel | Shape | Phase | Status | Cycle | Log |
|---|---|---|---|---|---:|---|
| C1 | softmax | configured | static | PASS |  | [C1.softmax.configured.static.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C1.softmax.configured.static.log) |
| C4 | softmax_layout_fused | configured | static | PASS |  | [C4.softmax_layout_fused.configured.static.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.configured.static.log) |
| C1 | softmax | prefill_1k | correctness | PASS | 9968770 | [C1.softmax.prefill_1k.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C1.softmax.prefill_1k.correctness.log) |
| C4 | softmax_layout_fused | prefill_1k | correctness | PASS | 10129934 | [C4.softmax_layout_fused.prefill_1k.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.prefill_1k.correctness.log) |
| C1 | softmax | overflow | correctness | PASS | 1625351 | [C1.softmax.overflow.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C1.softmax.overflow.correctness.log) |
| C4 | softmax_layout_fused | overflow | correctness | PASS | 1693835 | [C4.softmax_layout_fused.overflow.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.overflow.correctness.log) |
| C1 | softmax | mask_tail | correctness | PASS | 242333 | [C1.softmax.mask_tail.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C1.softmax.mask_tail.correctness.log) |
| C4 | softmax_layout_fused | mask_tail | correctness | PASS | 246148 | [C4.softmax_layout_fused.mask_tail.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.mask_tail.correctness.log) |
| C4 | softmax_layout_fused | seed_0 | correctness | PASS | 127986 | [C4.softmax_layout_fused.seed_0.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.seed_0.correctness.log) |
| C4 | softmax_layout_fused | seed_1 | correctness | PASS | 126364 | [C4.softmax_layout_fused.seed_1.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.seed_1.correctness.log) |
| C4 | softmax_layout_fused | seed_2986547050 | correctness | PASS | 125617 | [C4.softmax_layout_fused.seed_2986547050.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.seed_2986547050.correctness.log) |
| C4 | softmax_layout_fused | seed_4294967295 | correctness | PASS | 126019 | [C4.softmax_layout_fused.seed_4294967295.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.seed_4294967295.correctness.log) |
| C1 | softmax | prefill_1k | benchmark | PASS | 9919593 | [C1.softmax.prefill_1k.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C1.softmax.prefill_1k.benchmark.log) |
| C4 | softmax_layout_fused | prefill_1k | benchmark | PASS | 10130426 | [C4.softmax_layout_fused.prefill_1k.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.prefill_1k.benchmark.log) |
| C1 | softmax | overflow | benchmark | PASS | 1624468 | [C1.softmax.overflow.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C1.softmax.overflow.benchmark.log) |
| C4 | softmax_layout_fused | overflow | benchmark | PASS | 1691160 | [C4.softmax_layout_fused.overflow.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.overflow.benchmark.log) |
| C1 | softmax | mask_tail | benchmark | PASS | 239497 | [C1.softmax.mask_tail.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C1.softmax.mask_tail.benchmark.log) |
| C4 | softmax_layout_fused | mask_tail | benchmark | PASS | 244003 | [C4.softmax_layout_fused.mask_tail.benchmark.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/regression_results/softmax_rev4_optimization/extended/C4.softmax_layout_fused.mask_tail.benchmark.log) |

| Pair | Standalone cycle | Fused cycle | Overhead | Limit | Status | Reason |
|---|---:|---:|---:|---:|---|---|
| softmax/mask_tail | 239497 | 244003 | 1.88% | 30% | PASS |  |
| softmax/overflow | 1624468 | 1691160 | 4.11% | 30% | PASS |  |
| softmax/prefill_1k | 9919593 | 10130426 | 2.13% | 30% | PASS |  |
