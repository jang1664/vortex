# HBM Bank Interleaving

## Background: U55C HBM Address Scheme

Xilinx U55C has 32 HBM pseudo-channels (PCs). The HBM controller always uses a **contiguous** address scheme — there is no hardware-level interleaving option:

```
PC 0:  [0x0_0000_0000, 0x0_2000_0000)   512 MB
PC 1:  [0x0_2000_0000, 0x0_4000_0000)   512 MB
PC 2:  [0x0_4000_0000, 0x0_6000_0000)   512 MB
...
PC 31: [0x3_E000_0000, 0x4_0000_0000)   512 MB
```

After `v++` synthesis, Vivado attaches the **HMSS (HBM Memory SubSystem)** which contains an AXI-based switch. This switch routes AXI transactions to the correct PC based on the address. From the HMSS's perspective, addresses are always contiguous.

## Vortex Memory Interleaving

Vortex has a `PLATFORM_MEMORY_INTERLEAVE` config parameter (default: 1). When enabled, the software side treats the HBM address space as **interleaved** — i.e., consecutive cache-line-sized blocks cycle through banks in round-robin. However, since the actual HBM/HMSS is always contiguous, an **address remap** is needed.

### The Problem

```
Software's view (interleaved):
  addr [0x000, 0x03F] → bank 0
  addr [0x040, 0x07F] → bank 1
  addr [0x080, 0x0BF] → bank 2
  ...

HBM's reality (contiguous):
  addr [0x0_0000_0000, 0x0_2000_0000) → PC 0
  addr [0x0_2000_0000, 0x0_4000_0000) → PC 1
  ...
```

These two views are incompatible. The interleaved address must be remapped to a contiguous address before it reaches the HMSS.

### The Solution: VX_axi_adapter

`VX_axi_adapter.sv` (parameter `INTERLEAVE=1`) performs the remap. It extracts the bank index from the lower address bits and reconstructs a contiguous address for the AXI output:

**Incoming address (interleaved view):**
```
[bank_addr] [bank_sel] [byte_offset]
             (log2 N)   (log2 DATA_SIZE)
```

- `bank_sel = addr[BANK_SEL_BITS-1 : 0]` — selects which AXI port (bank)
- `bank_addr = addr >> BANK_SEL_BITS` — per-bank address

**Outgoing AXI address (contiguous, per port `i`):**
```
m_axi_addr[i] = (bank_addr << (BANK_SEL_BITS + LOG2_DATA_SIZE))
              | (i << LOG2_DATA_SIZE)
```

This reconstructs the flat contiguous address that the HMSS expects: the bank index `i` is placed back into the address so the HMSS routes it to the correct PC.

**Non-interleaved mode** (`INTERLEAVE=0`) uses upper bits for bank selection instead:
```
bank_sel  = addr[MSB -: BANK_SEL_BITS]   // upper bits → bank
bank_addr = addr[BANK_ADDR_WIDTH-1 : 0]  // lower bits → per-bank addr
```

## PLATFORM_MERGED_MEMORY_INTERFACE

The `PLATFORM_MERGED_MEMORY_INTERFACE` macro changes how many AXI master ports are exposed from the AFU:

| Mode | AXI ports out | Description |
|------|--------------|-------------|
| Not defined | `NUM_DMA_CHANNELS` (8) | Multiple AXI ports, one per bank. Each port connects to one HMSS slave port. |
| Defined | 1 | Single AXI port. The HMSS internally routes to PCs based on address. |

When merged interface is enabled:
- `vortex_afu.v` exposes only 1 AXI master port instead of 8
- `VX_afu_wrap.sv` instantiates the adapter with `NUM_BANKS=1`
- The HMSS does all the PC routing internally based on the contiguous address
- Internal Vortex logic still uses `VX_axi_adapter` with the interleave remap, but outputs to a single port

When merged interface is **not** enabled:
- 8 AXI master ports are exposed
- Each port maps to a specific HMSS slave port / PC range
- The address remap in `VX_axi_adapter` ensures each port sends addresses within its PC's contiguous range

## XRT Runtime: BANK_INTERLEAVE

The XRT runtime (`runtime/xrt/vortex.cpp`) has a compile-time `#define BANK_INTERLEAVE` that controls how host-side buffer allocation and data transfer work. By default it is **commented out** (OFF). The runtime mode must match the hardware configuration:
- `BANK_INTERLEAVE` ↔ `PLATFORM_MEMORY_INTERLEAVE=1`
- Non-interleave ↔ `PLATFORM_MEMORY_INTERLEAVE=0`

### Comparison

|  | BANK_INTERLEAVE ON | BANK_INTERLEAVE OFF |
|---|---|---|
| BO allocation | All banks pre-allocated at init | Lazy per-bank on first `mem_alloc` |
| BO storage | `vector<xrt_buffer_t>` (index = bank_id) | `unordered_map<uint32_t, {BO, refcount}>` |
| addr → bank | `(addr / 64) % N` (cache-line round-robin) | `addr / bank_size` (contiguous) |
| Transfer unit | Cache line (64B) per iteration | Remaining bank headroom (bulk) |
| `mem_free` | Clear all BOs when `allocated() == 0` | Decrement refcount, free BO when 0 |

### BANK_INTERLEAVE ON

**BO allocation:** At device init, one XRT buffer object (BO) is allocated **per bank** upfront:
```cpp
// init time — allocate all banks
for (uint32_t i = 0; i < num_banks; ++i) {
    xrtBuffers_.emplace_back(xrtDevice_, bank_size, xrt::bo::flags::normal, i);
}
```
`mem_alloc` does not create new BOs — they already exist.

**Address → bank mapping (`get_bank_info`):**
```cpp
block_addr = addr / CACHE_BLOCK_SIZE;              // cache-line index
index      = block_addr & (num_banks - 1);         // lower bits → bank
offset     = (block_addr >> lg2_num_banks) * CACHE_BLOCK_SIZE;  // bank-local offset
```
Consecutive cache lines cycle through banks: line 0 → bank 0, line 1 → bank 1, ..., line N → bank 0.

**Upload/download:** Transfers one cache line (64B) per iteration, striping across banks:
```cpp
xfer_size = min(remaining, CACHE_BLOCK_SIZE);  // always ≤ 64B
// each iteration: get_bank_info → picks next bank → write 64B to that bank's BO
```

**`mem_free`:** BOs are freed only when all memory is released (`allocated() == 0`).

### BANK_INTERLEAVE OFF (default)

**BO allocation:** No BOs at init. On `mem_alloc`, the runtime looks up which bank the address falls into, and lazily allocates a BO for that bank if one doesn't exist yet. A refcount tracks how many allocations reference each bank:
```cpp
// on mem_alloc
bank_id = addr >> lg2_bank_size;
if (xrtBuffers_.find(bank_id) == end) {
    xrtBuffers_[bank_id] = { xrtBOAlloc(..., bank_id), count: 1 };
} else {
    xrtBuffers_[bank_id].count++;
}
```

**Address → bank mapping (`get_bank_info`):**
```cpp
index  = addr >> lg2_bank_size;         // upper bits → bank
offset = addr & (bank_size - 1);        // lower bits → offset within bank
```
Address space is split into contiguous per-bank regions: [0, bank_size) → bank 0, [bank_size, 2*bank_size) → bank 1, ...

**Upload/download:** Transfers as much as possible within the current bank in one shot:
```cpp
bank_headroom = bank_size - bo_offset;
xfer_size = min(remaining, bank_headroom);  // could be megabytes
```
If a transfer crosses a bank boundary, the next iteration picks up in the next bank's BO.

**`mem_free`:** Decrements the bank's refcount. When refcount reaches 0, the BO is freed immediately.

## Summary: End-to-End Flow

```
Host (XRT runtime)
  BANK_INTERLEAVE: stripes data across BOs in cache-line chunks
      |
      v
HBM (contiguous address space, managed by HMSS)
  PC 0: [0, 512MB), PC 1: [512MB, 1GB), ...
      |
      v
vortex_afu.v
  MERGED_MEMORY_INTERFACE → 1 AXI port (HMSS routes internally)
  otherwise              → 8 AXI ports (one per PC group)
      |
      v
VX_axi_adapter (INTERLEAVE=1)
  LSU request addr (interleaved view)
  → extract bank_sel from lower bits
  → remap to contiguous addr for AXI output
  → HMSS routes to correct PC
      |
      v
Vortex core (LSU / DMA)
  Software sees interleaved address space
  Consecutive 64B blocks cycle through banks
```

## Key Configuration Parameters

| Parameter | Default | Location | Description |
|-----------|---------|----------|-------------|
| `PLATFORM_MEMORY_INTERLEAVE` | 1 | `VX_config.vh:187` | Enable interleaved address view in HW |
| `PLATFORM_MEMORY_NUM_BANKS` | 32 | `VX_config.vh` (build override) | Number of HBM banks (PCs) |
| `PLATFORM_MEMORY_DATA_SIZE` | 64 | `VX_config.vh:183` | Bytes per AXI data beat |
| `PLATFORM_MERGED_MEMORY_INTERFACE` | (build flag) | `VX_config.vh` | VX_axi_adapter outputs single port |
| `NUM_DMA_CHANNELS` | 8 | `VX_config.vh` | AXI master ports from Vortex |
| `BANK_INTERLEAVE` | ON | `runtime/xrt/vortex.cpp:50` | XRT runtime interleave mode |

## HBM Banks vs AXI Ports

These are two distinct concepts that must not be conflated:

| Concept | Parameter | Typical Value | Meaning |
|---------|-----------|---------------|---------|
| HBM banks (PCs) | `PLATFORM_MEMORY_NUM_BANKS` | 32 | Physical memory banks. Interleaving granularity. |
| AXI ports | `NUM_DMA_CHANNELS` | 8 | Number of AXI master ports from Vortex HW. |

8 AXI ports are **physical channels** that access 32 HBM banks. One port can serve multiple banks via address routing. The mapping is:

- **Runtime** sees 32 banks (from `dev_caps`): interleaves data across 32 banks in 64B chunks
- **VX_axi_adapter** remaps addresses, outputs to AXI ports
- **axi_demux** routes to 8 ports based on address bits
- **HMSS** (or sim) further routes each port to the correct PC based on address

Where each value is used:

| Item | Use `PLATFORM_MEMORY_NUM_BANKS` | Use `NUM_DMA_CHANNELS` |
|------|:---:|:---:|
| `VX_afu_ctrl.sv` dev_caps num_banks | **yes** | |
| `VX_afu_ctrl.sv` bank_addr_width | **yes** | |
| `xrt_sim_vcs.cpp` mem_bank_size_, mem_alloc_[], to_software_addr() | **yes** | |
| `Vortex_axi.sv` NUM_HBM_PORTS | | **yes** |
| `VX_afu_wrap.sv` C_M_AXI_MEM_NUM_BANKS | | **yes** |
| `vortex_afu.v` external port count | | **yes** |
| `xrt_sim_vcs.cpp` pending_mem_reqs_[], dram_queues_[], aw_state_[] | | **yes** |

## PLATFORM_MERGED_MEMORY_INTERFACE Scope

`PLATFORM_MERGED_MEMORY_INTERFACE` affects **only** `VX_axi_adapter`'s `NUM_BANKS_OUT` parameter (set to 1). Everything downstream is unaffected:

```
VX_axi_adapter(NUM_BANKS_OUT=1)  ← MERGED effect stops here
  → axi_demux(1→8, address-based) ← always 8 outputs
  → per-port axi_mux(LSU+DMA)     ← always 8
  → Vortex_axi: 8 ports            ← always NUM_DMA_CHANNELS
  → VX_afu_wrap: 8 ports           ← always NUM_DMA_CHANNELS
  → vortex_afu: 8 ports            ← always NUM_DMA_CHANNELS
```

Without merged interface, `VX_axi_adapter` can output multiple ports directly (NUM_BANKS_OUT=8), making the downstream demux a passthrough.

## Sim Backend Address Invariant

**AXI address from RTL == original software address.** This holds for both merged and non-merged modes.

VX_axi_adapter (INTERLEAVE=1) output formula:
```
m_axi_addr[i] = (bank_addr << (lg2N + lg2_DATA_SIZE)) | (i << lg2_DATA_SIZE)
```
Since port `i` only receives requests where `bank_sel == i`, expanding gives:
```
m_axi_addr[bank_sel] = software_addr   (always identical)
```

Therefore in the sim backend (`xrt_sim_vcs.cpp`):
- `process_axi_events`: use `pkt.addr` directly as flat RAM index — **no conversion needed**
- `mem_write(bank, offset)`: reconstruct flat software addr, then write to RAM:
  ```cpp
  flat_addr = (offset / CACHE_BLOCK_SIZE * PLATFORM_MEMORY_NUM_BANKS + bank) * CACHE_BLOCK_SIZE
  ```

Note: with `BANK_INTERLEAVE OFF`, `bank * bank_size + offset == addr` holds as a mathematical identity, so the old code appeared to work. This is a coincidence, not correct design — it breaks immediately when `BANK_INTERLEAVE` is enabled.
