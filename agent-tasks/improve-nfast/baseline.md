# Retained K-fast baseline

Both pre-change improve captures exist under `agent-tasks/gemm-naive-improve-baseline/p4-candidate/`: `improve-m4-iteration1` and `improve-m256-iteration1`. Their FSDB files are approximately 59 MB and 418 MB. Both wrapper results pass the deterministic `tools/verify_rtl.py` helpers, with no strict failures or source changes during capture.

| M | GEMM cycles | Core cycles |
|---:|---:|---:|
| 4 | 6,449 | 12,206 |
| 256 | 272,870 | 278,684 |

The recorded CONFIGS string exactly matches the current sourced improve comparison configuration plus `GEMM_LATENCY_OBSERVER`. Application source hashes match. The FSM hash before this experiment matches both retained captures. The pre-edit manifest hash audit is saved in `runs/baseline-source-check.json`.

Differences since capture belong to naive modules, the old input packetizer no longer instantiated by improve, the naive-only testbench FSDB branch, and the recently added `GEMM_NAIVE` branch in `VX_config.vh`. The latter leaves improve config preprocessing identical, as recorded in `agent-tasks/naive-weight8-parameter-audit/runs/config-identity/result.json`. The baseline config file at the recorded Git revision has the same content as HEAD; its worktree change is only the guarded naive weight-slot default. These differences do not alter the selected improve datapath used for this comparison.

`check_wave.py` independently sampled both original FSDB files strictly before rising edges. It checked all accepted Input ARM coordinates (1,024 at M4; 2,048 at M256), K-fast traversal, consecutive work identifiers within each macro tile, and the expected accepted Input counts (4,096 and 262,144). The new captures will be checked by the same script with N-fast expectations.

No baseline rerun is needed. New simulation manifests capture the N-fast FSM source and all other current sources; those runs must have no concurrent source changes.
