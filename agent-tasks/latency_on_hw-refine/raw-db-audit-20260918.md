# `th16_20260917` raw DB audit

Audit snapshot: 2026-09-18 13:13 KST. The six raw databases were no longer
being written when this audit ran. The complete machine-readable report is
[`raw_db_audit_20260918.json`](raw_db_audit_20260918.json).

## Result

| Model/bin | Rows | Unique executions | Failed rows | Minimum power samples | Total power range (W) | Dynamic power range (W) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| llama2/C1 | 108 | 108 | 0 | 95 | 33.873–34.757 | 0.982–1.925 |
| llama2/C3 | 84 | 84 | 0 | 79 | 34.547–35.663 | 1.169–2.465 |
| llama2/C4 | 827 | 827 | 0 | 44 | 32.504–34.991 | 0.259–2.844 |
| llama3/C1 | 116 | 116 | 0 | 96 | 33.976–34.676 | 1.058–2.006 |
| llama3/C3 | 92 | 92 | 0 | 80 | 34.146–35.610 | 0.957–2.491 |
| llama3/C4 | 897 | 897 | 0 | 40 | 32.375–34.878 | 0.201–2.774 |

All 2,124 rows are `pass`; every execution key is unique. All rows have finite,
positive latency, FPGA-cycle, elapsed-power, sample-count, and total-power
values. There are no nonzero return codes, parse errors, missing source files,
missing required metrics, latency ordering violations, or power min/avg/max
ordering violations. The 2,124 attempt-history rows also contain no failures or
retries.

The official project parsers reproduced every stored value from its source:

- 0 latency mismatches against the referenced benchmark CSV files
- 0 FPGA-cycle mismatches against the referenced logs
- 0 power mismatches against the referenced power summary files

Each database contains the expected candidate alias and one xclbin SHA for that
candidate. Every row records a 10 ns FPGA period. The pipeline's strict coverage
check accepted all 12 model/stage/bin measurement tasks, so the generated
prefill and generation suites have the required compatible measurements.

## Values that deserve attention

Seven long-running C1 TCU rows have `power_raw_truncated=1` because the 1 MiB
raw power CSV limit was reached:

- llama2: `81b4ddc389`, `f544b77e86`, `934292b08c`
- llama3: `de8ed46daf`, `88a756676a`, `dcd4337f83`, `542522e4f7`

Their latency ranges from about 1,108 to 2,674 seconds and each still has
8,047–8,157 valid power samples. Their stored summary is internally consistent,
but the samples cover only the captured prefix of the run. Remeasure these seven
with a larger `--power-csv-max-bytes` value before treating their power or
energy numbers as full-run measurements.

The largest latency values are not malformed. They belong to the largest TCU
GEMMs and reach about 2,674 seconds. Their wall latency, FPGA-cycle time, and
power-phase duration agree. Across measurements lasting at least 100 ms, the
95th percentile difference between wall latency and cycle-derived latency is at
most 1.12%. Short kernels show a larger relative difference because the wall
measurement includes fixed host/XRT overhead while FPGA cycles do not.

Exact execution keys shared by llama2 and llama3 provide a repeatability check.
Total power is stable: its 95th percentile relative difference is below 0.86%
for C1/C3/C4 and the maximum is 1.53%. FPGA-cycle latency is also generally
stable, with 95th percentile differences of 1.37% (C1), 0.81% (C3), and 1.54%
(C4). A few C4 rows are noisier; the largest is `rope` at
`-batch 1 -seq 8192 ...`, whose cycle count differs by 9.18% between runs.

Dynamic power is only about 0.2–2.8 W after subtracting a roughly 32–33 W idle
baseline. Its relative run-to-run difference is therefore larger: median
5.4–7.6%, with a maximum of 52.6%, although the maximum absolute difference is
under 0.43 W. Total-power TOPS/W is well supported by these measurements;
dynamic-power TOPS/W should retain this baseline-subtraction uncertainty.
