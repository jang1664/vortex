# 16x16 native FPGA resource study

A smaller counterpart to `../fig5-fpga` and `../array-fpga-study`.
The measured configuration targets a **64 MAC/cycle FP16 TCU versus a 256
MAC/cycle (16x16) FP-INT engine**, with matched WoQ/WKV resource attribution.
Original 32x32 measurements, production RTL, and the paper are not modified.
Copy/paste captions are provided in `captions.tex`.

## Controlled changes

- Base RTL: `f1f6303b112e060e56f0512294bd86f2be373b26`, identical to the original experiments.
- Isolated checkout edits: `MXU_ROW=16`, `MXU_COL=16`, `TCU_DP=2`.
  Preprocessing uses `NUM_THREADS=16`, `MXU_COL_TILE=16`.
- TCU hardware: 4x4 outputs, two packed words per reduction, two FP16
  products per word: **4x4x(2x2)=64 MAC/cycle**. This is the existing TCU DSP
  datapath with a smaller reduction, not an idealized square FP array.
- FP-INT input/output/metadata ports narrow from 64 B to 32 B with the array.
  ACC depth changes from 512 to 1024 to retain **256 KiB total ACC capacity**.
  TCU has no equivalent ACC; the three compute engines are not iso-storage.
- WoQ is the same WKV source with Q-COL and standard operand loading fixed at
  the experimental wrapper. No arithmetic RTL or DSP attributes are removed.
- Memory fabric: LMEM 8->32 banks/requests (512 KiB, 8 B words); cache
  1->4 banks/requests/ports (4 MiB, 16 B words, 64 B lines); AXI adapter
  1->4 inputs (64 B width) to 32 output banks. Bank/port counts halve with
  operand width; memory capacities and individual memory-port widths remain
  those of the original study. This is not scaling every resource by four.

## Measurement scope

Vivado 2025.1, U55C `xcu55c-fsvh2892-2L-e`, OOC synthesis, production async-RAM
patch, then `opt_design`. Native DSP mapping and unchanged FP IP settings.
Two operations/MAC at a **100 MHz nominal reference**: 12.8 GOPS for the TCU,
51.2 GOPS for either FP-INT engine. No achieved Fmax, routing closure, FPGA
power, or sustained throughput is claimed.

The memory figure adds separately synthesized block counts to the engines;
it is not a connected system or a C1/C4 implementation measurement. LUT
resource efficiency does not account for DSP/BRAM costs. Full counts are saved.

## Reproduce

From the main repository checkout (bash):

```bash
export MXU16_TASK="$PWD/agent-tasks/mxu16-fpga-study"
export FIG5_RTL_ROOT="$(dirname "$PWD")/vortex-mxu16-rtl"
git worktree add --detach "$FIG5_RTL_ROOT" f1f6303b112e060e56f0512294bd86f2be373b26
python3 "$MXU16_TASK/prepare_rtl.py" "$FIG5_RTL_ROOT"
cd "$FIG5_RTL_ROOT/build-mxu16-fpga"
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
export PATH=/opt/vortex/verilator/share/verilator/bin:$PATH
export VIVADO=/tool/Program/Xilinx/2025.1/Vivado/bin/vivado
source "$MXU16_TASK/../../configs/mxu16_fpga_compute.sh"
python3 "$MXU16_TASK/run.py" --kind compute --points fp_tcu_64 wkv_16x16
python3 "$MXU16_TASK/check_geometry.py"
python3 "$MXU16_TASK/prepare_test.py"
python3 "$MXU16_TASK/../../tools/verify_rtl.py" unittest \
    --path "$PWD/array_fpga_test" --sim vlt > array_fpga_test/verification.json
python3 "$MXU16_TASK/../array-fpga-study/check_vendor_ip.py" "$PWD/mxu16_fpga/wkv_16x16"
python3 "$MXU16_TASK/run.py" --kind compute --points woq_16x16
source "$MXU16_TASK/../../configs/fig5_fpga_memory.sh"
python3 "$MXU16_TASK/run.py" --kind memory --parallel 2
python3 "$MXU16_TASK/collect.py" "$PWD"
python3 "$MXU16_TASK/verify.py"
# Install "$MXU16_TASK/requirements.txt" in a plotting environment first.
python3 "$MXU16_TASK/plot.py"
```

Use a fresh build for synthesis reruns; the runner refuses to overwrite
completed checkpoints. `--prepare-only` emits source snapshots without
launching synthesis. Scripts retain inputs, SHA-256 hashes, wrapper edits,
commands, raw reports, clock constraints and verification logs.

The directed test is the original array study's test with only the expected
coverage counter resized from 18x32 to 18x16 lanes. It checks Q-COL WoQ/WKV
cycle/data equality, numerical oracle, both buffers, K accumulation, input
bubbles, reset/restart, and WKV Q-ROW with column loading. Three seeds cover
864 output lanes. This is bounded finite arithmetic, not exhaustive IEEE
verification; actual AMD FP IP burst/latency is checked separately. The TCU
geometry check is elaboration-based and is not a new TCU functional test.

Offline replay (no Vivado or original build paths required):

```bash
python3 agent-tasks/mxu16-fpga-study/verify.py
python3 agent-tasks/mxu16-fpga-study/plot.py
```

`results/engine_resource_breakdown.pdf` and `results/memory_scaling.pdf` are the
compact paper candidates. JSON/CSV retain all resource dimensions and overhead
denominators. Reference synthesis results are only valid once collection and
verification complete successfully. The global repository ignore rules exclude
`results/`; review and explicitly stage selected small artifacts when committing,
rather than adding the build tree or checkpoints.

## Measured result

All nine synthesis/optimization points completed successfully. The report
verifier passed: zero blackboxes, zero unclocked sequential pins, zero internal
unconstrained endpoints/loops, matched WoQ/WKV ACC and FP IP settings, report
hashes/counts, independent total-versus-hierarchy reconciliation, and all numeric
plot inputs. RTL directed tests passed all three seeds (864 output lanes),
geometry elaboration confirmed 64/256 MAC/cycle and 256 KiB ACC, and the actual
AMD IP test passed (27 transactions, 18 consecutive outputs, 1-cycle latency).

| Engine | MAC/cycle | LUT | FF | DSP | BRAM36 eq. | URAM |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| FP TCU | 64 | 20,930 | 32,563 | 256 | 1 | 0 |
| WoQ 16x16 | 256 | 47,324 | 19,548 | 480 | 58 | 0 |
| WKV 16x16 | 256 | 51,070 | 21,796 | 496 | 58 | 0 |

- WKV over WoQ: +3,746 LUT (+7.916%), +2,248 FF (+11.500%), +16 DSP (+3.333%).
- WKV input scaler: 1,537 LUT + 1,152 FF + 16 DSP, or 3.010% of WKV LUTs
  and 3.226% of WKV DSPs. These component shares are not the total extension cost.
- Relative nominal WKV/TCU GOPS/kLUT: **1.639x engine only -> 0.822x including
  the independently synthesized memory blocks** (original study: 2.192x -> 0.870x).
- Relative nominal WKV/TCU GOPS/DSP: **2.065x**. WKV uses more absolute DSPs;
  its nominal arithmetic throughput is four times larger.

[Engine breakdown](results/engine_resource_breakdown.pdf),
[memory-cost comparison](results/memory_scaling.pdf),
[all resource counts](results/resources.csv),
[overhead denominators](results/overhead.json).
