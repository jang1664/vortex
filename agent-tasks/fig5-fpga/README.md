# Fig. 5 FPGA feasibility experiment

The saved experiment uses RTL commit `f1f6303b112e060e56f0512294bd86f2be373b26`
from `fpint-fpga`, with Vivado 2025.1 for
`xcu55c-fsvh2892-2L-e` (U55C). It does not modify production RTL or the paper.
The build outputs are under `build-fig5-fpga/fig5_fpga` and
`build-fig5-fpga/fig5_fpga_compute`.

## Method

Each block is synthesized out of context with a 10 ns clock constraint. The
production `hw/scripts/xilinx_async_bram_patch.tcl` transformation is applied,
then `opt_design` and hierarchical utilization reporting. Checkpoint recovery
explicitly reloads `clock.xdc` before optimization. All black boxes must
be resolved. `post_opt.dcp`, source snapshots and hashes, manifests, logs and
reports are retained. Counts are post-synthesis/logic-optimization resources,
not placed-and-routed resources. No achieved Fmax or timing closure is claimed.

Memory sweep (capacity is fixed within each pair):

| Block | Small | Expanded | Other parameters |
| --- | --- | --- | --- |
| LMEM | 16 requests/banks | 64 requests/banks | 512 KiB, 8-byte word, full crossbar |
| Cache | 2 requests/banks/memory ports | 8 requests/banks/memory ports | 4 MiB, 64-byte line, 16-byte word, 4 ways, 16 MSHRs |
| AXI adapter | 2 input ports | 8 input ports | 32 output banks, 512-bit data |

This preserves the original Fig. 5 sweep's widths and capacities, using current
RTL. In particular, current cache RTL mixes crossbars and an Omega memory
response network. The experiment therefore is not an exact reconstruction of
the old ASIC netlist or an all-crossbar topology. Total block LUTs include
routing, storage wrappers and control; do not label total LUTs as crossbar-only.
BRAM/URAM are separate resource dimensions, not converted into LUT equivalents.

Compute follow-up uses the actual `VX_tcu_top` and `VX_gemm_unit_top` modules:

- FP16 TCU: `NUM_THREADS=32`, 8 x 4 results x 8 packed products = 256 MAC/cycle.
  The existing DSP implementation widens FP16 inputs for Xilinx floating-point
  multiply/add IP. This is not an idealized 16 x 16 FP16 array.
- FP-INT MXU: 32 x 32 = 1024 MAC/cycle, including prealignment, scaling,
  accumulation and local control. Its internal ACC is 256 KiB with BRAM selected.
  The TCU has no equivalent ACC allocation, so total storage is not iso-capacity.
- Xilinx FP IP settings are copied from `hw/scripts/xilinx_ip_gen.tcl`.
- A typo in the standalone TCU wrapper's execute-interface instance name is
  corrected only in the preprocessed experiment snapshot; the correction and
  hashes are recorded in `snapshot.json`. Production RTL is unchanged.

The follow-up adds separately synthesized block costs: small memory blocks to
the TCU, expanded blocks to the MXU. It does not connect these blocks, model all
SIMT/register-file/T-DMA/shell costs, measure C1/C4, or measure sustained
throughput. Nominal throughput uses two operations per MAC at a common 100 MHz;
GOPS/kLUT and GOPS/DSP must be accompanied by the other resource counts.

## Reproduce

There are two independent paths: replay the saved figures without Vivado, or
rerun synthesis from the exact RTL revision. Run shell commands in **bash**.
The scripts do not edit `paper/overleaf_fpga` or production RTL.

### 1. Verify saved measurements and redraw the figures (no Vivado)

From the repository root:

```bash
export FIG5_TASK_DIR="$PWD/agent-tasks/fig5-fpga"
python3 "$FIG5_TASK_DIR/verify_results.py" "$FIG5_TASK_DIR/results"

# Any Python >= 3.10 environment with the pinned matplotlib version works.
python3 -m venv /tmp/fig5-python
/tmp/fig5-python/bin/python -m pip install -r "$FIG5_TASK_DIR/requirements.txt"
export FIG5_PYTHON=/tmp/fig5-python/bin/python
"$FIG5_PYTHON" "$FIG5_TASK_DIR/plot.py" "$FIG5_TASK_DIR/results" \
    --output /tmp/fig5-redrawn
```

This produces `memory_scaling.{pdf,png}` and
`fig5_fpga_feasibility.{pdf,png}`. PDF timestamps can differ. The verifier checks
all eight report hashes/statuses, resource values against the raw utilization
reports, CSV/JSON agreement, additive resource totals and efficiency arithmetic.
The saved dataset includes original report paths for provenance; those old
absolute paths are **not required** for this replay.

### 2. Rerun synthesis with the exact RTL (Vivado required)

Prerequisites: Vivado **2025.1** with U55C device support and a working license;
Verilator **5.028** for preprocessing; Python >= 3.10 and matplotlib 3.10.8 for
plots. The original flow uses at most two simultaneous top-level synthesis jobs,
each with four Vivado threads. Allow tens of minutes and ample RAM/disk space.
XRT and a physical FPGA card are not needed for this OOC experiment.

Use a detached worktree to keep the measured RTL revision separate from newer
team changes. The worktree path below must not already exist. The harness and
configs remain in the current checkout; `FIG5_RTL_ROOT` selects only RTL,
headers, the FP IP configuration, and the stock async-BRAM patch.

```bash
# Start at the current repository root; keep FIG5_PYTHON from step 1.
export FIG5_TASK_DIR="$PWD/agent-tasks/fig5-fpga"
export FIG5_RTL_ROOT="$(dirname "$PWD")/vortex-fig5-rtl"
git worktree add --detach "$FIG5_RTL_ROOT" f1f6303b112e060e56f0512294bd86f2be373b26

# Adjust these installation paths on another host.
export VIVADO=/tool/Program/Xilinx/2025.1/Vivado/bin/vivado
export PATH="/opt/vortex/verilator/share/verilator/bin:$PATH"
verilator --version
"$VIVADO" -version

mkdir -p "$FIG5_RTL_ROOT/build-fig5-fpga"
cd "$FIG5_RTL_ROOT/build-fig5-fpga"
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"

# Six memory-subsystem points.
source "$FIG5_TASK_DIR/../../configs/fig5_fpga_memory.sh"
python3 "$FIG5_TASK_DIR/run.py" --parallel 2
"$FIG5_PYTHON" "$FIG5_TASK_DIR/summarize.py" "$PWD/fig5_fpga"

# Two actual compute engines; run after reviewing the memory experiment.
source "$FIG5_TASK_DIR/../../configs/fig5_fpga_compute.sh"
python3 "$FIG5_TASK_DIR/compute.py"
"$FIG5_PYTHON" "$FIG5_TASK_DIR/compare.py" "$PWD"
```

`VIVADO` overrides the executable; otherwise the harness tries `vivado` on PATH
and then the original host installation. Without `FIG5_RTL_ROOT`, it uses the
checkout containing the harness, which is useful for new experiments but does
not pin the saved experiment's RTL. Do not mix revisions/configs within a build
directory. The pinned TCU wrapper correction is recorded in `snapshot.json`.

For a preprocessing-only smoke check, use `run.py --prepare-only` and
`compute.py --prepare-only` after sourcing their respective configs, in a fresh
configured build directory. No Vivado synthesis is launched by these options.
For unchanged memory checkpoints, use `run.py --reuse-synth --points lmem_64`
to repeat the stock RAM patch, constrained `opt_design` and reporting. This
explicitly reloads `clock.xdc`; raw `synth_1/*.dcp` utilization is not the final
measurement. Run the summarizer again after a successful recovery.

### Inputs, outputs and reference values

- Configs: `configs/fig5_fpga_memory.sh`, `configs/fig5_fpga_compute.sh`.
- Source list: `results/source_provenance.json` records the original RTL paths
  and SHA-256 hashes of all 151 preprocessed source files, including the TCU
  wrapper correction. Per-run snapshots/manifests retain the actual inputs.
- Fresh outputs: `fig5_fpga/resources.csv`, `fig5_fpga/memory_scaling.pdf`,
  `fig5_fpga_compute/comparison.csv`, `fig5_fpga_compute/interpretation.json`,
  and `fig5_fpga_compute/fig5_fpga_feasibility.pdf` in the configured build.
- Checked-in reference: `results/` contains CSV/JSON, figures, eight utilization
  reports, manifests, status records and `audit.json`. Large projects,
  checkpoints, full logs and source snapshots remain in the build directory.
- `results/` is ignored by the repository globally; its selected reference
  files are intentionally tracked. To publish a new dataset, review it and
  explicitly stage the desired files rather than an entire build directory.

| Point | LUT | FF | DSP | BRAM36 equivalents | URAM |
| --- | ---: | ---: | ---: | ---: | ---: |
| LMEM 16 | 23,256 | 18,448 | 0 | 128 | 0 |
| LMEM 64 | 338,624 | 214,528 | 0 | 128 | 0 |
| Cache 2 | 9,486 | 13,803 | 0 | 1,099 | 0 |
| Cache 8 | 45,635 | 65,179 | 0 | 1,232 | 0 |
| AXI 2 | 15,332 | 8,390 | 0 | 0 | 0 |
| AXI 8 | 61,235 | 33,554 | 0 | 0 | 0 |
| FP16 TCU | 80,662 | 126,202 | 1,024 | 1 | 0 |
| FP-INT 32 x 32 | 147,203 | 50,704 | 1,857 | 58 | 0 |

Use the same tool version, RTL, defines and part to compare against these
values; changing them creates a new experiment. BRAM equivalents are
`RAMB36 + RAMB18/2`. The historical full reports and checkpoints are under
`/home/donghweeson/workspace/vortex/build-fig5-fpga` on the original host.

## Warning audit

AXI tag buffers intentionally take the asynchronous RAM fallback in the stock
patch (`is_raddr_reg=0` selects `rdata_a`); the warning text says "Grounding"
but refers to the unused synchronous address/control path, not the live data.
OOC clock-source/clock-buffer warnings do not establish implemented timing.
Early recovery reports without reloaded XDC were superseded by constrained
reruns; do not use intermediate raw synthesis or unconstrained results.

## Saved outcome (2026-09-30)

The small final artifacts and utilization reports are preserved in `results/`,
with successful status, clock checks and report hashes in `results/audit.json`.
All eight points completed with zero unresolved black boxes and zero unclocked
sequential pins. The constraints do not substitute for post-route timing.

LMEM LUTs scale 23,256 to 338,624 (14.56x); cache 9,486 to 45,635
(4.81x); AXI adapter 15,332 to 61,235 (3.99x). Cache BRAM36-equivalent
use grows from 1,099 to 1,232 despite fixed logical capacity.
The engine-only relative nominal GOPS/kLUT is 2.19x, falling to 0.87x
when the independently synthesized memory subsystems are added. This supports
replacing Fig. 5 with an explicitly scoped FPGA resource-scaling experiment.
It does not establish that a deployed FP-INT system is slower or less efficient.
FP-INT uses more total DSPs (1,857 vs 1,024); its nominal GOPS/DSP is 2.21x
higher because its MAC throughput is four times larger.

## Reproducibility checks for this package

A fresh detached checkout of the pinned RTL commit was configured and both
`--prepare-only` commands were run: all **151 preprocessed source hashes**
matched the saved experiment. Re-extracting the existing Vivado reports
reproduced both numeric datasets, and the standalone plot command reproduced
both saved PNGs byte-for-byte with matplotlib 3.10.8. The saved-result verifier
passed for all eight blocks. Full synthesis was completed for the original
measurement; the packaging check did not repeat those long synthesis jobs.
