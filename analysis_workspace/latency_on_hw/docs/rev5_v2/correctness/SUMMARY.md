# LLM kernel regression

Gate: **PARTIAL_PASS**

| Candidate | Kernel | Shape | Phase | Status | Cycle | Log |
|---|---|---|---|---|---:|---|
| C1 | head_concat | configured | static | PASS |  | [C1.head_concat.configured.static.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/rev5_v2/correctness/C1.head_concat.configured.static.log) |
| C1 | head_concat | q_head_reorder | correctness | PASS | 114565183 | [C1.head_concat.q_head_reorder.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/rev5_v2/correctness/C1.head_concat.q_head_reorder.correctness.log) |
| C1 | head_concat | kv_head_reorder | correctness | PASS | 1017050 | [C1.head_concat.kv_head_reorder.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/rev5_v2/correctness/C1.head_concat.kv_head_reorder.correctness.log) |
| C1 | head_concat | decode_head_reorder | correctness | PASS | 507577 | [C1.head_concat.decode_head_reorder.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/rev5_v2/correctness/C1.head_concat.decode_head_reorder.correctness.log) |
| C1 | head_concat | v_transpose | correctness | PASS | 2475743 | [C1.head_concat.v_transpose.correctness.log](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/rev5_v2/correctness/C1.head_concat.v_transpose.correctness.log) |

| Pair | Standalone cycle | Fused cycle | Overhead | Limit | Status | Reason |
|---|---:|---:|---:|---:|---|---|
