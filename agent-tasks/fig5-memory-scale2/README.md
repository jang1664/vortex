# Fig. 5: 2x versus 4x memory-fabric scaling

This extends `../fpga-v2-resource-study` with three newly synthesized points:
`lmem_16`, `cache_2`, and `axi_2`. The original FP TCU, WKV, baseline memory,
and 4x measurements are reused without modifying their archived files.

| Parameter | FP TCU baseline | FP-INT 2x | FP-INT 4x |
| --- | ---: | ---: | ---: |
| LMEM requests/banks | 8 | 16 | 32 |
| Cache requests/banks/memory ports | 1 | 2 | 4 |
| AXI adapter input ports | 1 | 2 | 4 |
| Physical HBM output ports / transport groups | 32 | 32 | 32 |
| Nominal MAC/cycle | 128 | 256 | 256 |

The sweep changes AXI **input** ports, not physical HBM port count. LMEM is
512 KiB with 8-byte words; cache is 4 MiB with 16-byte words, 64-byte lines,
4 ways, and 16 MSHRs. AXI data width is 512 bits. FP-INT retains its separate
256 KiB internal ACC. Capacity, datapaths, and nominal frequency are unchanged.

Each figure normalizes FP-INT GOPS/kLUT against FP TCU in the same category.
The engine-only baseline therefore differs from the engine-plus-memory
baseline. The figures use identical axes and styling.

## Measured results

| Profile | LMEM LUTs | Cache LUTs | AXI LUTs | Engine + memory LUTs | Relative nominal GOPS/kLUT |
| --- | ---: | ---: | ---: | ---: | ---: |
| FP TCU baseline | 5,105 | 5,453 | 17,874 | 69,406 | 1.00 |
| FP-INT, 2x | 23,256 | 9,486 | 36,352 | 120,164 | 1.155188 |
| FP-INT, 4x | 87,873 | 20,612 | 59,963 | 219,518 | 0.632349 |

FP-INT's engine-only relative efficiency is **1.604621** in both figures.
The 2x profile retains a 15.5% nominal GOPS/kLUT advantage after memory costs;
the 4x profile falls below the FP TCU reference. These are area-efficiency
results using nominal throughput, not measured application speedups.

All three new synthesis/optimization jobs completed successfully. The offline
verifier passed all 12 raw report audits, archived source/report hashes,
resource arithmetic, CSV checks, and exact preservation of the 4x reference.

- [2x figure PDF](results/fig5_2x.pdf)
- [4x figure PDF](results/fig5_4x.pdf)
- [Raw resource table](results/resources.csv)

## Measurement and provenance

- RTL revision: `1e4b367cca8f1a11cff74ce6b428079621b3a398`.
- Vivado 2025.1, U55C `xcu55c-fsvh2892-2L-e`, 10 ns clock constraint.
- Original `fig5-fpga/run.py`, `synth.tcl`, and `report.tcl` perform OOC
  synthesis, the production async-RAM patch, and `opt_design`.
- Every preprocessed memory source is required to match the original
  baseline's archived SHA-256 before synthesis. Only top-level generics change.
- The AXI geometry smoke test enables production `SIMULATION` assertions and
  checks two input ports, 32 output ports, and 34-bit physical addresses.
- Report audits check success, zero black boxes, optimized state, resource
  agreement, clock constraints, and absence of unconstrained internal endpoints
  and timing loops. The reconstructed 4x comparison must equal the original.
- These are additive standalone block costs at a nominal 100 MHz. They do not
  measure sustained throughput, achieved Fmax, or integrated placed/routed cost.

The old study's full `verify.py` currently rejects the changed production
candidate config `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh`.
This extension instead verifies the archived measurements/reports and uses an
isolated checkout of their exact RTL revision. It does not use today's config
as evidence for the historical compute measurements.

## Reproduce

Run in Bash. `FIG5_TASK` points to this directory in the main checkout; the
runner loads the unchanged earlier experiment harness from its sibling tasks.

```bash
export FIG5_TASK="$PWD/agent-tasks/fig5-memory-scale2"
export FIG5_RTL_ROOT="$(dirname "$PWD")/vortex-fig5-scale2-1e4b367"
git worktree add --detach "$FIG5_RTL_ROOT" 1e4b367cca8f1a11cff74ce6b428079621b3a398
mkdir -p "$FIG5_RTL_ROOT/build-fig5-scale2"
cd "$FIG5_RTL_ROOT/build-fig5-scale2"
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
export PATH=/opt/vortex/verilator/share/verilator/bin:$PATH
export VIVADO=/tool/Program/Xilinx/2025.1/Vivado/bin/vivado
source ../configs/fig5_fpga_memory.sh
python3 "$FIG5_TASK/run.py" --parallel 2
python3 "$FIG5_TASK/collect.py" "$PWD"
```

Use a fresh build directory for a new synthesis run. The runner refuses to
overwrite completed checkpoints. To regenerate only the figures, use a Python
environment with `../fpga-v2-resource-study/requirements.txt` installed:

```bash
python3 agent-tasks/fig5-memory-scale2/verify.py
python3 agent-tasks/fig5-memory-scale2/plot.py --output build
python3 agent-tasks/fig5-memory-scale2/plot.py --combined --output build
```

Outputs are `fig5_2x.pdf`, `fig5_4x.pdf`, and PNG versions. Numeric inputs and
reports reside in `results/`; `interpretation.json` contains the relative
efficiencies and `resources.csv` contains raw resource counts.

The `--combined` option creates `fig5_combined.{pdf,png}` with Engine only,
`x2\n+Memory subsystem`, and `x4\n+Memory subsystem` groups. The red
"Memory subsystem overhead" box points to both memory-inclusive FP-INT bars.
This presentation uses the same measured values (1.60x, 1.16x, and 0.63x);
no additional synthesis is required. The plot script hash in `results/harness.json`
was refreshed for this presentation change on 2026-10-30.
