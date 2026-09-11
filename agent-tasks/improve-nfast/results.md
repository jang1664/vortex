# Improve N-fast verification

Both runs use the configured `build_improve_nfast_vcs` directory, the exact comparison `improve.sh` config, and `ci/run_black.sh xrt-vcs-sim --perf 3`. FSDB and the GEMM latency observer are enabled. The app is `fpint_gemm_ffn_hw`, with `-m M -k 512 -n 512 -q 32 -t 0 -d 0 -r 1`.

| M | Status | Previous GEMM cycles | N-fast GEMM cycles | Previous core cycles | N-fast core cycles |
|---|---|---:|---:|---:|---:|
| 4 | PASS | 6,449 | 6,433 | 12,206 | 12,206 |
| 256 | PASS | 272,870 | 272,869 | 278,684 | 278,684 |

Both M4 and M256 returned zero from both runner and wrapper; `tools/verify_rtl.py` deterministic helpers confirmed PASS and no strict failure. Source hashes remained unchanged during both runs. Each observer emitted one completed GEMM interval and each application reported one core-cycle count. Both FSDB captures exist and are nonempty.

Reproduce with `python3 agent-tasks/improve-nfast/run.py` after configuring the named build directory. Preserve or relocate existing `runs/improve-m4` and `runs/improve-m256` captures first; the runner refuses to overwrite evidence.

Raw manifests, logs, cycles, and FSDB captures are under the ignored `runs/improve-m4/` and `runs/improve-m256/` directories. The root task checks waveform command traversal separately.
