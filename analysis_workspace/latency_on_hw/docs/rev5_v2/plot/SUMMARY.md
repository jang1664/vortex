# Rev5 v2 plots

Completed on 2026-10-09 through `workflow.py pipeline`, using `run.sh`.
Output: `analysis_workspace/latency_on_hw/figure_output.rev5_v2/`.

| Check | Result |
|---|---|
| Workflow compose / prepare / plot | Complete; no failed or blocked stages |
| Llama2 composed rows | 272,580 (251,064 pass; 21,516 estimated) |
| Llama3 composed rows | 272,580 (251,082 pass; 21,498 estimated) |
| Missing latency / power rows | 0 / 0 for both models |
| Duplicate cases | 0 |
| Figures | 11 jobs; 33 PNG/PDF/SVG files |
| Raw databases during plotting | Unchanged |
| Source FPGA image hashes | Match each application's selected image |

V-transpose refinement converged before composition (p95 error: Llama2 1.34%,
Llama3 1.49%). Decode uses 128 generated tokens. Figures include the QK,
head-reorder/V-transpose, and padded C4 decode KV-quant corrections.

Historical per-application FPGA image provenance is preserved through validated
offline inputs; this does not claim that all measurements used one FPGA image
or the current source revision. Rev5 v3 GEMM execution-M changes are deferred
and are not included in these figures.

Evidence: `completion.json`, `input_inventory.json`, `workflow.log`, and
`../refine/completion.json`. The E2E PNG was also visually inspected.
