---
name: debug-xrt-vcs
description: Use when diagnosing Vortex blackbox failures in xrt_vcs mode, including compile logs, simv logs, X propagation, hangs, and waveform workflows.
---

# Debugging xrt_vcs Blackbox Tests

Guide for diagnosing failures in `blackbox.sh --driver=xrt_vcs` runs.

## Build & Run

All commands from the `build/` directory. Use `PATH=/usr/bin:$PATH` to avoid conda linker conflicts.

```bash
cd /home/jaeyongjang/project.local/vortex/build
PATH=/usr/bin:$PATH CONFIGS="$CONFIGS" timeout 300 \
  ./ci/blackbox.sh --driver=xrt_vcs --app=<app> --args="<args>" --cores=1 --threads=8 --debug=3
```

Always use the CONFIGS from `/run-bb-common` skill. **Never run with empty CONFIGS.**

## Log Locations

| Log | Path (relative to `build/`) | Contents |
|-----|------|----------|
| VCS compile log | `sim/xrtsim_vcs/compile.log` | Compilation errors, warnings |
| Simulation log | `sim/xrtsim_vcs/simv.log` | Runtime trace (`DBG_TRACE_*` output), X prop, pipeline state |
| blackbox wrapper | stdout/stderr of `blackbox.sh` | Build + run summary |
| Runtime | app stdout | `PASSED` / `FAILED` / register reads |

**Always check `compile.log` first for compile errors, then `simv.log` for simulation issues.**

## Failure Categories & Diagnosis

### 1. Compile Error
**Symptom**: VCS exits non-zero before `simv` is created. Check `compile.log`.
**Checklist**:
- Missing include? → Check `sim/xrtsim_vcs/Makefile` for AXI/common_cells include paths
- Macro conflict? → Add `+define+ASSERTS_OFF` to `VCS_FLAGS`
- `cf_math_pkg` not found? → Ensure conditional compile guard for `FPU_FPNEW`
- Undeclared identifier in `DBG_TRACE_*` block? → These blocks are only compiled with trace defines; unit tests won't catch them
- Interface array index error? → Use `genvar` + wire extraction, not runtime variable indexing

### 2. X Propagation
**Symptom**: `REG_READ: offset=0x00 value=0x0000000x` or PC shows `0xxxxxxxxx` in `simv.log`.

**Important**: PC is normally `x` during reset. After reset completes, PC should transition to a valid address (e.g., `0x80000000`). Do NOT conclude "X propagation failure" from early reset-phase `x` values alone — scroll past the reset period and check whether PC eventually becomes valid.

**Checklist**:
- AXI port count mismatch? → Check `PLATFORM_MEMORY_NUM_BANKS` vs actual HBM port count in DUT
- Unconnected AXI ports? → TB must instantiate memory models for ALL DUT AXI master ports
- DMA ports uninitialized? → Inactive DMA `valid`/`ready` signals must be tied to 0/1, not left floating
- Bank interleave mode? → Check runtime `BANK_INTERLEAVE` flag matches TB memory model addressing

### 3. Simulation Hang (Timeout)
**Symptom**: `timeout` kills simv, no `PASSED`/`FAILED` in log.
**Checklist**:
- Deadlock in AXI handshake? → Check `valid` asserted but `ready` never comes
- Cache drain stall? → Check if `AFU_DONE_WAIT_CACHE_DRAIN` is set and L2/L3 is configured
- Core stuck? → Look for PC not advancing in trace log

### 4. Simulation Fail (Wrong Result)
**Symptom**: `FAILED` in app output, or mismatch in expected vs actual.
**Checklist**:
- Address mapping wrong? → Check `LMEM_LOG_SIZE`, `STACK_BASE_ADDR`, `MEM_ADDR_WIDTH`
- Data corruption? → Look for overlapping address ranges between LSU and DMA paths
- Thread/core count mismatch? → Check `NUM_THREADS`, `NUM_CORES` in CONFIGS vs app args

## Debugging Strategy

Use a two-level approach: **log-based first, waveform second**.

### Level 1: Log-Based Debugging (try this first)

Analyze `simv.log` which contains `DBG_TRACE_*` output (pipeline, memory, cache, AFU, GEMM traces).

1. **Read `simv.log`** — search for `Fatal:`, `ERROR`, `MISMATCH`, X values after reset, or PC stuck patterns.
2. **Check PC progression** — find where PC transitions from `x` (reset) to a valid address. If it never does, the issue is in reset/boot path. If it does but later goes to `x` or stalls, narrow down the cycle range.
3. **Follow the data path** — use `DBG_TRACE_MEM`, `DBG_TRACE_CACHE`, `DBG_TRACE_AFU` to trace memory requests from core → cache → AXI → memory model.

**If existing traces are insufficient**: request the RTL Implementation subagent to add `DBG_TRACE_*` statements to the relevant RTL module. Then re-run the blackbox test. Specify:
- Which module/signal needs tracing
- What information to print (e.g., address, data, valid/ready, state)
- Which `DBG_TRACE_*` guard to use

### Level 2: Waveform Debugging (when logs aren't enough)

Use when log-based analysis can't pinpoint the issue (e.g., combinational glitches, multi-cycle timing, signal relationships across modules).

**Step 1: Generate FSDB waveform**
```bash
FSDB_DUMP=1 PATH=/usr/bin:$PATH CONFIGS="$CONFIGS" timeout 600 \
  ./ci/blackbox.sh --driver=xrt_vcs --app=<app> --args="<args>" --cores=1 --threads=8 --debug=3
```
Note: FSDB dump adds significant slowdown (~10x). Increase timeout accordingly.

**Step 2: Convert FSDB to FST**
```bash
# Check tools exist
which fsdb2vcd
which vcd2fst
# Convert: FSDB → VCD → FST
fsdb2vcd <fsdb_file> -o sim.vcd
vcd2fst sim.vcd sim.fst
```

**Step 3: Analyze with pywellen**
Use `pywellen` to extract and analyze specific signals without loading the entire waveform:
```python
import pywellen

fst = pywellen.open("sim.fst")

# List available signals (search by pattern)
signals = fst.list_signals("*axi*valid*")

# Load specific signal traces
sig = fst.signal("tb.dut.m_axi_mem_0_awvalid")
values = sig.changes()  # list of (time, value) tuples

# Analyze a time range
for t, v in values:
    if start_time <= t <= end_time:
        print(f"  t={t}: {v}")
```

Focus on:
- The signals identified as suspicious from log-based analysis
- Valid/ready handshake pairs on AXI interfaces
- State machine transitions in the suspected module

**Step 4 (optional): Interactive Verdi**
```bash
GUI=1 PATH=/usr/bin:$PATH CONFIGS="$CONFIGS" \
  ./ci/blackbox.sh --driver=xrt_vcs ...
```

## XRT Runtime in xrt_vcs Simulation

In `xrt_vcs` mode, the **XRT runtime** (`runtime/xrt/vortex.cpp`) runs on the host side and communicates with the VCS-simulated RTL. Understanding the runtime is critical because many failures originate from the host-device interface, not the RTL itself.

### Runtime Role in Simulation

```
Host process (C++ test app)
  → Vortex runtime API (vx_mem_alloc, vx_copy_to_dev, vx_start, ...)
    → XRT runtime (vortex_v2.cpp) — manages BOs, address mapping, DMA
      → XRT simulation bridge (xrtsim)
        → VCS simulated RTL (vortex_afu.v → Vortex core)
```

The runtime handles:
1. **Buffer allocation** — `vx_mem_alloc` → XRT buffer objects (BOs) on simulated HBM
2. **Data transfer** — `vx_copy_to_dev/from_dev` → BO write/sync → AXI transactions to RTL
3. **Kernel launch** — `vx_start` → MMIO register writes to AFU control
4. **Completion wait** — `vx_ready_wait` → polls AFU status register

### BANK_INTERLEAVE and Simulation

The runtime is compiled with `#define BANK_INTERLEAVE` by default. This affects how data reaches the simulated HBM:

- **ON:** Data is striped across BOs in 64B (cache-line) chunks. Address-to-bank mapping: `bank = (addr / 64) % num_banks`. This must match `PLATFORM_MEMORY_INTERLEAVE=1` in HW config.
- **OFF (default):** Data is placed contiguously in per-bank BOs. Address-to-bank mapping: `bank = addr / bank_size`. This must match `PLATFORM_MEMORY_INTERLEAVE=0` in HW config.

**Mismatch between runtime and HW config causes silent data corruption** — data ends up in the wrong bank/address, leading to wrong results or hangs that look like RTL bugs but are actually configuration bugs.

For detailed address mapping mechanics, see `docs/hbm-bank-interleaving.md`.

### Runtime Debug Logging

Compile the runtime with `DEBUG_XRT=1` to enable diagnostic output:
```bash
DEBUG_XRT=1 make -C runtime/xrt
```

This enables `DBG_PRINT` statements showing:
- Buffer allocation: bank, size, address
- Upload/download: per-chunk bank, offset, transfer size
- Kernel launch: kernel addr, args addr, bank mapping
- Bank overflow warnings

### Common Runtime-Related Failures

| Symptom | Likely runtime cause |
|---------|---------------------|
| Wrong results, no RTL errors | `BANK_INTERLEAVE` mismatch with `PLATFORM_MEMORY_INTERLEAVE` |
| Hang after `vx_start` | Kernel or args buffer landed in wrong bank → core reads garbage |
| `vx_ready_wait` timeout | AFU never signals done — check if MMIO addresses are correct |
| `ALLOC_FAIL` from kernel | LMEM layout doesn't fit — check `LMEM_LOG_SIZE` and `STACK_BASE_ADDR` |

### Key Runtime Files

| File | Role |
|------|------|
| `runtime/xrt/vortex.cpp` | Main XRT runtime (BO management, DMA, MMIO) |
| `runtime/common/vx_utils.cpp` | Memory allocator, alignment utilities |
| `sim/xrtsim/` | XRT simulation bridge (connects runtime to VCS) |

## Key Files

| File | Role |
|------|------|
| `sim/xrtsim_vcs/Makefile` | VCS build flags, include paths, source file list |
| `sim/xrtsim_vcs/tb_vcs_xrtsim.sv` | Top-level testbench (AXI memory model instantiation) |
| `hw/rtl/afu/xrt/VX_afu_wrap.sv` | AFU wrapper (AXI port count, address decode) |
| `hw/rtl/afu/xrt/VX_afu_ctrl.sv` | Device capability registers (bank count, cache config) |
| `hw/rtl/afu/xrt/vortex_afu.v` | Top-level Verilog wrapper |
| `hw/rtl/Vortex_axi.sv` | AXI routing (LSU demux, DMA mux, HBM ports) |

## Common Gotchas

- `ASSERTS_OFF` define is required to avoid macro conflict between Vortex and common_cells
- DBG_TRACE bugs only surface with full CONFIGS (unit tests don't enable trace defines)
- Conda linker conflict: always use `PATH=/usr/bin:$PATH` for VCS builds
- Two-stage verify: xrt_vcs first (fast), then hw_emu (closer to hardware)
- PC is `x` during reset — this is normal. Only flag X propagation if PC stays `x` after reset completes
