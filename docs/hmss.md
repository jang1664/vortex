# HMSS (HBM Memory Subsystem) — Architecture, PL Cost, Connectivity Rules

This document describes the Xilinx/AMD HBM Memory Subsystem (HMSS) used by the
Vortex XRT flow on U55C. It covers three things:

1. What HMSS actually is — hard blocks (free) vs soft wrapper (PL LUT/FF).
2. Which parts consume the most PL resources and why.
3. Connectivity rules (`sp=...`) and the mistakes that caused prior failures.

Source citations are provided for every architectural claim. Claims that are
inferred from the observed build (not directly quoted in docs) are explicitly
marked **[inferred]** or **[observed]**.

## TL;DR

- On U55C the two HBM2 stacks, their memory controllers, and an on-die
  32×32 segmented crossbar are **hard silicon**. They are free in the sense
  that they consume no PL LUTs.
- The **HMSS wrapper** that Vitis generates around the HBM IP is **entirely
  soft** (in PL), but its total cost is small. In the
  `core1_fpint_improve` build with 8 masters × `HBM[0:31]`, the complete
  HMSS consumed **48,200 LUTs ≈ 3.7 %** of the U55C device
  (§2.1 measured inventory). The HBM IP itself was 1,009 LUTs and AXI VIPs
  in PASS_THROUGH were **0 LUTs**.
- Cost scales with **kernel master count × HBM fan-out per master** (i.e. the
  breadth of each `sp=` line), not with the 32 HBM slave ports themselves.
  Measured per-master SmartConnect (with `HBM[0:31]`) is ~5 k LUTs; shrinking
  to `HBM[0:3]` would reduce that by roughly an order of magnitude.
- **Non-contiguous `sp=...:HBM[0]:HBM[8]:...` syntax is not supported** — v++
  rejected it in our hw_emu build. Only single channels and contiguous ranges
  work.
- **HMSS is rarely the bottleneck.** When a Vortex AFU synth reports 87.6 %
  LUT use, cutting HMSS from 3.7 % to 0.5 % recovers ~3 %. The same
  reference platform synthesized cleanly with a 32×32 HBM bandwidth kernel
  at **21.8 %** total LUT use — the difference is the *user kernel*, not
  HMSS.

## 1. U55C HBM Architecture

### 1.1 Hard silicon (HBM IP core)

The U55C (xcu55c) integrates two HBM2 stacks in SLR0. The HBM IP core
(`xilinx.com:ip:hbm:1.0`) in a Vitis build exposes the whole hardened block:

| Element | Count | Notes |
|---------|-------|-------|
| HBM2 stacks | 2 | 8 GB each, 16 GB total |
| Pseudo-channels (PCs) | 32 | 16 per stack, 512 MB each |
| AXI3 slave ports | 32 | 256-bit @ 450 MHz nominal, one per PC |
| Memory controllers | 32 | Hardened, JEDEC HBM2 timing |
| Internal switch | 1 | Segmented crossbar (see 1.2) |

Citations: PG276 *Introduction* / *AXI Port Details* — "up to 16 AXI3 slave
ports, each with its own independent clocking" per stack; U55C has two stacks.
UG1469 *HBM Memory* — 16 GB total, 32 PCs.

### 1.2 Hard internal switch

PG276 *Core Overview* documents a hardened AXI switch inside the HBM IP:
a **16×16 crossbar per stack** (U55C has two stacks → effectively a
32×32 capability across the device). Each HBM AXI slave port operates on
an independent clock domain. Per PG276 *Raw Throughput Evaluation*, the
aggregate dual-stack throughput is 460,800 MB/s, i.e. **~14.4 GB/s per
AXI port** on average.

> "fastest performance occurs when AXI masters access aligned pseudo
> channels within the same 4x4 segment."
> — Vitis Tutorials, HBM Overview (2022.1)

PG276 documents the internal switch but does not quantify inter-segment
latency or bandwidth penalty in a way that can be quoted here.

**What is soft** is the wrapper logic connecting **kernel masters** to the
32 AXI slave ports of the HBM IP. That wrapper is the subject of the rest
of this document.

## 2. What Vitis HMSS adds in PL (the soft wrapper)

When v++ runs `system_link`, it emits a block diagram at
`ulp_hmss_0_0/bd_0/bd_*.bd`. This top BD plus one sub-BD per kernel master
form the HMSS wrapper. All of the following is in PL (soft), placed inside
`pblock_dynamic_region`.

### 2.1 Observed IP inventory and LUT cost (this repo, 8 masters × HBM[0:31])

IP types in the top HMSS BD:

```
build/.../_x/link/vivado/vpl/prj/prj.gen/my_rm/bd/ulp/ip/ulp_hmss_0_0/
  bd_0/                       # top HMSS wrapper
    bd_*.bd counts:
      1 × hbm                  (HARD — the HBM IP core)
      9 × axi_vip              (PASS_THROUGH monitor, one per master-side port)
      9 × smartconnect         (1→N router, one per master)
      9 × axi_register_slice   (pipeline stage, one per master)
      1 × axi_apb_bridge       (host access to HBM control/status)
      2 × proc_sys_reset, util_vector_logic, util_reduced_logic, xlconcat
  bd_1 / bd_2 / ... / bd_9/    # per-master SmartConnect internals
    each contains:
      5 × sc_node
      1 × sc_transaction_regulator
      1 × sc_si_converter
      1 × sc_sc2axi, 1 × sc_axi2sc, 1 × sc_mmu, 1 × sc_exit
      3 × proc_sys_reset + xlconstant glue
```

Per-component LUT/FF from synth reports
(`_x/reports/link/syn/bd_85ad_*_utilization_synth.rpt`):

| Component | Count | LUT each | LUT total | FF total |
|-----------|------:|---------:|----------:|---------:|
| `smartconnect` (bd_1..bd_8, 1→32 per master) | 8 | 5,062 | 40,496 | 45,008 |
| `smartconnect` (bd_9, host/XDMA path) | 1 | 2,092 | 2,092 | 2,703 |
| `axi_register_slice` (slice0, 256-bit wide) | 1 | 2,099 | 2,099 | 11,714 |
| `axi_register_slice` (slice1..slice8) | 8 | 293 | 2,344 | 9,776 |
| `hbm` IP core | 1 | 1,009 | 1,009 | 824 |
| `axi_apb_bridge` | 1 | 122 | 122 | 127 |
| `hbm_reset_sync_SLR0` / `SLR2` | 2 | 18 | 36 | 80 |
| `axi_vip` (PASS_THROUGH) | 9 | **0** | **0** | 0 |
| `init_reduce`, `util_vector_logic` glue | 2 | 1 | 2 | 0 |
| **HMSS total** | | | **~48,200 (3.7 %)** | ~70,200 (2.7 %) |

Notes:
- 9 master-side wrappers = 8 kernel masters (`m_axi_mem_0..7`) + 1 host/XDMA
  calibration path.
- Each per-master SmartConnect (bd_1..bd_8) is a 1→32 soft router — 8× copies
  of the 5 k-LUT block are the dominant HMSS cost.
- **AXI VIP instances synthesize to 0 LUTs in PASS_THROUGH mode.**
  This was verified in the utilization reports; earlier speculation in this
  file that VIPs contribute hundreds of LUTs was wrong.
- The HBM IP core itself is ~1 k LUTs — confirming that its internal 32×32
  switch is hard silicon, not soft logic.

### 2.2 What each soft IP does

Function claims here are limited to what is documented in AMD product
guides. Measured LUT figures are from this repo's synth reports.

| IP | Documented function | Measured LUT |
|----|---------------------|--------------|
| `axi_vip` (PASS_THROUGH) | Protocol monitor/sim hook (PG267). | 0 (in this build) |
| `smartconnect` | AXI4↔AXI3 conversion incl. burst splitting (PG247 *AXI4-to-AXI3 Conversion*); clock domain crossing (PG247 *Feature Comparison*); address decode/routing (PG247 *Feature Comparison*). | ~5 k per master at 1→32 |
| `axi_register_slice` | AXI pipeline stage for timing closure (PG373). | 293 each; one wide at 2.1 k |
| `axi_apb_bridge` | AXI↔APB bridge for HBM control/status (PG276 HBM IP uses APB for register access). | ~120 |
| `proc_sys_reset`, `util_*`, `xlconcat`, `xlconstant` | Reset synchronization and glue. | ≤50 total |
| `sc_node`, `sc_mmu`, `sc_transaction_regulator`, `sc_si_converter`, `sc_sc2axi`, `sc_axi2sc`, `sc_exit` | SmartConnect internal primitives (PG247). | Rolled up into SmartConnect above. |

**Not in AMD documentation (and therefore not stated here as fact):**
- Why Vitis chooses SmartConnect (vs simpler register-slice + per-port direct
  wiring) for HBM connectivity. No AMD doc searched states this explicitly.
- Whether the 1→32 SmartConnect topology is for bandwidth aggregation across
  HBM ports, or simply as a by-product of `sp=...:HBM[0:31]` expansion.
  Only the *observation* that Vitis produces 1→N SmartConnects with N equal
  to the `sp=` breadth is supported by our build.

## 3. What consumes LUTs — ranked (measured)

Ordered by measured LUT in the `core1_fpint_improve` build:

1. **Per-master SmartConnect with wide fan-out — 42.5 k LUT (88 % of HMSS).**
   Eight SmartConnects (bd_1..bd_8) at ~5,062 LUTs each, plus one smaller
   host-side router (bd_9, 2,092 LUTs). SmartConnect documented functions
   (AXI4↔AXI3, CDC, address decode — PG247) are all present in these
   instances. That per-instance cost scales with the `sp=` breadth for that
   master in this build; whether scaling is strictly linear in N is not
   documented.

2. **Register slices on the master→HMSS path — 4.4 k LUT (9 %).**
   One wide slice (`bd_85ad_slice0`, 2,099 LUTs, 11,714 FFs — likely the
   host-side path) plus eight narrow slices (293 LUTs, 1,222 FFs each).

3. **HBM IP core itself — 1,009 LUT (2 %).**
   Minimal, as expected for a hard IP. Mostly calibration/status soft logic
   around the hard block.

4. **APB bridge, reset sync, init reduce — ~160 LUT (<1 %).**
   `axi_apb_bridge` 122 LUTs; two `hbm_reset_sync` 18 LUTs each; trivial
   glue.

5. **AXI VIP pass-throughs — 0 LUT.**
   All nine `axi_vip` instances synthesize to zero LUTs in PASS_THROUGH
   mode — they are wire pass-throughs after synth.

**HMSS total: ~48,200 LUT ≈ 3.7 % of U55C.**

### 3.1 Comparison with a lightweight reference build

For perspective, a minimal bandwidth-test kernel with the *same* platform and
*more* ambitious connectivity — **32 masters × `HBM[0:31]`** — built
successfully at 21.8 % total LUT
(`fpga_experiments/test_manual_burst_rw_xbar/build/vpp_temp_dir/reports/link/imp/impl_1_full_util_placed.rpt`):

| Metric | 32×32 bandwidth test | 8×32 Vortex (this repo) |
|--------|---------------------|-------------------------|
| Kernel source | ~475 lines HLS | full Vortex + GEMM + L2 + FPU |
| Total LUT after impl | **284,405 (21.8 %)** | — (failed at place) |
| Kernel synth LUT | ~few k | **1,142,237 (87.6 %)** |
| HMSS LUT | larger xbar (~50–80 k est.) | 48,200 measured |
| Build outcome | success | `pblock_dynamic_region` overrun |

**Takeaway:** the HMSS wrapper is not what makes Vortex overflow
`pblock_dynamic_region`. The Vortex AFU itself is 24× larger than the
entire bandwidth-test design. Optimizing HMSS recovers at most ~3 % of
device LUTs — useful but not sufficient if the kernel is already at 87 %.

## 4. How connectivity choice drives LUT cost

**Observed in this build:** the per-master SmartConnect fan-out matches the
number of HBM PCs listed in that master's `sp=` line. With
`sp=...:HBM[0:31]` on every master, each SmartConnect is a 1→32 router and
the top HBM BD contains 9 such instances.

| Per-master `sp=` breadth | Observed SmartConnect fan-out |
|----|----|
| `HBM[0]` | 1→1 |
| `HBM[0:3]` | 1→4 |
| `HBM[0:7]` | 1→8 |
| `HBM[0:15]` | 1→16 |
| `HBM[0:31]` | 1→32 (this repo) |

The precise LUT scaling law for SmartConnect as a function of N is not
quoted in AMD docs; what we can say with certainty is that this repo's
8 × (1→32) instances measured at ~5 k LUT each. Expected reduction for
narrower ranges is not precisely predictable from docs alone.

### 4.1 Why non-contiguous `sp=` does not help

An "8:32 matrix where each master reaches only 4 PCs" (e.g.
`m_axi_mem_0 → {HBM0, HBM8, HBM16, HBM24}`) would shrink each SmartConnect
to 1→4 and drop the total soft cost by roughly 8×. v++, however, does not
accept non-contiguous syntax.

Tested and rejected by v++ in hw_emu:
```ini
# v++ error — syntax not accepted
sp=vortex_afu_1.m_axi_mem_0:HBM[0]:HBM[8]:HBM[16]:HBM[24]
# also rejected — repeated sp= lines are silently collapsed (see §6)
sp=vortex_afu_1.m_axi_mem_0:HBM[0]
sp=vortex_afu_1.m_axi_mem_0:HBM[8]
```
Supported forms are single channel (`HBM[N]`) or contiguous range
(`HBM[N:M]`) only.

### 4.2 What *does* reduce LUT cost

In order of effect (device-LUT %, measured or estimated). Entries marked
`[estimated]` are projections, not documented guarantees.

1. **Shrink the user kernel.** Vortex AFU at 87.6 % dominates. Cache size,
   FPU count, GEMM unit width, core count, and thread count all compound
   here. This is where the bulk of any saving must come from. [measured]
2. **Shrink `sp=` breadth per master** to a contiguous range matching what
   that master actually accesses. Requires the RTL bank→port map to use
   **contiguous** ranges (not stride-8): e.g. `m_axi_mem_0 → HBM[0:3]`,
   `m_axi_mem_1 → HBM[4:7]`, … , `m_axi_mem_7 → HBM[28:31]`. LUT savings
   not precisely predictable without a rebuild. [estimated]
3. **Reduce `NUM_DMA_CHANNELS`** (currently 8). Fewer masters → fewer
   SmartConnect copies. [estimated]
4. PASS_THROUGH VIP removal is **not** worth the engineering cost —
   measured at 0 LUT.

## 5. U55C SLR layout and its effect

All 32 HBM controllers and the HBM IP are in **SLR0** (bottom SLR of U55C).
Kernel logic placed in SLR1 or SLR2 must cross SLR boundaries to reach HBM,
which forces Vivado to insert additional register slices on SLR-crossing
wires. That inflates the PL path length and pressure on `pblock_dynamic_region`
near the SLR0 boundary, even when total LUT utilization is below 100%.

The practical consequence seen in our build: `report placer` declared 32,317
CLBs required vs 30,427 available inside `pblock_dynamic_region` — a ~6 %
overrun. The **Vortex AFU synth report** showed 1,142,237 LUTs (87.62 % of
the device), so this is genuinely a "kernel too big" failure, not a
congestion-only issue. HMSS added ~3.7 % on top.

Compare to `fpga_experiments/test_manual_burst_rw_xbar` on the same U55C
platform: total placed LUT 21.8 %, even though that build pins 32 gmem
AXI interfaces plus read-port logic to SLR0 via an explicit
`sub_slr.tcl` post-init hook (`make_pblock hbm_ports_SLR0 {SLR0} ...`).
That floorplanning trick keeps all HBM-facing logic in SLR0 and succeeds
because there is plenty of slack. The same trick cannot rescue the current
Vortex build: SLR0 has ~1/3 of the device's LUTs (roughly 430 k of 1.30 M),
which is well under Vortex's 1.14 M requirement.

Practical implications:
- Minimize the number of kernel masters that need to reach HBM.
- Prefer placing HBM-heavy logic (DMA, LSU, last-level cache) in SLR0, but
  be aware SLR0 only holds ~1/3 of total LUT capacity.
- Adding a master is not free even if LUT % is fine globally; it costs
  SLR-boundary crossings and increases `pblock_dynamic_region` pressure.

## 6. Connectivity Rules (`sp=`)

### 6.1 One kernel argument = one `sp` line

`package_kernel.tcl` creates one pointer register per top-level master:

```text
MEM_0 → m_axi_mem_0
MEM_1 → m_axi_mem_1
...
MEM_7 → m_axi_mem_7
```

An `sp=` line addresses the interface by its top-level port name, not by the
pointer register name:

```ini
sp=vortex_afu_1.m_axi_mem_0:HBM[0:3]
```

### 6.2 Only single channel or contiguous range is accepted

```ini
# OK
sp=vortex_afu_1.m_axi_mem_0:HBM[0]
sp=vortex_afu_1.m_axi_mem_0:HBM[0:3]

# Rejected by v++ (confirmed in hw_emu on this repo)
sp=vortex_afu_1.m_axi_mem_0:HBM[0]:HBM[8]:HBM[16]:HBM[24]
```

Repeated `sp=` lines for the same port do not produce a union. In earlier
builds, `vitis.gen.ini` accepted the extra lines, but the resulting
`cfgen_cfgraph.xml` kept only one `sptag` per `MEM_i`, and the final
`address_map.xml` wired `m_axi_mem_0..7` to only `HBM_MEM00..07`. Runtime
allocations to PCs 8..31 then went to channels that the kernel could not
reach, causing hangs.

### 6.3 RTL, `sp=`, and runtime must agree

| Layer | Value |
|-------|-------|
| Physical HBM PCs | 32 (`PLATFORM_MEMORY_NUM_BANKS`, runtime bank count, address remap) |
| Top-level AXI ports | 8 (`NUM_DMA_CHANNELS`, `m_axi_mem_0..7`) |
| HMSS connectivity | whatever `sp=` says |

If the runtime allocates across 32 banks but kernel masters can only reach
`HBM[0:7]`, accesses to `HBM[8:31]` will hang in hardware or hw_emu.

### 6.4 Full-range mapping (what the repo currently uses)

```ini
[connectivity]
sp=vortex_afu_1.m_axi_mem_0:HBM[0:31]
sp=vortex_afu_1.m_axi_mem_1:HBM[0:31]
...
sp=vortex_afu_1.m_axi_mem_7:HBM[0:31]
```

This is functionally correct for any RTL bank→port mapping but is the
highest-cost configuration (see §4). It is what pushed placement over the
pblock budget in the failed `core1_fpint_improve` build.

### 6.5 Partitioned contiguous mapping

Only valid if the RTL routes addresses for `HBM[0:3]` to `m_axi_mem_0`, etc.
Vortex currently uses a **stride-8 (modulo)** bank→port map (port `i` serves
banks `{i, i+8, i+16, i+24}`), so this configuration cannot be used without
an RTL change to the bank→port demux.

```ini
sp=vortex_afu_1.m_axi_mem_0:HBM[0:3]
sp=vortex_afu_1.m_axi_mem_1:HBM[4:7]
sp=vortex_afu_1.m_axi_mem_2:HBM[8:11]
...
sp=vortex_afu_1.m_axi_mem_7:HBM[28:31]
```

## 7. How to verify a connectivity change

After every `sp=` change, inspect the generated artifacts before running the
full 9-hour impl. `system_link` completes in ~10 s; Vivado `vpl` starts at
`synth`, which takes minutes.

```bash
# Confirm the sp= lines were emitted
rg -n '^sp=' build/.../_x/link/int/syslinkConfig.ini

# Confirm cfgen preserved them
rg -n 'sptag=|MEM_|m_axi_mem_' build/.../_x/link/sys_link/cfgraph/cfgen_cfgraph.xml

# Confirm the generated address map
rg -n 'componentRef="vortex_afu_1".*m_axi_mem_|HBM_MEM' build/.../_x/link/int/address_map.xml

# Count IPs in the generated HMSS (should match expectations)
grep -oE '"xilinx\.com:ip:[a-z_0-9]+' \
  build/.../_x/link/vivado/vpl/prj/prj.gen/my_rm/bd/ulp/ip/ulp_hmss_0_0/bd_0/bd_*.bd \
  | sort | uniq -c | sort -rn
```

The per-master sub-BD node counts (`sc_node`, `sc_transaction_regulator`,
etc.) are the best early indicator of soft xbar size. They change when
`sp=` breadth changes.

## 8. References

Primary:
- PG276, *AXI High Bandwidth Memory Controller Product Guide* — Core
  Overview (AXI3 protocol, 16×16 per stack / 32×32 dual-stack internal
  switch), Raw Throughput Evaluation (460 GB/s dual-stack ≈ 14.4 GB/s per
  port)
  <https://docs.amd.com/r/en-US/pg276-axi-hbm/Core-Overview>
  <https://docs.amd.com/r/en-US/pg276-axi-hbm/Raw-Throughput-Evaluation>
- PG247, *SmartConnect Product Guide* — Feature Comparison (address decode,
  CDC, up to 256 address segments), AXI4-to-AXI3 Conversion (burst split for
  AXI4 > 16 beats)
  <https://docs.amd.com/r/en-US/pg247-smartconnect/Feature-Comparison>
  <https://docs.amd.com/r/en-US/pg247-smartconnect/AXI4-to-AXI3-Conversion>
- PG373, *AXI Register Slice*
  <https://docs.amd.com/r/en-US/pg373-axi-register-slice>
- PG267, *AXI Verification IP*
  <https://docs.amd.com/r/en-US/pg267-axi-vip>
- UG1393, *HBM Configuration and Use* (Vitis Application Acceleration)
  <https://docs.amd.com/r/2024.1-English/ug1393-vitis-application-acceleration/HBM-Configuration-and-Use>
- UG1469, *Alveo U55C Data Center Accelerator Card User Guide*
  <https://docs.amd.com/r/en-US/ug1469-alveo-u55c>
- UG1700, *Mapping Kernel Ports to Memory*
  <https://docs.amd.com/r/en-US/ug1700-vitis-accelerated-data-center/Mapping-Kernel-Ports-to-Memory>
- Vitis Tutorials, *HBM Overview / Bandwidth Explorations* (2022.1)
  <https://xilinx.github.io/Vitis-Tutorials/2022-1/build/html/docs/Hardware_Acceleration/Feature_Tutorials/07-using-hbm/1_overview.html>
