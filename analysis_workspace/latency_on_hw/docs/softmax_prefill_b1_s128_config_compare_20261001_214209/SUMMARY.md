# Softmax prefill B1 S128: five-config xrt-vcs-sim comparison

## Workload

- Case: `derived_from_llama3_prefill_batch1_softmax_s128`
- Case source: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/generated_suites/llama3_8b_main_full.th16_20260920_c4_slots16_v2r1/C1_prefill/llama3_8b_prefill_C1_softmax_C4.pkl`
- App: `softmax`; variant: `rev2_shuffle_grouped`
- Arguments: `-batch 1 -heads 1 -seqq 128 -seqk 128 -seqk-stride 128 -mask 1`
- FP16 input/output, causal mask, default scale 1/sqrt(64)=0.125. Deterministic initialize_softmax_scores provides the same input to every config.
- This latency_on_hw case measures one attention head (128 rows x 128 columns), not all heads/layers of the model.
- Metric: core cycles from `vx_dump_perf`, measured over one kernel launch on a fresh simulation. Host wall time includes compilation and is not the latency comparison metric.
- Runs use ci/run_black.sh xrt-vcs-sim from five independent configured build directories. Waveform dumping is disabled through MAKEFLAGS=FSDB_DUMP=; no hardware config overrides are added.

## Results

| Config | Passed | Core cycles | Delta vs original C1 | Relative change | Speedup | Instructions |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `tcu_th16_c1.sh` | yes | 366,204 | +0 | +0.000% | 1.0000x | 1,290,016 |
| `tcu_th16_c1_v2.sh` | yes | 364,738 | -1,466 | -0.400% | 1.0040x | 1,290,016 |
| `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr.sh` | yes | 361,071 | -5,133 | -1.402% | 1.0142x | 1,290,016 |
| `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr.sh` | yes | 361,071 | -5,133 | -1.402% | 1.0142x | 1,290,016 |
| `improve_th16_tcol16_m16_t8_bigmem_all_bram_v2.sh` | yes | 361,277 | -4,927 | -1.345% | 1.0136x | 1,290,016 |

## Configuration differences

| Config | L2 | I-cache (KiB) | D-cache (KiB) | LMEM (KiB) | D-cache banks |
| --- | --- | ---: | ---: | ---: | --- |
| `tcu_th16_c1.sh` | on | 16 | 16 | 1024 | default (2) |
| `tcu_th16_c1_v2.sh` | off | 32 | 32 | 2048 | default (2) |
| `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr.sh` | off | 32 | 32 | 1024 | 4 |
| `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr.sh` | off | 32 | 32 | 1024 | 4 |
| `improve_th16_tcol16_m16_t8_bigmem_all_bram_v2.sh` | off | 32 | 32 | 1024 | default (2) |

C1 versus C1 v2 changes L2 enable, L1 capacities, and LMEM capacity together. Their cycle difference cannot isolate the effect of L2 alone. The source variant is identical across all runs, but each kernel is built with its config. C1 v2 has different LMEM partition constants and hence a different kernel binary hash. C1/C2/C3/C4 share an identical kernel binary in this run.

## Reproduction and evidence

- Source snapshot: `/tmp/vortex_softmax_compare_j_ndwifz/source`
- Git HEAD at capture: `1e4b367cca8f1a11cff74ce6b428079621b3a398`
- experiment.json records the selected case and environment; source_sha256.json records captured source hashes.
- Config copies and command.sh, raw host logs, simv logs, compile logs, U55C model manifests and result.json are under config_1 through config_5.
- The original 1024x1024 case was intentionally stopped at the user request. This experiment uses a derived 128x128 case, with the same source snapshot and hardware configs.

### Config 1

- Config: `tcu_th16_c1.sh`
- Build: `/tmp/vortex_softmax_compare_j_ndwifz/source/build_1`
- Log: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/softmax_prefill_b1_s128_config_compare_20261001_214209/config_1/run_attempt_1.log`
- Kernel SHA256: `678edd317ad38e82cbc6927b2cf46caac86888007cf3fed5b54665d3308bcdbb`

### Config 2

- Config: `tcu_th16_c1_v2.sh`
- Build: `/tmp/vortex_softmax_compare_j_ndwifz/source/build_2`
- Log: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/softmax_prefill_b1_s128_config_compare_20261001_214209/config_2/run_attempt_1.log`
- Kernel SHA256: `34352cffc7d8ce986dcd5893835da0f45bc5af86b5aec3becf831dd1568dbc88`

### Config 3

- Config: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr.sh`
- Build: `/tmp/vortex_softmax_compare_j_ndwifz/source/build_3`
- Log: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/softmax_prefill_b1_s128_config_compare_20261001_214209/config_3/run_attempt_1.log`
- Kernel SHA256: `678edd317ad38e82cbc6927b2cf46caac86888007cf3fed5b54665d3308bcdbb`

### Config 4

- Config: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr.sh`
- Build: `/tmp/vortex_softmax_compare_j_ndwifz/source/build_4`
- Log: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/softmax_prefill_b1_s128_config_compare_20261001_214209/config_4/run_attempt_1.log`
- Kernel SHA256: `678edd317ad38e82cbc6927b2cf46caac86888007cf3fed5b54665d3308bcdbb`

### Config 5

- Config: `improve_th16_tcol16_m16_t8_bigmem_all_bram_v2.sh`
- Build: `/tmp/vortex_softmax_compare_j_ndwifz/source/build_5`
- Log: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/softmax_prefill_b1_s128_config_compare_20261001_214209/config_5/run_attempt_1.log`
- Kernel SHA256: `678edd317ad38e82cbc6927b2cf46caac86888007cf3fed5b54665d3308bcdbb`
