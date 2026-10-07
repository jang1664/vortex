# Rev5 PV-only workflow refresh

Status: complete. 60/60 latency+power measurements passed, with original board identities preserved.

- Model tag: `th16_20261007_rev5_pipeline`. Candidate map: `candidate_fpga_bins.rev5.yaml`. C4 alias: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_fix_pad`.
- Each model: six prefill PV shapes and 24 generation PV shapes. Filters: `app=fpint_gemm_ffn_hw` and `name=attn_pv`.
- Existing workflow `--from run --to run --rerun run` staged measurements and replaced successful rows. Generation was run first because the selectively cloned rev5 initially had no generated-suite receipts.
- Preserved shape policy, warmup=0, iterations=1, power auto repetitions targeting 10 seconds, idle stability policy and latency sampling interval 0.1 seconds. This is benchmark execution PASS, not a new numerical-reference validation.
- All non-PV C4 dictionaries are unchanged; C1/C3 raw DBs are byte-identical. The physical key set is unchanged.

| Model | Replaced PV | Preserved C4 rows | Board |
|---|---:|---:|---|
| llama2 | 30 | 390 | `0000:2a:00.1` |
| llama3 | 30 | 431 | `0000:3d:00.1` |

[Exact workflow command](run_workflow.sh), [workflow log](workflow.log), [PV before/after comparison](comparison.csv), [verification](completion.json), [updated full rev4/rev5 comparison](../th16_20261007_rev5_pipeline_results/comparison.csv).

Original raw DBs and comparison reports are backed up in this directory. Updated raw DBs:

- [llama2 C4](../../outputs_llama2_main.th16_20261007_rev5_pipeline/C4/raw_db.csv)
- [llama3 C4](../../outputs_llama3_main.th16_20261007_rev5_pipeline/C4/raw_db.csv)
