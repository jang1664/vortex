# MXU16 TMEM bank-count performance comparison

> Correction (2026-09-06): the 8-bank runs reported application PASSED but also
> emitted a time-zero `Error:` from `VX_gemm_node.sv:1672`, which still requires
> 512 KiB total TMEM capacity. The collector matched `ERROR:` but missed `Error:`.
> Raw cycle readings below are preserved, but the 8-bank profile is not an
> error-free RTL validation. Resolve the capacity constraint before treating
> these runs as a fully validated supported configuration.

## Scope and metric

Compare `fpint_gemm_ffn_hw` with `ci/run_black.sh xrt-vcs-sim --perf 3`,
using M=1,4,256 and K=N=256, QBLK=32, QDIR=0, WTRANS=0.
K/N and quantization/layout settings are explicit assumptions because the
request only specified M. Each case has three independent simulator launches,
with one application repetition per launch. Report median and full range.

The primary metric is `total_cycles` on the line
`PERF: jobs=... total_cycles=... busy_cycles=...`.
It is the GEMM-node counter, not host wall time, the generic processor `cycles`,
or `busy_cycles`:

- `runtime/stub/utils.cpp:648` reads `VX_CSR_MPM_GEMM_TOTAL_CYC`.
- `hw/rtl/core/VX_csr_data.sv:235` maps it to `accel_perf.gemm_node.total_cycles`.
- `hw/rtl/core/gemm/VX_gemm_node.sv:1654` forwards the GEMM controller counter.
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv:2566` increments it when
  `invocation_active_q || gemm_unit_computing`.

Thus it includes active GEMM invocation scheduling/DMA/compute time but excludes
host-side input generation and transfer outside that invocation. M=1 and M=4
reserve padded DRAM slots, but compute and DMA use the real M
(`tests/regression/fpint_gemm_ffn_hw/main.cpp:660`).

## Controlled configuration and coupled changes

Base configuration:
`configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`.
Source revision: `5c748f68`, including the committed C2 DMA write-ACK repair.
C2 timing cuts remain enabled in both profiles. Physical TMEM bank width is
32 B and HBM DMA beat width is 64 B in both profiles.

| Parameter | 16-bank profile | 8-bank profile |
| --- | ---: | ---: |
| NUM_TMEM_BANKS | 16 | 8 |
| NUM_DMA_CHANNELS | 8 | 4 |
| TMEM_BANK_SIZE | 32 KiB | 32 KiB |
| Total TMEM capacity | 512 KiB | 256 KiB |
| External HBM AXI ports | 8 | 8 |
| MXU rows/columns | 16/16 | 16/16 |

The existing RTL requires two physical banks per HBM DMA channel (static
assertions in `VX_gemm_node.sv` and `VX_tmem_subsystem.sv`). Consequently this
experiment compares two supported complete configurations, not bank arbitration
in isolation: DMA injection parallelism and total capacity also change. With
four DMA channels, `Vortex_axi.sv` routes each channel to two external HBM ports;
eight external ports do not imply eight independent DMA injectors.

## Reproduction and evidence

The runner creates/configures separate build roots, sources the base config,
replaces only the two bank/channel defines, and invokes from each build:

```sh
./ci/run_black.sh xrt-vcs-sim --perf 3 --app fpint_gemm_ffn_hw \
  --args "-m M -k 256 -n 256 -q 32 -d 0 -t 0 -r 1"
```

No `--debug` is used. No RTL or primary configuration file is modified.
`run_comparison.py` captures per-profile configuration and RTL hashes in
`b16/manifest.json` and `b8/manifest.json`; per-case commands, wrapper output,
simulator logs, kernel hash, and parsed counters are kept under `b*/m*_r*/`.
Simulator binary identity must remain unchanged across repetitions, and RTL
hashes are checked again after completion.

The first M1 executions passed, but the initial collector expected a nonexistent
`build/run.log`. The collector was corrected to read archived wrapper stdout;
`--resume` reparses those existing successful runs without discarding evidence.
The initial collector verdicts remain in `result_initial.json`.

## Results

Completed 2026-09-06, 16:04 KST. **All 18 launches reported application PASS**
(2 profiles x 3 shapes x 3 repetitions). The 8-bank runs also emitted the
capacity assertion error described in the correction above. Both profiles
retained their original simulator binaries and all 326 RTL source hashes.
All 18 launches used the same kernel SHA-256:
`15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`.

| M | 16 banks: median cycles | 8 banks: median cycles | Extra cycles (8 vs 16) | Cycle increase |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1,795 | 1,871 | 76 | +4.23% |
| 4 | 1,869 | 1,955 | 86 | +4.60% |
| 256 | 71,495 | 72,843 | 1,348 | +1.89% |

Cycle increase = `(median8 / median16 - 1) * 100`; positive means slower.

| M | 16-bank raw cycles | 16-bank min-max | 8-bank raw cycles | 8-bank min-max |
| ---: | --- | --- | --- | --- |
| 1 | 1797, 1795, 1795 | 1795-1797 | 1871, 1871, 1871 | 1871-1871 |
| 4 | 1869, 1870, 1868 | 1868-1870 | 1955, 1955, 1955 | 1955-1955 |
| 256 | 71495, 71494, 71504 | 71494-71504 | 72843, 72848, 72843 | 72843-72848 |

The observed within-profile ranges are much smaller than the differences
between profiles. For these shapes, reducing to the supported 8-bank/4-channel
configuration has a modest cycle cost; it does not halve performance. The
relative cost is smaller at M=256. These observations do not isolate whether
individual extra cycles arise from bank contention, DMA channel parallelism,
or the changed HBM routing topology.

The input/weight/output fire counts match across both profiles and all three
launches per shape: M1 = 256/1024/16, M4 = 1024/1024/64,
M256 = 65536/2048/4096. Thus M1 and M4 are distinct executed workloads, despite
their padded memory reservations.

Machine-readable summary: [comparison.json](comparison.json).
Detailed evidence: [b16/results.json](b16/results.json),
[b8/results.json](b8/results.json), and their per-case `wrapper.log`/`simv.log`.

## Interpretation limits

This is a simulated cycle comparison at identical RTL timing-cut settings,
not an achieved-Fmax, utilization, congestion, or board-throughput comparison.
It does not predict behavior at K=N=4096. A resource/timing benefit from fewer
banks would require separate synthesis/P&R evidence.

Class-3 `input/weight/output fire` counts provide an additional same-work check.
Do not interpret a zero `input stall` counter as proof of no input bubbles:
backpressure while valid and the absence of valid input are different events.
