# Fresh complete legacy decoder regression: finite six-hour operation wait

Prepared only, no new simulation launched. Root reviews/releases `bash agent-tasks/c4-sram-flash-attention/legacy_retry_21600000/run.sh`. Exact runner/helper hashes are in `legacy_retry_21600000/source_manifest.json`. This uses a new build/output/evidence directory and refuses existing paths. It never changes the old attempt or active resident/prefill runs.

## Preserved previous terminal result

Session5987 ended with authoritative tool exit2 at04:44:16. The host returned1 through make after `down_proj: status=-1`.36 of38 operations completed; down_proj has no DONE/cycle count, final residual did not start, and the full CPU comparator was not executed. The old wrapper did not capture simulator wait exit; orderly SHUTDOWN/$finish is recorded without inventing exit0. All four launch app/kernel/simv/config-stamp hashes still match, and binaries plus70MB terminal trace are archived in `logs/decoder_legacy/timeout7200000_terminal/`.

The runtime AP_DONE wait returns silent-1 at its deadline; there is no down AP_IDLE message or transport-error diagnostic. The actual down BEGIN observation window is02:40:56–02:48:32, error04:43:54–04:44:16, yielding6922–7400s elapsed bounds that contain7200s. This supports per-operation expiry; it does not distinguish slow progress from a stall. The stale final PERF886277 belongs to ffn_hadamard. `hardware_vcs_timing_comparison.json` records old-image hardware down1895201 cycles separately from measured VCS gate1653476/up1652732 and completed-operation observation bounds. No down progress is inferred from PID/CPU activity.

## Exact new workload and configuration

New configured build: `build_c4_decoder_legacy_6h`, XLEN64,/opt/vortex,$HOME/tools/vortex. Source the same base rev8 C4 config `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh`; never enable GEMM_SRAM_FUSION. Use system GCC/G++ and /usr/bin first on PATH, no DEBUG/DEBUG_AXI/MAKEFLAGS, DISABLE_FSDB and DEBUG_LEVEL=0. No CMD_PERF or passive progress monitor: the existing monitor requires fusion and must remain disabled. Automatic free socket pair, unique SHM, fresh source compile.

Required configured invocation remains `ci/run_black.sh xrt-vcs-sim --app llama_decoder_C4`, args:

```
--model llama3-8b --batch 1 --seq-len 1 --stage decode
--past-kv-len 16 --cache-capacity 32 --mode verify
--timeout-ms 21600000 --attention-backend legacy
--fixture ABS/build_c4_sram_fusion/fixtures/resident_attention/llama3-8b_decode_p16_c32
--output ABS/build_c4_decoder_legacy_6h/results/llama3-8b_decode_p16_c32/legacy_timeout21600000
```

All38 full model operations remain. Per-operation timeout is fixed21600000ms(6h); GNU timeout bounds the build/run/reference body to86400s(24h), TERM followed by30s kill allowance. These are new explicit finite allowances, not an extension of old session5987. Observe after the first5min, then retain actual BEGIN/DONE boundaries and terminal. A live observation yield is not a restart or reason to infer kernel progress.

## Source linkage and complete gates

Before execution, `identity.py` preprocesses the ten touched RTL modules under actual feature-off C4/VCS quiet defines and compares to fixed HEAD251fa5d5 source modules, checked against git object hashes. Only line directives and whitespace-only lines are discarded. Both sides use identical current common include context. Author read-only preflight75709 exit0 proves all10 equal; `logs/decoder_legacy/retry21600000_identity_preflight_v2/manifest.json` links the earlier167440-record whole-core elaboration/6334-GEMM and8406-core cycle identity receipt. This is preprocessing linkage, not new synthesis/elaboration/simulation. The first helper's missing DPI/FPU includes are preserved as a failed preflight; only helper include paths were corrected.

The inner runner sources TVM environment first, then defines only legacy-prefixed paths/arguments and invokes explicit `/home/jaeyongjang/.conda/envs/vortex/bin/python` for the reference comparator. The wrapper is checked byte-for-byte against the installed template with exit recording.

The runner records initial, actual-host-PID-boundary and final dependency/input/binary hashes. Its dependency closure follows the reviewed prefill runner pattern: hw/rtl,dpi,kernel,runtime,sim (including sim/common), exact config generator/build templates, base C4 config, decoder/reference helpers, recursively resolved quoted includes including reused variant TUs, the reference's TVM helpers and its referenced physical profile manifest. It excludes unrelated alias maps/checker workflows. All85 fixture files plus the referenced manifest are hashed. At the actual decoder PID boundary, it archives exact source files and all required app/kernel/ELF/simv/runtime libraries plus generated configuration artifacts. The final gate requires initial=launch=final sources/inputs, launch=final binary/config hashes and exact child exits. A snapshot failure is preserved and cannot pass; it never starts a duplicate or changes the live deadline. The installed opt-in CI recorder supplies real host/simulator exits even on a regular log; forced termination cannot pass. Runtime logs stay sparse existing boundary/REG_READ output. After all operations, the unchanged existing reference.py compare uses the immutable P16/C32 fixture. Final receipt requires actual outer/host/simulator zero exits, source stability, exactly38 unique DONE operations, final verification pass and positive element count, CPU pass_all=true/complete_decoder=true and output-chain pass. Numerical thresholds are unchanged. Any source drift requires independent linkage review; it is not silently accepted. Review the freshly generated compile command for no fusion/debug monitor defines and O2 host flags. The runner automatically records launch provenance once the actual decoder PID is present.

Evidence: `logs/decoder_legacy/timeout21600000`; final results remain under the fresh build. No partial operation subset or intermediate-only comparator may satisfy the full gate. Root owns STATUS; the new process owner must retain authoritative terminal exits. No hardware launch or source edit is part of this request.

Author read-only dependency preflight validated all required source/fixture paths and the installed configured-wrapper identity using the already configured smoke tree; it did not configure/launch the fresh legacy tree or claim its binary/configuration correctness. Receipt: `logs/decoder_legacy/retry21600000_receipt_preflight/preflight.json`. Initial generic-variable draft is preserved in `.pre_review` snapshots. Bash/Python syntax checks pass; root review is still required before launch.
