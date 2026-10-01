# Table VI / Fig. 15 — native FPGA resource study

This experiment measures an FPGA replacement for the paper's ASIC array-efficiency
and area-breakdown results. The manuscript is not edited. Native DSP mapping is
retained: GOPS/kLUT and GOPS/DSP are separate conditional resource efficiencies,
not a conversion of FPGA resources into silicon area.

## Scope

- Device: U55C `xcu55c-fsvh2892-2L-e`; Vivado 2025.1.
- Flow: OOC synthesis, production async-BRAM patch, then `opt_design`.
- 100 MHz is a common **reference** for nominal compute peak; neither timing
  closure nor achieved Fmax or end-to-end throughput is established by this flow.
  The OOC ports have no board I/O delay constraints.
- FP TCU: actual production 256 MAC/cycle implementation, FP16 × FP16.
- WKV: production 1024 MAC/cycle FP16 × INT4 GEMM, including 256 KiB internal ACC.
- WoQ derived: the **same** GEMM RTL, with only the wrapper's quantization direction
  tied to Q-COL and weight address bit 1 tied to zero (row loading). Address bit 0
  and all other address/data/control bits remain unchanged. This is a same-engine
  ablation, not the historic separate ASIC WoQ patch.
- WoQ/WKV have identical ACC capacity and mapping settings, FP IP configuration,
  and clock. TCU has different storage scope; this is **not** an iso-storage
  comparison of all three rows. The original ASIC experiment excluded internal ACC.
- C4 system breakdown comes from a separate **historical post-route build** with
  ACC in URAM. Its totals must never be added to the OOC engine results.
- No DSP-free experiment, FPGA power estimate, board power measurement, or
  TOPS/W claim is included.

The approved analysis and reasons for these boundaries are in [PLAN.md](PLAN.md).
Original evidence collected before the new experiment remains in `results/provenance/analysis_evidence.json`.

## Reference result (2026-09-30)

| Engine | LUT | FF | DSP | BRAM36 eq. | Nominal GOPS/kLUT | Nominal GOPS/DSP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| FP TCU | 80,662 | 126,202 | 1,024 | 1 | 0.635 | 0.050 |
| WoQ derived | 136,565 | 46,280 | 1,825 | 58 | 1.500 | 0.112 |
| WKV | 147,203 | 50,704 | 1,857 | 58 | 1.391 | 0.110 |

All three points use native mapping and a 100 MHz nominal reference. URAM=0.
WoQ/WKV each include 256 KiB ACC; TCU is not iso-storage.

- WKV−WoQ: **+10,638 LUT (+7.790%), +4,424 FF (+9.559%), +32 DSP (+1.753%)**; identical RAM usage.
- WKV input scaler attribution: **3,360 LUT + 2,304 FF + 32 DSP**, or **2.283% of WKV LUTs / 1.723% of WKV DSPs**. This is not the full WKV overhead.
- WKV/FP TCU nominal efficiency: **2.192× GOPS/kLUT**, **2.206× GOPS/DSP**.
- Verification passed: 3 seeds, 1,728 numerical output lanes, actual AMD IP burst/latency test, source hash matching, zero blackboxes/no-clock/internal-unconstrained endpoints, matched ACC/IP, report-to-table reconciliation.
- Table VI resource-efficiency and Fig. 15 resource-breakdown replacements are feasible with these scope labels. Power and Fmax portions remain unmeasured.

Preview: [table](results/engine_resources_table.pdf), [engine breakdown](results/engine_resource_breakdown.pdf), [resource efficiency](results/engine_resource_efficiency.pdf), [C4 routed breakdown](results/c4_resource_breakdown.pdf).

Legacy baseline command JSONs were not retained; `study_metadata.json` records their availability explicitly. The fresh WoQ command and logs are archived, and full reproduction commands are below.

## RTL and mapping provenance

The experiment uses `hw/rtl/core/gemm/VX_gemm_unit_top.sv` and
`VX_gemm_unit.sv`, with `VX_gemm_tree_v1.sv`, `VX_pe_tree_new.sv`,
`VX_gemm_weight_regs_v1.sv`, `VX_prealigner.sv`, `VX_pint2fp.sv`,
`VX_fp16_mul.sv`, `VX_fp32_mul.sv`, `VX_fp32_add.sv`, and `VX_f32_to_f16.sv`.
Their dependency closure has 31 preprocessed files. The TCU closure has 14 files.
The snapshots and ablation manifests record every hash; no ASIC patch directory
is included in the dependency search.

Native DSP attributes remain on PE products and reduction-tree pair sums.
The default PE multiply is signed 12-bit selected mantissa × INT4, followed by
alignment handling; it is not a direct 31-bit × INT4 multiplier in every PE.
FP16/FP32 multiplier IPs use `Full_Usage`, and the FP32 adder IP uses `No_Usage`.
All three GEMM FP IPs use `C_Latency=1`, `C_Rate=1`; resolved parameters are saved
in `results/ip_parameters.json`. The RTL wrapper's generic `LATENCY=0` must not
be interpreted as the selected Vivado IP having zero latency.

## Saved outputs

`results/engine_resources.{json,csv}` and `engine_resources_table.pdf` provide the
Table VI candidate. `engine_resource_breakdown.pdf` is the Fig. 15a candidate;
`overhead.json` distinguishes total WKV−WoQ overhead (denominator WoQ) from input
scaler share (denominator WKV). `engine_resource_efficiency.pdf` plots both resource
efficiencies. `c4_resource_breakdown.pdf` is the separate Fig. 15b candidate.

The raw reports, source hashes, resolved FP IP parameters and test evidence are
archived alongside the results. Large checkpoints/build trees stay in the
configured build directory and are not reference artifacts to commit.

## Replay without Vivado

From the repository root, with Python 3 and Matplotlib (reference version 3.10.8):

```bash
python3 -m pip install -r agent-tasks/array-fpga-study/requirements.txt
python3 agent-tasks/array-fpga-study/verify_results.py
python3 agent-tasks/array-fpga-study/plot_results.py
```

The plots consume only the saved JSON. The verifier checks report hashes, global
resource counts, hierarchy partitions, CSV/JSON agreement, nominal GOPS formulas,
matched ACC/IP settings, and both functional validation results. It does not
substitute for rerunning RTL simulation or synthesis.

## Full reproduction

Use Bash for sourcing configuration. Verilator 5.028 and system GCC/G++ are used
for the bounded engine test. Vivado 2025.1 supplies the actual FP IP simulation.
Set `VIVADO` if it is not at the reference installation path. `run_native.py` and
`check_vendor_ip.py` default to `/tool/Program/Xilinx/2025.1/Vivado/bin/vivado`.

1. Recreate or reuse the Fig. 5 **compute** baseline by following
   [the Fig. 5 README](../fig5-fpga/README.md). Its production RTL reference is
   `f1f6303b112e060e56f0512294bd86f2be373b26`; the committed Fig. 5 harness is
   `bc67d9555`. Existing local baseline build: `build-fig5-fpga`.
   The memory sweep is unnecessary for this experiment. If rebuilding just the
   compute baseline, source `configs/fig5_fpga_compute.sh` in a configured build
   and run `python3 ../agent-tasks/fig5-fpga/compute.py`.

2. Prepare a fresh configured build and check source/IP compatibility:

```bash
mkdir -p build-array-fpga-study
cd build-array-fpga-study
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
source ../configs/array_fpga_native.sh
export PATH=/opt/vortex/verilator/share/verilator/bin:$PATH
export VIVADO="${VIVADO:-/tool/Program/Xilinx/2025.1/Vivado/bin/vivado}"
python3 ../agent-tasks/array-fpga-study/run_native.py \
  --baseline-build ../build-fig5-fpga --prepare-only
```

This freshly preprocesses both baseline tops and compares every file hash and
config against the source snapshots that produced the old reports. It applies
exactly the Fig. 5 TCU wrapper instance-name correction in the snapshot only.
A mismatch fails rather than silently mixing a new WoQ with a stale baseline.
`prepare_woq.py` copies the WKV snapshot and records all three wrapper edits and
before/after hashes. Production `hw/rtl` and ASIC `hw/rtl/patch` are not modified.

3. Run the engine test and actual vendor FP IP test before synthesis:

```bash
python3 ../agent-tasks/array-fpga-study/prepare_test.py \
  --reference-sources "$PWD/array_fpga_native/sources/fpint_32x32/sources.txt"
python3 ../tools/verify_rtl.py unittest \
  --path "$PWD/array_fpga_test" --sim vlt \
  > array_fpga_test/verification.json
python3 ../agent-tasks/array-fpga-study/check_vendor_ip.py \
  ../build-fig5-fpga/fig5_fpga_compute/fpint_32x32
```

The `verify_rtl.py` CLI calls Verilator `vlt`, not `verilator`. Compilation uses
`/usr/bin/gcc` and `/usr/bin/g++`. Its compile timeout is 300 seconds; on slower
hosts the compile adapter can first be run from `array_fpga_test` with
`python3 ../../agent-tasks/array-fpga-study/test/compile_test.py`, then invoke the
same deterministic verifier. Do not launch two compilers on the same `obj_dir`.

The directed engine test checks three seeds (1234/2027/91), 576 FP16 output lanes
per seed, cycle/data equality on the WoQ domain, an independent integer numerical
oracle, both weight/scale/zero banks, three accumulated K tiles, input bubbles,
reset/restart, and WKV Q-ROW plus column loading. Vectors use activations 1/2, INT4 weights 1–7 and scale/zero values 1/2; signed
extremes and heterogeneous per-lane scaling are outside this bounded test.
Its FP AXI models cover normal, finite directed arithmetic; this is not exhaustive IEEE or formal equivalence.

The separate XSim test instantiates the **actual generated AMD** FP16 multiplier,
FP32 multiplier and FP32 adder models. It checks numerical alignment, burst input
and valid gaps, measured one-cycle handshake latency and consecutive outputs.
This validates the IP latency/rate contract, not the entire engine with vendor
models. Both tests and their limits are recorded.

The production output readout pulses valid independently of `o_rsp_ready`.
Low-ready responses are checked for WoQ/WKV equivalence and correct presented
values; the test does **not** claim lossless output backpressure support.

4. Run the native WoQ synthesis:

```bash
python3 ../agent-tasks/array-fpga-study/run_native.py \
  --baseline-build ../build-fig5-fpga \
  --verification array_fpga_test/verification.json
```

The gate requires passing RTL and vendor-IP checks and matching verified/synthesized
source hashes. The flow uses four Vivado threads. It fails on unresolved blackboxes;
post-opt reports retain the 10 ns clock. Existing successful WoQ outputs are not
overwritten: use a fresh configured build to reproduce independently.

5. Collect and verify small reference artifacts (repository root):

```bash
cd ..
python3 agent-tasks/array-fpga-study/collect_native.py \
  --build build-array-fpga-study --baseline-build build-fig5-fpga
python3 agent-tasks/array-fpga-study/collect_c4.py
python3 agent-tasks/array-fpga-study/verify_results.py
python3 agent-tasks/array-fpga-study/plot_results.py
```

`collect_c4.py` defaults to the provided C4 binary report directory under
`/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin`.
To recalculate without that host path, give `--source` pointing at the saved
`results/reports/c4` directory and `--output` pointing at a separate directory.
This replays report accounting, not a fresh full-system P&R run. C4 source/build
provenance is limited to the historical binary directory and vendor reports.

## Attribution rules

- `GOPS = 2 × MAC/cycle × reference_MHz / 1000`; `GOPS/kLUT = GOPS × 1000 / LUT`.
  Report all absolute resources. Do not sum LUT and DSP with an arbitrary weight.
- Engine hierarchy groups are selected once at the `gemm_unit` child level; the
  remainder goes to control/buffers/ACC glue. All groups sum to the reported top.
  ACC hard memory means RAM primitives only; its glue remains in the logic group.
  Synthesis moves logic across hierarchy and merges some banks: a child's
  attributed resources are not necessarily what deleting that child would save.
- C4 groups partition `vortex_afu_1`. The shell/other region is full design minus
  that accelerator. Ignore report percentages whose PR-region denominators differ.
  Raw hierarchy immediate-child LUT counts exceed `gemm_node` by 2; the explicit
  parent-minus-selected-child residual preserves the reported total. The analysis
  does not infer the cause of that vendor-report accounting difference.
- C4 TMEM banks, five DMA engines, and TMEM switch/control are separate. ACC URAM
  primitives are split from GEMM logic without claiming an exact ACC LUT boundary.
- `dump_dsp.tcl` provides optional read-only primitive attribution, including
  `USE_MULT`, `USE_SIMD` and pipeline registers. Use an optimized checkpoint:

```bash
# From configured build; output remains outside the source tree.
"$VIVADO" -mode batch -source ../agent-tasks/array-fpga-study/dump_dsp.tcl \
  -tclargs ../build-fig5-fpga/fig5_fpga_compute/fpint_32x32/post_opt.dcp \
  wkv_dsp.csv
```

The current WKV checkpoint has 1,024 multiplier DSPs and 672 adder DSPs inside MXU,
32 input-scaler DSPs, 64 output-scaler DSPs, 64 direct GEMM arithmetic DSPs, and one
activation-reduction DSP. All 1,857 are `ONE48`; 1,184 have `USE_MULT=MULTIPLY`
and 673 `USE_MULT=NONE`. This is the observed native mapping, not an estimate
from RTL multiplier count.
