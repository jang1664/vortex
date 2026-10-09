# Rev5 v2: C4 padded decode KV quant remeasurement

Completed 2026-10-09 using `workflow.py pipeline`. Both models used the Rev5 C4 `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_fix_pad` image.

36/36 physical latency/power cases passed (18 per model). This is benchmark execution status, not a new output-value functionality check.

Scope: decode K/V append, batch 1/4/64, cache positions 1024/2048/4096/8192/16384/32768, capacity 65536. K source rows8; V source rows8 (B1/B4) or64 (B64). Identical execution arguments share measurements. Prefill and other applications were not measured.

Each model retained its original board: Llama2 `0000:2a:00.1`, Llama3 `0000:3d:00.1`.

| Model | Quant | Physical rows | Cases | Old compact cycles (mean) | New padded cycles (mean) | Change | New PCIe power W (mean) |
|---|---|---:|---:|---:|---:|---:|---:|
| llama2 | K | 8 | 6 | 29,236.0 | 32,653.7 | +11.69% | 22.659 |
| llama2 | V | 8 | 6 | 29,551.3 | 33,088.0 | +11.97% | 22.659 |
| llama2 | V | 64 | 6 | 29,551.3 | 33,130.8 | +12.11% | 22.667 |
| llama3 | K | 8 | 6 | 29,258.3 | 32,696.7 | +11.75% | 22.098 |
| llama3 | V | 8 | 6 | 29,583.3 | 33,203.0 | +12.24% | 22.099 |
| llama3 | V | 64 | 6 | 29,583.3 | 33,149.5 | +12.05% | 22.113 |

Old compact measurements are retained as history. New padded arguments have distinct execution keys and are selected by the regenerated suites. Original Rev5 databases, Rev5 v2 C1/C3 databases, and all historical Rev5 v2 C4 rows are unchanged. Compose/prepare/plot were not run.

Artifacts: `run.sh` (exact environment/command), `selection.json`, `comparison.csv`, `completion.json`, `workflow.log`, and `baseline.json`. A preliminary run with a subset candidate setting was rejected before measurement because its generation receipt did not match; the final command uses the full generated candidate set with an KV-quant/padded-source case filter (only the C4 suite contains these cases).
