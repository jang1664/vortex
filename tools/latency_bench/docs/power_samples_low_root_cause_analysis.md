# `power_samples_low` Root-Cause Analysis

Date: 2026-07-29

## Summary

The observed C4 `power_samples_low` failures were not caused by the automatic kernel-iteration calculation producing a power phase shorter than ten seconds. Successful measurements at the same neighboring shapes ran for approximately ten seconds and collected 116--130 samples.

The failing measurements had zero samples, a missing power CSV, or an empty power summary. At the same wall-clock time, benchmark logs and runner status CSV rows were also truncated in the middle of writes. The root filesystem was reported as 100% used, with approximately 12 GB available at inspection time. The evidence therefore points to a transient filesystem write failure, most likely storage exhaustion, followed by insufficient error propagation from the sampler child process.

The sampler invocation point should not be moved based on this incident. Its current placement before XRT initialization is deliberate and protects against inherited BO-mapping synchronization failures.

## Two different sample thresholds

The benchmark uses two thresholds with different meanings:

- `power_target_samples=100` determines whether samples collected during the latency phase are sufficient to skip the separate power phase.
- `power_min_samples=5` is the latency-bench validity threshold. A final power result is classified as `power_samples_low` when the summary is missing, the sample count is unavailable, or fewer than five samples were recorded.

The C4 failures were therefore not cases with 59 or 99 samples. They were cases with an empty or missing summary and effectively zero usable samples.

## Measurement sequence

The current sequence is:

1. Fork the latency sampler before opening XRT.
2. Collect idle samples.
3. Stop the idle sampler.
4. Start the latency sampler.
5. Open and initialize XRT and its buffers.
6. Mark the latency window immediately before the measured iterations.
7. Run the latency iterations.
8. Mark the end of the latency window and stop the sampler.
9. If fewer than 100 latency-window samples were captured, reset the capture files and enter the separate phase.
10. Calculate `power_kernel_iterations` from the first measured FPGA cycle count.
11. Start a new sampler before the separate idle and kernel phases.
12. Collect two seconds of idle power.
13. Run the kernel for the planned iteration count, targeting ten seconds.
14. Stop the sampler and generate the power summary.

The latency sampler is intentionally forked before XRT initialization. `LatencyPowerMeasurement::prestart()` documents that forking after XRT opens can inherit BO mappings and break later device-write/host-rewrite synchronization. Any fix should preserve this ordering.

## Automatic iteration calculation

Auto mode calculates:

```text
kernel_seconds = fpga_cycle / fpga_frequency_hz
power_kernel_iterations = ceil(power_target_seconds / kernel_seconds)
```

When an FPGA cycle count is unavailable, host latency is used as the fallback. The C4 measurements used the FPGA-cycle path and the C4 clock parsed from the xclbin information.

Representative successful `kv_cache_dequant_w4a16` results were:

| K | Estimated single-run duration | Kernel iterations | Actual power run | Samples |
| ---: | ---: | ---: | ---: | ---: |
| 2176 | about 42 ms | 239 | 9.93 s | 129 |
| 4097 | about 77 ms | 130 | 10.10 s | 124 |
| 4129 | about 79 ms | 126--127 | 9.86--9.93 s | 116--119 |
| 4224 | about 81 ms | 124 | 9.89--9.97 s | 118--123 |

These results show that the iteration calculation produced the intended duration. Neighboring shapes that appeared among the failures also succeeded in the other model run or in another quantization direction, further ruling out a deterministic duration error for those shapes.

## Effective sampling interval

The separate phase uses the default `power_interval=0.05`. This is distinct from `power_latency_interval`, which the current hardware run sets to 0.1 seconds for the latency phase.

The sampler shell script does substantial work before each sleep:

- launch `date`;
- read eight sysfs sensors through separate `cat` commands;
- launch `awk` to compute power values;
- run `wc` and `xargs` to enforce the output size limit;
- append through `tee`;
- sleep for the configured interval.

Consequently, `0.05` is an additional sleep after sample processing, not a strict 20 Hz period. The observed effective interval was approximately 0.075--0.085 seconds. Collecting 116--130 samples in ten seconds is consistent with this implementation.

This overhead could matter if exactly 200 samples are required, but it does not explain the observed zero-sample failures or the current five-sample validity threshold.

## Failure evidence

The affected C4 runs showed all of the following in the same approximate 15:52--15:54 KST window:

- missing power CSV files;
- zero-byte power summaries;
- zero-byte sampler logs;
- sampler CSV output truncated in the middle of a row;
- benchmark logs truncated in the middle of a `run_progress` line near nine seconds;
- a 66-column `progress.csv` row containing 83 fields because the following case was appended to an incomplete row;
- a `run_status.csv` path truncated mid-string and immediately followed by the next case;
- failures in both independent Llama2 and Llama3 runs during the same wall-clock interval;
- a root filesystem reported as 100% used during investigation.

This pattern is incompatible with a simple kernel-duration underestimate. It indicates that writers stopped partway through output. A literal `No space left on device` message was not preserved, but the files that would have contained that message were themselves empty or truncated.

## Error-propagation weakness

`PowerSampler::start()` currently verifies only that:

- the sampler script is executable;
- the sampler log can be opened;
- `fork()` succeeds.

The parent returns success immediately after the fork. It does not verify that the child successfully completed `exec()`, resolved its sensors, created the CSV header, or remained alive. If the sampler child exits because of a write error, the benchmark may continue through the idle period and the full ten-second kernel run before discovering that no usable summary exists.

The sampler script also uses `set -euo pipefail`. A failed `tee` or another failed filesystem operation terminates it immediately. The parent currently has no readiness or health channel through which to receive that failure.

The runner correctly detects the missing result afterward through `power_min_samples`, but at that point the hardware time has already been spent and the run-local progress files may also have incomplete writes.

## Root-cause assessment

The evidence supports the following chain:

```text
transient filesystem write failure, likely storage exhaustion
  -> measure_power.sh or its tee pipeline exits early
  -> PowerSampler does not immediately observe the child failure
  -> the benchmark continues the power kernel phase
  -> the power CSV or summary is empty or missing
  -> latency-bench observes fewer than five usable samples
  -> status becomes power_samples_low
```

Confidence is high that the automatic iteration count is not the primary cause. Confidence is also high that the direct failure was in output recording. Storage exhaustion is the leading system-level explanation, although the original write error was not retained and therefore cannot be proven from an explicit error string.

## Recommended follow-up

Preserve the current sampler/XRT ordering and address robustness instead:

1. Ensure sufficient free space before launching a hardware run and monitor it while large C4 suites run.
2. Add a child-readiness handshake that confirms successful `exec()`, sensor discovery, and CSV creation without moving the pre-XRT fork point.
3. Check child liveness before beginning the separate kernel phase and after the idle phase.
4. Propagate child exit status and write errors explicitly to the benchmark result.
5. Record `errno` and sampler exit status in a small, independently written status artifact.
6. Make runner progress/status publication atomic so a failed write cannot concatenate two logical rows.
7. Keep `raw_db.csv` authoritative and retain its atomic replacement behavior.
8. Add tests for sampler child exit, empty summary, ENOSPC-style write failure, and recovery through retry.

Optimizing `measure_power.sh` to avoid many subprocesses per sample is a separate improvement. It would make the requested interval closer to a true sampling period, but it is not required to correct this incident's zero-sample failure.
