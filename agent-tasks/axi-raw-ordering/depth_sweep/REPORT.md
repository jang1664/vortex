# AXI inflight-write depth sweep

## Scope and result
The user requested increasing the VX_dp_ram-backed write table depth until
performance saturates. The address-tracking algorithm is unchanged.
`AXI_WRITE_PENDING_SIZE` is now a config define, default16. All tests use VCS
and configured builds; FPGA bitstreams and the running pipeline are untouched.

The matched softmax probe stops being capacity-limited by depth64: both64 and128
reach only36 live entries and never encounter an occupied allocation slot.
Depth32 and128 tie for the lowest cycle count in this deterministic case.
The64/128 cycle spread is only0.27%; larger capacity does not give monotonic
speedup because read scans grow with the number of outstanding writes and
memory request timing changes. Depth64 is sufficient capacity for this case;
this is not a universal optimum across kernels or memory latency settings.

## Matched full-system softmax
C4v4, TH16/MXU16, L2 enabled, cursor fused softmax, batch=head=1,Q=K=32, mask1,
scale0.125, input seed2986547050. Memory RNG seed19; request stalls50/10 and
response stalls75/5; responses remain in order. Build-local ci/run_black.sh
xrt-vcs-sim was used. Exact commands, flags, logs and kernel hashes are retained.

| Depth | Kernel cycles | Change vs16 | Maximum live entries per port | Full-table port-cycles (sum) | Scanned entries (sum) |
|---:|---:|---:|---:|---:|---:|
|16|291410|0.000%|16|87857|2988|
|32|288731|-0.919%|32|71935|6373|
|64|289512|-0.651%|36|0|6263|
|128|288731|-0.919%|36|0|6234|

All four runs PASS with zero errors and identical kernel SHA256
fde8a343d616acffc607ade3d3d036a287021e1c83645ec0b07097561da5ec82.
Depth16 with the read-only bind monitor exactly reproduces the earlier291410
cycle result, confirming instrumentation did not change measured behavior.
The monitor spans all non-reset simulation cycles, slightly more than the
kernel PERF interval. Summed port-cycles are not wall-clock cycles.
`slot_unavailable_cycles` measures unavailability, not demanded write stalls;
in these in-order runs it equals `full_cycles`. At64/128 both are zero.

## Controlled sustained-write benchmark
The existing adapter test scoreboard is reused in a task-local top. One input,
one output group, one physical port,2048 writes, always-ready AW/W, B eligible128
cycles after AW/W pairing. The throughput window is cycles513..1536. Identity,
data, address mapping, credits, pairing, and complete drain are checked.

|Depth|Writes per1024-cycle window|Writes/cycle|Total cycles including fill/drain|Demand backpressure cycles|
|---:|---:|---:|---:|---:|
|16|128|0.125000|16665|14478|
|32|256|0.250000|8361|6174|
|64|512|0.500000|4233|2046|
|128|1008|0.984375|2217|30|
|129|1016|0.992188|2202|15|
|130|1024|1.000000|2187|0|
|256|1024|1.000000|2187|0|
|512|1024|1.000000|2187|0|

This synthetic workload saturates exactly at130 with the current handshake/credit
implementation and latency128. Clock-boundary occupancy from the bind monitor
is129 at depths130/256/512. The test scoreboard's peak130 includes a new AW
before subtracting a concurrent B. An occupied slot cannot be reused until
the next cycle after B, which accounts for the spare entry required for1/cycle.
This benchmark has no reads and therefore does not include address-scan costs
or the full system's downstream flow control. It cannot establish the optimal
depth for the softmax kernel. All8 cases PASS. Ordinary45-case adapter regression
and helper checks also PASS.

## Resource implications
Measured full-system elaboration has28 address bits,8 write-ID bits,4 physical
ports and2 groups. Logical state estimates before synthesis:

|Depth|Address RAM, all4 ports|Other state bits, all4 ports|
|---:|---:|---:|
|16|224 bytes|862|
|32|448 bytes|1574|
|64|896 bytes|2990|
|128|1792 bytes|5814|
|256|3584 bytes|11454|
|512|7168 bytes|22726|

Other state includes ID registers, valid/remaining/match bitmaps, pointers,
controls, synchronous RAM output registers, and2 group admission bits. Formula:
`4*(depth*(8+3) + 2*LOG2UP(depth) + 3 + 28) + 2`.
BRAM granularity can allow deeper address storage without another physical block,
but it does not eliminate this growing register and ID-comparison logic cost.
No physical BRAM/LUT/Fmax claim is made without synthesis.

## Reproduction and artifacts
`measure.py --write-depth N` sources the intended C4 config then appends
`-DAXI_WRITE_PENDING_SIZE=N`. `run_sweep.py` serializes configurations in the
configured build_axi_raw_port, avoiding binaries overwritten by concurrent runs.
The generated VCS Makefile explicitly includes the experiment-only bind monitor
and the existing response-reorder testbench. Monitoring is absent from production
RTL. Production default remains16; tests override depth explicitly.

```bash
python3 agent-tasks/axi-raw-ordering/depth_sweep/run_sweep.py --depths 16 32 64 128
python3 agent-tasks/axi-raw-ordering/depth_sweep/summarize.py
```

- softmax.csv: matched kernel cycle and occupancy results.
- write_pressure.csv: synthetic write throughput and saturation.
- resources.csv: logical memory and register accounting.
- bench_boundary.log: all8 passing benchmark cases and monitor stats.
- ../verify_depth_boundary.json and ../verify_depth_regression.json: deterministic unit reports.

## Depth64 confirmation
Both extra full-system runs PASS with zero errors and the same kernel hash.

|Condition|Depth16 cycles|Depth64 cycles|Change|
|---|---:|---:|---:|
|Normal|164269|164276|+0.0043%|
|In-order stalls|291410|289512|-0.6513%|
|Reordered-response stalls|296909|286589|-3.4758%|

Normal64 is +0.0591% versus the original correct164179-cycle baseline; in-order64
is +1.1502% versus the original correct286220-cycle baseline. Original reordered
RTL failed correctness and is not used as a performance baseline. All64 runs
have no full/unavailable table cycles. Recommended experiment setting for this
workload: `-DAXI_WRITE_PENDING_SIZE=64`; default16 is preserved since this request
was a depth sweep and other workloads/configurations have not been benchmarked.

The read scan loops over live entries, not every unused RAM location. This is why
64 and128 show similar scanned-entry counts once maximum occupancy stays36.
Increasing depth nevertheless permits more live writes than16 and increases
read-scan work. Capacity alone does not make mixed read/write kernels faster
in proportion to the synthetic write-only throughput gain.
