---
name: run-bb-common
description: Use when running Vortex blackbox tests from a configured build directory, especially xrt_vcs mode with correct CONFIGS and logging.
---

# Run Blackbox Test

Run a regression test via `ci/blackbox.sh` from the build directory.

## Prerequisites

The build directory must be configured first:
```bash
mkdir -p build && cd build
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
```
This generates `ci/blackbox.sh` from `ci/blackbox.sh.in`.

## Usage

All commands run from the `build/` directory.

```bash
cd build

# Base CONFIGS comes from hw_config.sh (auto-loaded via .envrc). Append only extras.
CONFIGS+=" -DDBG_TRACE_PIPELINE"
CONFIGS+=" -DDBG_TRACE_MEM"
CONFIGS+=" -DDBG_TRACE_CACHE"
CONFIGS+=" -DDBG_TRACE_AFU"
CONFIGS+=" -DDBG_TRACE_SCOPE"
CONFIGS+=" -DDBG_TRACE_GBAR"
CONFIGS+=" -DDBG_TRACE_TCU"
CONFIGS+=" -DDBG_TRACE_GEMM"
NUM_CORES=1
NUM_THREADS=8
DEBUG_LEVEL=3
CONFIGS="$CONFIGS" \
./ci/blackbox.sh --driver=<driver> --app=<app> --args="<args>" --cores=$NUM_CORES --threads=$NUM_THREADS --debug=$DEBUG_LEVEL
```
Use timeout to prevent hanging. First time, use 5 minutes to see if it completes. If it does not, check logs to see if it is stuck or just slow. For slow tests, increase timeout to 30 minutes.

```bash

## Drivers

| Driver | Description |
|---|---|
| `simx` | Software simulator (default, fastest) |
| `rtlsim` | Verilator RTL simulation |
| `xrt` | XRT runtime (for hw_emu or hw) |
| `xrt_vcs` | XRT runtime + VCS RTL simulation |
| `xrt_vcs_post` | XRT + VCS post-implementation gate sim |

## Key Options

| Option | Description |
|---|---|
| `--driver=<name>` | simx, rtlsim, xrt, xrt_vcs, xrt_vcs_post |
| `--app=<name>` | Test app folder name under `tests/regression/` or `tests/opencl/` |
| `--args="<args>"` | Arguments passed to the test app |
| `--cores=<N>` | Number of cores |
| `--threads=<N>` | Number of threads per core |
| `--debug=<level>` | Debug level (0=off, 3=verbose) |
| `--l2cache` | Enable L2 cache |
| `--l3cache` | Enable L3 cache |
| `--perf=<class>` | Performance counters (0=off, 1=pipeline, 2=memsys) |

## Environment Variables

| Variable | Description |
|---|---|
| `CONFIGS` | RTL build defines. Base set exported by `hw_config.sh` via `.envrc`; scripts append debug/test-specific extras. |
| `DRIVER` | Override driver (needed for xrt_vcs) |
| `TARGET` | `hw_emu` or `hw` (for XRT driver) |
| `FPGA_BIN_DIR` | Path to xclbin directory (hw_emu/hw) |
| `PLATFORM` | FPGA platform string |
| `FSDB_DUMP=1` | Enable FSDB waveform dump (xrt_vcs) |
| `GUI=1` | Launch Verdi for live waveform (xrt_vcs) |
| `LOG_MAX_BYTES` | Rolling log buffer size (keeps last N bytes) |

## Two-Stage Verification Flow

1. **xrt_vcs first** — faster, catches most RTL bugs
2. **hw_emu second** — builds xclbin via v++, closer to real hardware

## Reading Results

- Success: test app exits with status 0
- Failure: check the log file (`run_*.log` in build/) or simv log (`sim/xrtsim_vcs/simv.log`)
- Look for: `PASSED`, `FAILED`, `Error`, `Fatal`
