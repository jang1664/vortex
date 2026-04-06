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

# Basic: run app with a driver
./ci/blackbox.sh --driver=<driver> --app=<app> --args="<args>" --cores=<N> --threads=<N> --debug=<level>
```

## Drivers

| Driver | Description |
|---|---|
| `simx` | Software simulator (default, fastest) |
| `rtlsim` | Verilator RTL simulation |
| `xrt` | XRT runtime (for hw_emu or hw) |
| `xrt_vcs` | XRT runtime + VCS RTL simulation |
| `xrt_vcs_post` | XRT + VCS post-implementation gate sim |

## Common Examples

```bash
# Verilator RTL sim
./ci/blackbox.sh --driver=rtlsim --app=vecadd --args="-n 128" --cores=1 --threads=8 --debug=3

# XRT + VCS (needs CONFIGS, env vars)
CONFIGS="-DNUM_THREADS=8 -DLMEM_LOG_SIZE=22 -DDCACHE_DISABLE -DL2_ENABLE" \
DRIVER=xrt_vcs \
./ci/blackbox.sh --driver=xrt_vcs --app=vecadd --args="-n 128" --cores=1 --debug=3

# hw_emu (requires v++ xclbin built first)
CONFIGS="..." \
FPGA_BIN_DIR=hw/syn/xilinx/xrt/hw_emu/bin \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
DRIVER=xrt TARGET=hw_emu \
./ci/blackbox.sh --driver=xrt --app=vecadd --args="-n 128" --cores=1 --debug=3
```

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
| `CONFIGS` | Additional RTL build defines (e.g., `-DNUM_THREADS=8 -DLMEM_LOG_SIZE=22`) |
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
