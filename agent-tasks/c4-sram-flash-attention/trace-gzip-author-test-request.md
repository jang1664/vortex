# Lossless full-prefill trace capture candidate

Task-local author candidate only. No shared CI/parser/RTL files changed, no new VCS workload launched, no existing run restarted or extended. Full prefill144 remains all64 records and256 GEMM jobs. Selected records cannot replace its traffic or hardware numerical gate.

## Candidate boundaries

`trace_gzip_candidate/ci/blackbox.sh.in` adds an opt-in simulator exit receipt, opt-in host exit receipt, and a FIFO-safe early-failure diagnostic. The absent-opt-in launch statement remains exactly the original. The opt-in launcher forwards TERM/INT to the real simulator and waits; any forced stop emits `forced:<actual exit>` and cannot pass collection. Original regular-file early failure still prints the log. The main wrapper remains configured `ci/run_black.sh xrt-vcs-sim`.

Task-owned `trace_gzip_candidate/capture_vcs_trace.py` creates a new `sim/xrtsim_vcs/simv.log` FIFO in an isolated configured build and starts the reader before the required wrapper. It refuses all preexisting artifacts, writes one gzip level1 stream, retains every raw byte including errors/MEM/CACHE/fence records, and records raw SHA256/length and the compressed file SHA256. A fresh decompression pass verifies gzip CRC/trailer and exact raw SHA256/length after EOF and fsync. The supervisor requires actual wrapper, host, simulator and collector success; empty streams, missing exit files, forced stops, collector failures, outer timeout and missing EOF/drain fail. Bounded cleanup signals only the newly created child process groups. Artifacts including FIFO and failed partial gzip files remain for inspection.

The collector receipt is an integrity receipt, never a full-decoder or numerical PASS. Independent existing DMA, all-AFU, completion, ledger and context gates remain required. Existing aggregate provenance hashes the compressed trace file itself; a capture receipt alone does not replace that input hash.

Three parser changes add gzip text opening only when trace suffix is `.gz`: `check_dma_trace.py`, `check_external_trace.py`, and `tools/gemm_command_overlap_summary.py`. Ordinary file opening and each parser's prior decoding/error policy remain unchanged. No regex, record selection, topology/address whitelist, count, numerical threshold or validation changes are included.

## Bounded validation

All tests run against task-local copies. These are OS/process fixtures and archived-log parser tests, not an RTL simulation or proof of a new configured build.

- `logs/trace_gzip_author/bounded_finite/summary.json`:14 checks including exact binary bytes, wrapper/host/simulator failure, missing exit, empty/no-writer input, finite timeout, orphan-writer drain, truncated/corrupt gzip, ENOSPC injection at compressed write, actual candidate run_app startup failure with FIFO and preserved regular-file behavior.
- `logs/trace_gzip_author/additional_finite/summary.json`:3 checks: actual kernel-enforced collector file-size failure and bounded writer cleanup; candidate run_app success with four actual zero exits; forced shutdown forwarding to real fake-simulator PID, exit2 recorded and capture rejected even though host/wrapper exit0.
- `logs/trace_gzip_author/real_traces/summary.json`: complete archived M128, M16 and decoder P16 traces, compressed by the same supervisor through an explicitly mocked wrapper producer. Require raw SHA256 equal to the original full file, then compare complete original-plain, candidate-plain and candidate-gzip DMA/all-AFU JSON after removing only artifact-path fields. Compare all six ledger collections exactly. M16's historical missing ledger must be rejected identically by all readers. No record subset is written or used.

Independent review found that float NaN/infinity bypassed the original positive-only test. The prior collector/source manifest are preserved as `.pre_finite`; `finite_bounds.diff` contains only `import math` and isfinite checks. Final validation rejects NaN,+infinity,-infinity,zero and negative values for both bounds before FIFO/process creation (10 checks in `logs/trace_gzip_author/finite_bounds/summary.json`). The complete17 bounded process checks were rerun after this repair (session22758). Finite valid paths and every archival/parser byte remain unchanged, so prior full-archive proof links through this exact diff.

Final author sessions:79902 exit0 (three complete real-trace parser comparisons),18688 exit0 (final17 process checks),32621 exit0 (final collector rearchives all three real traces, with gzip files byte-identical to those already parsed). `logs/trace_gzip_author/real_traces_v2/summary.json` links final compressed SHA256 and exact raw bytes/hashes. No parser logic changed between these runs. The final collector adds compressed SHA256 and an immediate nonzero-wrapper failure branch; its earlier version is preserved as `capture_vcs_trace.py.v1`.

Independent reruns may select fresh directories without modifying test logic:

```sh
TRACE_GZIP_TEST_OUTPUT=/ABS/new_finite python3 /ABS/task/trace_gzip_candidate/test_finite_bounds.py
TRACE_GZIP_TEST_OUTPUT=/ABS/new_bounded python3 /ABS/task/trace_gzip_candidate/test_capture.py
TRACE_GZIP_TEST_OUTPUT=/ABS/new_additional python3 /ABS/task/trace_gzip_candidate/test_capture_additional.py
TRACE_GZIP_TEST_OUTPUT=/ABS/new_real_traces python3 /ABS/task/trace_gzip_candidate/test_real_trace_equivalence.py
```

The output parent must exist and target must be new. This output-path override was added after author runs solely to avoid overwriting receipts. Tests still use mocked wrappers for archived input, never launch RTL. Current actual code/patch hashes are frozen in `trace_gzip_candidate/source_manifest.json`. Independent review must distinguish capture integrity from all64 prefill execution.

Initial wrapper v1 and test receipts are preserved. Author review found that post-command status capture can prevent shell tail-exec, so v2 preserves the original default launch and explicitly forwards signals in the opt-in branch. This was corrected before any shared installation.

## Future configured invocation and resource gate

After independent review/install, freshly configure an isolated build and source the exact C4 fusion config. Retain all five required trace macros and DISABLE_FSDB. No current run's flags or bounds change. Use absolute paths:

```sh
python3 /ABS/task/trace_gzip_candidate/capture_vcs_trace.py \
  --build /ABS/build_prefill144_trace \
  --output /ABS/evidence/prefill144.simv.log.gz \
  --receipt /ABS/evidence/prefill144.capture.json \
  --timeout FINITE_APPROVED_OUTER_SECONDS --drain-timeout 3600 \
  -- /ABS/build_prefill144_trace/ci/run_black.sh xrt-vcs-sim \
  --app llama_decoder_C4 --args 'FULL_64_RECORD_ARGS_WITH_FINITE_APPROVED_HOST_TIMEOUT'
```

The collector's outer cap includes build, workload and final gzip verification; reserve a finite drain allowance within it. `--drain-timeout 3600` allows final verification of the entire large stream, not extra kernel work. The parser accepts `.gz` directly; never materialize a second full raw trace. The wrapper does not currently forward run-only flags for this mode; the normal build phase remains enabled. Inspected `build_driver` invokes simv/applib targets without `clean`, so it does not intentionally remove the precreated FIFO. Final FIFO type is checked. Use no `--nohup`/temporary-build mode.

Historical estimates remain175.6GB raw, ~14GB gzip, and51–59 wall hours under similar conditions, not observed prefill runtime or a guaranteed bound. Current free space was67GiB at03:27; new FPGA outputs and other logs can change it. A new finite host/outer allowance and fresh disk check are root-owned launch prerequisites. Existing7200000ms/43200s bounds are insufficient for that estimate and remain unchanged on current runs. Full64-record hardware numerical correctness remains a separate required gate.
