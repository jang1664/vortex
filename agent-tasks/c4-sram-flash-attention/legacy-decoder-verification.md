# Full legacy decoder verification

This record supplements `compatibility-verification.md`. The full legacy decoder VCS gate is **not passed**: both complete-workload attempts that reached execution exceeded the existing per-operation wait limit at `q_proj`. No production RTL, decoder source, fixture contents, or timeout defaults were changed for these attempts.

## Workload and isolation

The workload is the complete Llama3-8B decoder, batch 1, sequence length 1, decode with 16 past KV positions and capacity 32, legacy attention backend, verify mode. It retains all 38 operations, nine GEMMs, and 23 GEMM jobs. The fixture is `build_c4_sram_fusion/fixtures/resident_attention/llama3-8b_decode_p16_c32`.

The configured build directories are `build_c4_decoder_legacy` and `build_c4_decoder_legacy_quiet`. Both use the rev8 C4 base configuration `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh`, without fusion, system host compilers, the required `ci/run_black.sh xrt-vcs-sim` wrapper, and distinct shared-memory paths. The TVM environment is sourced before the C4 configuration. The CPU comparator runs only after a successful complete app execution.

## Completed attempts

| Attempt | Terminal result | Evidence |
|---|---|---|
| Initial 300-second observation | Outer timeout, exit 124, during setup before the first operation | `logs/decoder_legacy/attempt_300s_status.json` |
| Warm 1800-second run, `--debug 0`, explicit `DEBUG_LEVEL=0` and `DISABLE_FSDB` | App error `q_proj: status=-1`, wrapper exit 2; outer timeout did not expire | `logs/decoder_legacy/attempt_1800s_status.json` |
| Isolated 1800-second run without `--debug`, explicit `DEBUG_LEVEL=0` and `DISABLE_FSDB` | Same per-operation error at `q_proj`, wrapper exit 2; outer timeout did not expire | `logs/decoder_legacy/quiet_attempt_1800s_status.json` |

The second attempt completed only `attention_norm`, in 50,639 cycles. It began `q_proj`, whose weight-slot activity continued through cycle 40,646 / sequence 4,420 before the wait failed. These are progress observations, not a completed GEMM cycle count. No simulator fatal was found. All processes in that build had exited when terminal status was recorded. The CPU comparator did not run.

`Decoder::launch` in `tests/regression/llama_decoder_C4/decoder.cpp` passes a fixed 300,000 ms to `vx_ready_wait`. The active XRT runtime returns -1 on that elapsed wall-time limit. Increasing an outer shell timeout does not extend this individual operation limit.

Setup itself uploads substantial data: the 76 fixture files total 136,390,434 bytes, and the allocation zero-fill followed by fixture upload sends that volume twice, before scratch-buffer allocations. The first operation was eventually reached; the initial absence of a `BEGIN` marker was not evidence of a simulator deadlock.

## Quiet retry

`--debug 0` still makes `ci/run_black.sh` append `DBG_TRACE_*` definitions and makes `blackbox.sh` select debug compilation. Several GEMM queue `$display` calls are controlled by `DBG_TRACE_GEMM` alone, so `DEBUG_LEVEL=0` does not suppress them.

The supported quiet invocation omits `--debug`, unsets inherited `DEBUG` and `DEBUG_AXI`, and adds only `-DDISABLE_FSDB -DDEBUG_LEVEL=0` to the base configuration. It preserves the full workload and the default per-operation timeout. The prepared and launched script is `logs/decoder_legacy/run_quiet_prepared.sh`; its log is `quiet_attempt_1800s.log`. The raw compiler-command evidence is collected in `quiet_flags_observed.json`.

The actual runtime and app compiler commands both used `-O2 -DNDEBUG`, with no `DEBUG` or `DEBUG_AXI` definition. The actual vlogan command contained no `DBG_TRACE_*` definitions or fusion definition. All ten touched RTL source hashes matched the final feature-off manifest (`quiet_source_hashes.json`). Vendor-generated simulator C compilation has its own flags; this host optimization observation is not a claim about every vendor compilation stage.

The quiet retry completed `attention_norm` in the same 50,639 cycles and then exceeded the unchanged 300,000 ms wait at `q_proj`. Session 50823 returned exit 2; terminal state was observed at 2026-10-23 20:20:52 KST. The outer 1800-second timeout did not fire. No simulator fatal was found, no build processes remained, and the CPU comparator did not run. `quiet_simv_1800s.log` is 852,565 bytes and contains no GEMM `SLOT_*` trace output. The testbench's unconditional control-register polling still produces log lines, so this supported quiet invocation does not mean zero simulator output.

The quiet invocation alone therefore does not make the full decoder fit the current per-operation wait. A subsequent complete VCS attempt needs an explicitly extended operation wait, while retaining the current default for ordinary runs. The active runtime has no existing environment override for the caller's wait: `VXDRV_KERNEL_TIMEOUT_MS` exists only in an obsolete runtime source, not the `runtime/xrt/vortex.cpp` compiled by the active Makefile.

The parent's separate unchanged-rev8 FPGA baseline results do not constitute a full-decoder pass for the current RTL simulation.

## Host timeout option after the failed attempts

The decoder now accepts `--timeout-ms N`, a positive decimal uint32 value. The existing extent parser performs conversion and range checking; a timeout-specific character check also rejects signed and malformed input. `main.cpp` defaults to 300000, passes the value into `Decoder`, and `Decoder::launch` forwards the stored value to its sole `vx_ready_wait` call. The constructor also defaults to 300000 and rejects zero. Its only call site is `main.cpp`. The workload, kernel, numerical gates, and runtime implementation are unchanged by this option.

Only `decoder.h`, `decoder.cpp`, `main.cpp`, and the timeout paragraph in `README.md` were edited for this extension. Existing resident-attention changes in these files were retained. Exact final file hashes and all 17 CLI results are in `logs/decoder_legacy/timeout_host_checks.json`; the host build log is `timeout_host_build.log`.

Host-only build, from the repository root:

```bash
source configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh
unset DEBUG DEBUG_AXI
export CC=/usr/bin/gcc CXX=/usr/bin/g++
export CONFIGS="$CONFIGS -DDISABLE_FSDB -DDEBUG_LEVEL=0"
cd build_c4_decoder_legacy_quiet
make -C tests/regression/llama_decoder_C4 llama_decoder_C4
```

This target returned zero and compiled only the host executable with `-O2 -DNDEBUG`. CLI checks invoke that executable with `LD_LIBRARY_PATH` pointing to this build's `runtime` directory. `--help`, `--timeout-ms 1 --help`, `--timeout-ms 300000 --help`, `--timeout-ms 7200000 --help`, and the uint32 maximum all returned zero. Zero, negatives (including unsigned-wrap edge input), malformed text, decimal fractions, overflow, whitespace/sign prefixes, empty input, and a missing value all returned one. These checks exercise the actual parser before device startup. Default preservation was also inspected at both the main initializer and constructor declaration; the host checks do not claim device execution.

## Explicit extended-wait full retry

A new full legacy retry uses `--timeout-ms 7200000` with an outer `timeout 43200s`, retaining the same model, complete workload, fixture, and CPU comparison gate. `logs/decoder_legacy/run_timeout7200000.sh` writes to `legacy_timeout7200000`, preserving all earlier results. Its wrapper log is `timeout7200000_run.log`. The isolated simulator configuration stamp was touched to force current RTL recompilation; no production RTL or trace definitions changed for this run.

`timeout7200000_sources.json` records 19 source hashes, including the later controller's nonsynthesizable command-ledger update. `logs/cmd_perf_ledger_identity/noninstrumented_linkage.json` records that controller update's selected-source identity with its trace macro absent. All 19 sources still matched at simulator/app startup. `timeout7200000_artifacts.json` records the fresh app, kernel, simulator, and configuration-stamp hashes and confirms no fusion, `DBG_TRACE_*`, or command-ledger trace definitions.

This retry is running under child process session 5987. Actual `BEGIN`/`DONE` observations are retained in `timeout7200000_progress.jsonl` and `timeout7200000_latest.json`. Simulator busy state and CPU usage establish only process activity; they do not establish forward execution progress or a numerical pass. The full gate remains unpassed until authoritative app completion and CPU comparison succeed.

### Completed attention boundary diagnostic

After 28 operations completed and `o_proj` began, the 92 completed binary dumps through concat plus the fixed catalog were copied into `logs/decoder_legacy/partial_attention_timeout7200000/snapshot`. Only explicitly completed outputs were included; `o_proj`, final output, and later outputs were excluded. Each copy was checked against catalog size, unchanged source inode/size/mtime, and source/copy SHA-256. The live simulation was untouched.

The unmodified CPU comparator returned exit 1 on this partial snapshot: 12 chain checks, nine passes, and failures for scores, context, and concat. It explicitly reports `complete_decoder=false`. Scores have maximum absolute error 0.03125 and 4.4118% violating elements; context/concat have maximum absolute error 0.00244140625 and 2.1484% violating elements. There are no nonfinite values. Since final output is absent, the existing comparator skips its same-input and quantization replay block; this partial result does not establish a local operation defect or a full decoder result. The full comparator remains scheduled after complete app execution.

All **92 completed binary dumps are byte-identical** to the parent's unchanged-rev8 hardware baseline, including scores, probabilities, context, concat, and packed KV/qparam data. That hardware report has the same three chain failures and passing same-input checks. This supplies historical context and completed-boundary byte identity, not a full current-RTL numerical pass. Exact partial metrics, snapshot manifests, command/log, and byte identities are retained as `summary.json`, `snapshot_manifest.json`, `reference_compare.log`, `old_hardware_context.json`, and `old_hardware_dump_identity.json` under the partial diagnostic directory.

### First full FFN projection completed

At 00:20:52 KST on October 24, the unchanged live session 5987 reported `DONE gate_proj cycles=1653476` and `BEGIN 32 up_proj`. The previous observation at 00:18:47 still showed gate running. Gate therefore completed within its finite 7200000 ms wait, about 112–114 minutes after its observed start. This is an actual completed large GEMM, not an estimate from busy state. The resulting throughput is approximately 242–247 cycles/s, subject to observation/start-time uncertainty. Up projection, later stages, and the final comparator remain pending. The full gate is not passed. Receipt: `logs/decoder_legacy/timeout7200000_gate_completed.json`.

At 2026-10-24 02:14:37 KST, the unchanged full legacy session 5987 reported `DONE up_proj cycles=1652732` and `BEGIN 33 silu`. The prior observation at 02:12:37 still had up_proj active. This is another completed operation, not a complete decoder pass. The final comparator remains required.

At 2026-10-24 02:48:32 KST, unchanged session5987 reported `DONE ffn_hadamard cycles=886277` and `BEGIN 36 down_proj`. Only down projection and final residual remain; full terminal success and CPU comparison are still required.

## Terminal: quiet full legacy retry, 2026-10-24 04:44

Session5987 ended exit2 with host down_proj status=-1 after36/38 completed operations. No down DONE or final residual and no full CPU comparator. Old binary hashes match launch; archived terminal evidence and read-only hardware/VCS timing comparison are under `logs/decoder_legacy/timeout7200000_terminal`. AP_DONE deadline expiry is supported by the runtime branch and6922–7400s observation interval containing7200s; slow versus stalled execution remains unresolved. The final PERF886277 is the preceding ffn_hadamard, not down progress. This is not a full regression PASS. A separate full38-op six-hour/24-hour candidate is prepared in `legacy_retry_21600000`; not launched by this receipt.
