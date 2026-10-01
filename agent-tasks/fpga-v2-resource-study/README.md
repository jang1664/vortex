# FPGA v2 resource study: Fig. 5 and Table VI

Rerun of the controlled `mxu16-fpga-study` using `fpint-fpga-v2` RTL at
`1e4b367cc` and the explicitly selected current FPGA candidate configurations.
This directory preserves the earlier measurements and does not edit the paper.

## What is compared

- **FP TCU:** `configs/tcu_th16_c1.sh` (`tcu_th16_c1_v2`), unmodified TCU
  geometry: 4 x 4 output lanes x 8 FP16 products = **128 MAC/cycle**.
  The previous 16x16 experiment forced `TCU_DP=2` to obtain 64 MAC/cycle.
  This rerun does not make that RTL edit; do not carry its old denominator over.
- **WKV:** `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh`
  (`improve_th16_tcol16_m16_t8_bigmem_all_bram_spread`), **16x16 = 256 MAC/cycle**,
  `GEMM_IMPROVE`, `GEMM_TIMING_CUTS=1`, `MXU_WLOAD_NUM=4`, native FPGA arithmetic.
- **WoQ:** same current WKV datapath with Q-COL and standard weight loading
  statically selected in the wrapper. Arithmetic, timing cuts, IP, ACC and
  buffering are shared with WKV. This isolates attention support cost; it is
  not the deployed C2 `GEMM_NAIVE` engine.
- WoQ/WKV each retain **256 KiB internal ACC**, BRAM mapping. The TCU has no
  equivalent internal ACC, so the engine comparison is not iso-storage.
- **Fig. 5 memory sweep:** user explicitly retained the previous controlled
  LMEM 8->32, cache/AXI 1->4 profile. LMEM capacity 512 KiB, word 8 B; cache
  capacity 4 MiB, word 16 B, line 64 B, 4 ways, 16 MSHRs; AXI input 64 B to 32 banks.
  These blocks are synthesized independently and their costs are added to the
  engine. This is not an integrated C1-C4 implementation or a measurement of
  sustained bandwidth. In particular, the 4x memory-port sweep is independent
  of the current engines' 2x MAC/cycle ratio.

All four requested aliases/configs are recorded in `candidate_provenance.json`.
Their explicit defines were checked against the installed binary manifests.
`python3 agent-tasks/fpga-v2-resource-study/capture_candidates.py` refreshes this
record when the referenced `/opt/vortex_fpga_bins` artifacts are available;
offline replay uses the archived record and does not require these binaries.
Synthesis uses current branch RTL, not a reconstruction of the archived bitstreams.

## Current AXI parameter adaptation

The current adapter distinguishes `NUM_BANKS_OUT` (transport groups) from
`NUM_HBM_PORTS` (physical output ports). Reusing the old generic list silently
left eight physical ports behind 32 groups; those initial synthesis trials
are **rejected and excluded**. The accepted experiment explicitly sets both
counts to 32, `INTERLEAVE=1`, and 28-bit word/34-bit physical byte addresses.
This preserves the intended 32 output ports while satisfying the current HBM
address-map contract. Address width/interleave settings are a documented
adaptation, not an identical-parameter historical comparison.

`check_axi_geometry.py` enables the production `SIMULATION` static assertions
and verifies the elaborated physical port/address dimensions for both 1/4 input
cases. This gate is required before accepting the AXI synthesis results; static
assertions are absent from production synthesis preprocessing. This is a
geometry check, not a new AXI traffic benchmark.

## Measurement scope

Vivado 2025.1, U55C `xcu55c-fsvh2892-2L-e`, OOC synthesis plus the production
async-BRAM patch and `opt_design`. Native DSP mapping; **100 MHz nominal**
reference and two operations per MAC. Raw LUT, FF, DSP, BRAM36/18 and URAM counts
are retained. No achieved Fmax, routed resource count, power or measured GOPS
is inferred from synthesis timing. GOPS/kLUT and GOPS/DSP are separate
single-resource efficiencies, not an aggregate FPGA cost measure.

## WoQ implementation and verification

`hw/rtl/patch/VX_woq_gemm_unit_top.sv` now instantiates the current production
`VX_gemm_unit`. The obsolete patch's external-ACC interfaces are removed and
current control fields restored. It statically sets `quant_dir=0` and weight
address bit1=0, preserving all other address bits, including the buffer index.
The old lower-level `VX_woq_gemm_unit`, tree, weight-register and PE patch modules
are excluded from this experiment; copying those old ASIC datapaths would
confound the comparison. `prepare_woq.py` checks that the reviewable wrapper
matches exactly these substitutions and records every dependency hash.

The paired test compares Q-COL cycle/data behavior against WKV and an independent
numeric oracle with signed INT4 weights and lane-varying scale/zero parameters.
It covers both buffer banks, three accumulated K tiles, input bubbles, reset,
restart, and WKV Q-ROW plus column loading. Three seeds check 864 output lanes.
These finite arithmetic models do not prove all IEEE corner cases. Production
output pulses are checked under low-ready conditions for equivalence, not
claimed as lossless backpressure support. Generated AMD FP16/FP32 multiplier
and FP32-adder IP models are tested separately in XSim.

## Reproduce synthesis and tests

Use Bash from this repository checkout. Use a fresh configured build directory
for a new run; completed checkpoints are never overwritten. The experiment
expects its RTL root to be the parent of the build directory.

```bash
export V2_TASK="$PWD/agent-tasks/fpga-v2-resource-study"
export FIG5_RTL_ROOT="$PWD"
mkdir -p build-fpga-v2-study
cd build-fpga-v2-study
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
export PATH=/opt/vortex/verilator/share/verilator/bin:$PATH
export VIVADO=/tool/Program/Xilinx/2025.1/Vivado/bin/vivado
source ../configs/fpga_v2_compute.sh
python3 "$V2_TASK/run.py" --kind compute --points fp_tcu_128 wkv_16x16
python3 "$V2_TASK/check_geometry.py"
python3 "$V2_TASK/prepare_test.py" \
  --reference-sources "$PWD/fpga_v2/sources/wkv_16x16/sources.txt"
python3 ../tools/verify_rtl.py unittest --path "$PWD/fpga_v2_test" \
  --sim vlt --timeout 1800 > fpga_v2_test/verification.json
python3 "$V2_TASK/../array-fpga-study/check_vendor_ip.py" \
  "$PWD/fpga_v2/wkv_16x16"
python3 "$V2_TASK/run.py" --kind compute --points woq_16x16
source ../configs/fig5_fpga_memory.sh
python3 "$V2_TASK/check_axi_geometry.py"
python3 "$V2_TASK/run.py" --kind memory --parallel 2
python3 "$V2_TASK/collect.py" "$PWD"
python3 "$V2_TASK/verify.py"
# Install requirements.txt into a plotting virtual environment first.
python3 "$V2_TASK/plot.py"
python3 "$V2_TASK/table.py"
```

The TCU runner sources `configs/fpga_v2_tcu.sh` for its own snapshot. Both new
experiment configs source the selected production candidate configs and add
synthesis/platform build defines. The only TCU snapshot edit corrects the
pre-existing `execute_if` instance-name typo in the standalone wrapper; it does
not change TCU dimensions or arithmetic.

Offline validation and figure/table replay require only this repository:

```bash
python3 agent-tasks/fpga-v2-resource-study/verify.py
python3 agent-tasks/fpga-v2-resource-study/plot.py
python3 agent-tasks/fpga-v2-resource-study/table.py
```

Raw reports, selected preprocessed compute RTL, config/source provenance,
verification logs, and resource/efficiency JSON/CSV accompany the PDFs and
copy/paste LaTeX. Checkpoints and build products remain local.

## Measured results

All nine accepted OOC points passed synthesis/optimization and report audits.

| Engine | MAC/cycle | LUT | FF | DSP | BRAM36 eq. | URAM | Relative GOPS/kLUT | Relative GOPS/DSP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| fp_tcu_128 | 128 | 40,974 | 63,770 | 512 | 1 | 0 | 1.00 | 1.00 |
| woq_16x16 | 256 | 47,324 | 19,548 | 480 | 58 | 0 | 1.73 | 2.13 |
| wkv_16x16 | 256 | 51,070 | 21,796 | 496 | 58 | 0 | 1.60 | 2.06 |

Fig. 5: WKV/TCU relative nominal GOPS/kLUT is **1.60x engine only ->
0.63x with additive memory costs**. These ratios use the current 128-MAC TCU.
WoQ and WKV engine counts equal the earlier 16x16 study; the TCU baseline and
AXI adapter implementation/configuration differ, so the normalized values change.

WKV adds 3,746 LUTs (7.916%) and 16 DSPs (3.333%) over matched WoQ. The input
scaler alone is 1,537 LUTs (3.010% of WKV) and 16 DSPs (3.226% of WKV).

[Fig.5 PDF](results/memory_scaling.pdf), [Table VI LaTeX](results/table6.tex),
[resource counts](results/resources.csv),
[engine breakdown PDF](results/engine_resource_breakdown.pdf).
