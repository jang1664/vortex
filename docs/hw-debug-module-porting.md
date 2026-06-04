# ENABLE_HW_DEBUG_MODULE Porting Guide

This document explains how to port the optional hardware debug module to another
Vortex branch. It is written as a branch-porting checklist rather than a design
proposal.

## Goal

`ENABLE_HW_DEBUG_MODULE` adds a low-intrusion MMIO debug block for cases where a
real FPGA run appears hung and internal state is otherwise invisible. When the
macro is disabled, the design should compile to the original port shape and
behavior.

The module records:

- Last and sampled committed PCs from the core pipeline.
- AFU state and pending-write state.
- Memory AXI and control AXI-Lite counters.
- Sticky anomaly/protocol flags for suspicious signal combinations.
- First and last low 32 bits of the cycle counter when an anomaly was observed.

The MMIO interface uses an indirect selector, so only four registers are added to
the XRT control address map.

## User-Facing Register Interface

Add these AXI-Lite control registers only when `ENABLE_HW_DEBUG_MODULE` is set:

| Offset | Name | Access | Meaning |
| --- | --- | --- | --- |
| `0x0C0` | `DBG_SEL` | RW | Indirect selector: `[7:0] metric`, `[15:8] AXI port`, `[23:16] PC ring slot` |
| `0x0C4` | `DBG_DATA_LO` | RO | Selected 64-bit debug value `[31:0]` |
| `0x0C8` | `DBG_DATA_HI` | RO | Selected 64-bit debug value `[63:32]` |
| `0x0CC` | `DBG_CTRL` | RW/RO | Write bit0 to clear, write bit1 to freeze/unfreeze; read status |

`DBG_CTRL` read status format:

| Bits | Meaning |
| --- | --- |
| `[0]` | debug module present |
| `[1]` | snapshot frozen |
| `[2]` | any anomaly flag observed |
| `[23:16]` | PC source count |
| `[31:24]` | AXI memory port count |

Selector metric IDs:

| Metric | Meaning |
| --- | --- |
| `0x00` | module ID |
| `0x01` | AFU status, including `vx_pending_writes` |
| `0x02` | cycle count |
| `0x03` | PC event count |
| `0x04` | last PC metadata |
| `0x05` | last PC value |
| `0x06` | same-PC streak count |
| `0x07` | PC hash |
| `0x08` | PC ring metadata |
| `0x09` | PC ring value |
| `0x0a` | global anomaly flags |
| `0x0b` | anomaly cycle pair: `{last_cycle_lo, first_cycle_lo}` |
| `0x10`-`0x20` | memory AXI counters, last transactions, response error count |
| `0x21` | selected memory AXI port sticky flags |
| `0x30`-`0x33` | control AXI-Lite status, counters, last write, last read |
| `0x34` | control AXI-Lite sticky flags |

Global anomaly flag bits:

| Bit | Meaning |
| --- | --- |
| `0` | summary bit, high if any detailed flag is set |
| `1` | `vx_pending_writes` sign bit became high |
| `2` | next `vx_pending_writes` update would underflow |
| `3` | next `vx_pending_writes` update would overflow |
| `4` | control AXI-Lite protocol/stability anomaly |
| `5` | memory AXI protocol/stability anomaly |
| `6` | control AXI-Lite non-OKAY response |
| `7` | memory AXI non-OKAY response |

Control and memory AXI flag bits:

| Bit | Meaning |
| --- | --- |
| `0` | AW payload changed while `AWVALID && !AWREADY` |
| `1` | W payload changed while `WVALID && !WREADY` |
| `2` | B payload changed while `BVALID && !BREADY` |
| `3` | AR payload changed while `ARVALID && !ARREADY` |
| `4` | R payload changed while `RVALID && !RREADY` |
| `5` | B response arrived with no matching write outstanding |
| `6` | R response arrived with no matching read outstanding |
| `7` | BRESP was not OKAY |
| `8` | RRESP was not OKAY |

Note: in the current implementation, memory AXI `WDATA/WSTRB/RDATA` are not wired
into `VX_hw_debug`, so memory data payload stability is not checked. Control
AXI-Lite `WDATA/RDATA` are checked.

## Porting Checklist

### 1. Add shared debug sizing localparams

File: `hw/rtl/VX_gpu_pkg.sv`

Add localparams after `NUM_SOCKETS` is defined:

```systemverilog
localparam HW_DEBUG_NUM_PC_SOURCES = `NUM_CLUSTERS * NUM_SOCKETS * `SOCKET_SIZE;
localparam HW_DEBUG_CORE_ID_WIDTH = `UP(`CLOG2(HW_DEBUG_NUM_PC_SOURCES));
```

Keep these localparams outside the macro guard. They are harmless when the debug
module is disabled and make conditional port declarations easier.

### 2. Export commit PC events from `VX_commit`

File: `hw/rtl/core/VX_commit.sv`

Under `ENABLE_HW_DEBUG_MODULE`, add output ports:

```systemverilog
output wire                         hw_debug_pc_valid,
output wire [NW_WIDTH-1:0]          hw_debug_pc_wid,
output wire [`XLEN-1:0]             hw_debug_pc
```

Capture only committed end-of-packet events:

- Use `per_issue_commit_fire[i] && per_issue_commit_eop[i]`.
- Convert the compressed PC with `to_fullPC(commit_arb_if[i].data.PC)`.
- Select the first valid issue lane in a combinational block.

Important VCS gotcha:

- Do not dynamically index `commit_arb_if[i].data.*` inside a procedural loop.
- First assign interface fields into packed arrays inside the existing `genvar`
  generate loop, then index those packed arrays procedurally.

Expected pattern:

```systemverilog
wire [`ISSUE_WIDTH-1:0][`XLEN-1:0] per_issue_commit_pc;

for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin : g_commit_arbs
    ...
    assign per_issue_commit_pc[i] = to_fullPC(commit_arb_if[i].data.PC);
end
```

### 3. Propagate PC sideband through the core hierarchy

Add conditional output ports and connections through these files:

- `hw/rtl/core/VX_core.sv`
- `hw/rtl/VX_socket.sv`
- `hw/rtl/VX_cluster.sv`
- `hw/rtl/Vortex.sv`
- `hw/rtl/Vortex_axi.sv`

Port shape:

- `VX_core` exports a single event plus `hw_debug_pc_core_id`.
- `VX_socket` exports arrays of `SOCKET_SIZE`.
- `VX_cluster` exports arrays of `NUM_SOCKETS * SOCKET_SIZE`.
- `Vortex` and `Vortex_axi` export arrays of `HW_DEBUG_NUM_PC_SOURCES`.

Use static generate-time slices, not procedural dynamic indexing:

```systemverilog
.hw_debug_pc_valid(
    hw_debug_pc_valid[socket_id * `SOCKET_SIZE +: `SOCKET_SIZE]
)
```

Core ID:

```systemverilog
assign hw_debug_pc_core_id = HW_DEBUG_CORE_ID_WIDTH'(CORE_ID);
```

### 4. Extend `VX_afu_ctrl` with the debug MMIO window

File: `hw/rtl/afu/xrt/VX_afu_ctrl.sv`

Under `ENABLE_HW_DEBUG_MODULE`, add ports:

```systemverilog
output wire [31:0] hw_debug_select,
output wire        hw_debug_clear,
output wire        hw_debug_freeze,
input  wire [63:0] hw_debug_rdata,
input  wire [31:0] hw_debug_status,
```

Add address decode entries:

```systemverilog
ADDR_DBG_SEL    = 8'hC0,
ADDR_DBG_DATA_0 = 8'hC4,
ADDR_DBG_DATA_1 = 8'hC8,
ADDR_DBG_CTRL   = 8'hCC,
```

Write behavior:

- `DBG_SEL`: normal masked 32-bit write.
- `DBG_CTRL[0]`: one-cycle clear pulse.
- `DBG_CTRL[1]`: sticky freeze register.

Read behavior:

- `DBG_SEL`: current selector.
- `DBG_DATA_0/1`: selected 64-bit data halves.
- `DBG_CTRL`: `hw_debug_status`, with bit1 overwritten by the local freeze
  register so software can confirm freeze state.

### 5. Add `VX_hw_debug.sv`

File: `hw/rtl/afu/xrt/VX_hw_debug.sv`

Instantiate this as a standalone module guarded by `ENABLE_HW_DEBUG_MODULE`.

Inputs should include:

- AFU state: `ap_reset`, `ap_start`, `ap_done`, `ap_idle`, `ap_ready`,
  `ap_state`, `ap_done_base`, `ap_done_wait_cache`, `vx_busy`,
  `vx_cache_drain`, `vx_pending_writes`.
- PC sideband arrays from `Vortex_axi`.
- AXI-Lite control signals.
- Memory AXI address/id/len/resp/last valid-ready signals.
- `m_axi_wr_req_fire`, generated by `VX_axi_write_ack`.

Counters and state to preserve:

- Cycle count.
- PC event count, last PC, same-PC streak, hash, sampled ring.
- Control and memory AXI fire/stall/outstanding counters.
- Last AW/AR/B/R transaction summaries.
- Sticky anomaly flags and first/last anomaly cycles.

Reset/clear behavior:

- `reset || debug_clear` clears all counters, sampled PCs, outstanding counts,
  and sticky flags.
- `debug_freeze` stops all debug state updates so software can read a consistent
  multi-register snapshot.

### 6. Instantiate the debug block in `VX_afu_wrap`

File: `hw/rtl/afu/xrt/VX_afu_wrap.sv`

Under `ENABLE_HW_DEBUG_MODULE`:

- Declare wires for control register outputs and debug readback.
- Declare PC sideband arrays from `Vortex_axi`.
- Connect debug ports to `VX_afu_ctrl`.
- Connect PC sideband ports to `Vortex_axi`.
- Instantiate `VX_hw_debug`.

Use:

```systemverilog
.reset(reset || ap_reset)
```

Pass `m_axi_mem_*_a` signals after platform address offset has been applied.

`m_axi_wr_req_fire` is already computed for pending-write tracking:

```systemverilog
VX_axi_write_ack axi_write_ack (... .tx_ack(m_axi_wr_req_fire[i]), ...);
```

Port type gotcha:

- In `VX_afu_wrap`, `m_axi_wr_req_fire` is a packed vector.
- In `VX_hw_debug`, declare it as:

```systemverilog
input wire [NUM_AXI_PORTS-1:0] m_axi_wr_req_fire
```

### 7. Update XRT packaging

File: `hw/syn/xilinx/xrt/package_kernel.tcl`

Parse the define:

```tcl
set hw_debug_module 0
...
if { $name == "ENABLE_HW_DEBUG_MODULE" } {
    set hw_debug_module 1
}
```

Force package the source:

```tcl
set force_packaged_sources {
    VX_dma_engine.sv
    VX_hw_debug.sv
    vcs_fsdb_init.sv
}
```

Add register metadata only when the macro is enabled:

```tcl
if { $hw_debug_module == 1 } {
    # DBG_SEL, DBG_DATA_LO, DBG_DATA_HI, DBG_CTRL at 0x0C0..0x0CC
}
```

Add a collision guard because memory bank registers start at `0x30` and consume
`8 * NUM_DMA_PORTS` bytes:

```tcl
set hw_debug_base 0xC0
set mem_regs_end [expr {0x30 + $num_ports * 8}]
if { $hw_debug_module == 1 && $mem_regs_end > $hw_debug_base } {
    error "debug register window overlaps MEM registers"
}
```

### 8. Add runtime support

Files:

- `runtime/xrt/vx_hw_debug.h`
- `runtime/xrt/vx_hw_debug.c`
- `runtime/xrt/Makefile`
- `runtime/xrt/vortex_v5.cpp`

The C util uses callback-based MMIO access:

```c
typedef int (*vx_hw_debug_read32_cb)(void *opaque, uint32_t addr, uint32_t *value);
typedef int (*vx_hw_debug_write32_cb)(void *opaque, uint32_t addr, uint32_t value);
```

This keeps it reusable from:

- the current C++ XRT runtime,
- future `vx_wait` polling code,
- standalone debug tools that can provide `read32/write32`.

In `vortex_v5.cpp`, add a small adapter:

```c++
static int hw_debug_read32(void *opaque, uint32_t addr, uint32_t *value) {
  return static_cast<vx_device *>(opaque)->read_register(addr, value);
}

static int hw_debug_write32(void *opaque, uint32_t addr, uint32_t value) {
  return static_cast<vx_device *>(opaque)->write_register(addr, value);
}
```

Then call:

```c++
vx_hw_debug_io_t io = { this, hw_debug_read32, hw_debug_write32 };
vx_hw_debug_dump(stderr, &io, NUM_DMA_CHANNELS, HW_DEBUG_PC_RING_DEPTH,
                 "[VXDRV-HWDBG]");
```

For future periodic polling in `ready_wait`, keep a persistent:

```c
vx_hw_debug_flag_snapshot_t previous = {0};
```

and periodically call:

```c
vx_hw_debug_poll_flags(stderr, &io, NUM_DMA_CHANNELS, &previous,
                       "[VXDRV-HWDBG]");
```

### 9. Build and verification

After changing source-tree Makefiles, regenerate the configured build tree:

```bash
cd build
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
```

Run macro-on RTL simulation:

```bash
cd build
make -C sim/xrtsim_vcs clean
ci/run_black.sh xrt-vcs-sim --hw-debug --app basic --args ""
```

Run macro-off regression after a clean rebuild:

```bash
cd build
make -C sim/xrtsim_vcs clean
ci/run_black.sh xrt-vcs-sim --app basic --args ""
```

Run whitespace check from the source tree:

```bash
git diff --check
```

Expected result:

- Macro-on VCS compiles `VX_hw_debug`.
- Macro-off VCS does not instantiate `VX_hw_debug`.
- Both `basic` runs report `Test PASSED`.

## Common Pitfalls

- Do not use dynamic procedural indexing into SystemVerilog interface arrays in
  `VX_commit`; VCS rejects this. Copy interface fields to packed wires first.
- Do not add debug registers above `0xff` unless `VX_afu_ctrl` address decode is
  widened beyond 8 bits.
- Keep all new RTL ports under `ENABLE_HW_DEBUG_MODULE` so macro-off top-level
  ports remain unchanged.
- Do not rely on stale `simv`. Clean `sim/xrtsim_vcs` before switching between
  macro-on and macro-off verification.
- `runtime/xrt/vortex.cpp` is a symlink to `vortex_v5.cpp`; edit
  `vortex_v5.cpp` directly.
- The build tree contains configure-generated copies. After changing
  `runtime/xrt/Makefile`, rerun `../configure` from the build directory.
