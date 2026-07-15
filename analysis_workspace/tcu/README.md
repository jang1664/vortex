# TCU Synthesis Report Analysis

`analyze_tcu.py` scans Vortex TCU synthesis runs and uses `hwexplorer` to parse:

- Design Compiler hierarchical area reports (`14_*.mapped.area.rpt`)
- Design Compiler hierarchical power reports (`18_*.mapped.power.rpt`)
- Design Compiler timing reports (`12_*.mapped.timing.rpt`)

It reports top-level area, power, timing, cell counts, TCU functional block counts, and normalized hierarchy module-family instance counts.

## Environment

Activate the requested Conda environment:

```bash
conda activate vortex
```

The script first uses an installed `hwexplorer` package. If it is not installed, it also looks for the repository sibling checkout at:

```text
/home/jaeyong.jang/project.local/research/hwexplorer
```

## Basic usage

From the Vortex repository root:

```bash
python analysis_workspace/tcu/analyze_tcu.py
```

The default input root is:

```text
build/hw/syn/synopsys/tcu
```

The default output directory is:

```text
analysis_workspace/tcu/results
```

Generated files:

| File | Contents |
|---|---|
| `summary.csv` | One row per synthesis run with area, power, timing, utilization, and cell counts |
| `functional_breakdown.csv` | TCU-specific hierarchy categories and their instance counts, area, and power |
| `module_instances.csv` | Module-family instance counts with cumulative global area, non-overlapping local area, and power |
| `analysis.json` | Machine-readable copy of all standard results |
| `analysis.md` | Human-readable run summary and functional breakdown |

## Selecting runs

List discovered runs:

```bash
python analysis_workspace/tcu/analyze_tcu.py --list-runs
```

Analyze only the thread-16 BHF run:

```bash
python analysis_workspace/tcu/analyze_tcu.py \
  --run 'synthesis_th16/tcu_unit_bhf/*'
```

`--run` accepts shell-style globs and can be repeated.

## Raw hierarchy export

The full area hierarchy is large, so it is optional:

```bash
python analysis_workspace/tcu/analyze_tcu.py --raw-hierarchy
```

This adds `hierarchy.csv`, with area rows joined to matching power hierarchy paths.

## Other options

```bash
python analysis_workspace/tcu/analyze_tcu.py --help
```

Useful options include:

- `--build-root PATH`: scan another TCU synthesis root.
- `--output-dir PATH`: write results somewhere else.
- `--require-power`: fail instead of producing empty power columns when a power report is missing.

## Accounting notes

- Synopsys hierarchy `Global area` and hierarchy power are cumulative subtree values. Do not add a parent category to its descendants.
- `local_area_sum_um2` contains only area owned directly by matched hierarchy rows and is suitable for non-overlapping module-family accounting.
- Power is reported in mW except leakage, which is reported in uW by the current synthesis reports.
- Current TCU power reports warn that primary inputs and sequential outputs are not fully annotated, so the values are vectorless synthesis estimates rather than workload-annotated power.
