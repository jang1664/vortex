# SRAM / URAM / BRAM Reference — Alveo U55C (xcu55c-fsvh2892-2L-e)

Target device: Virtex UltraScale+ HBM (`xcu55c`). This document collects
**official AMD/Xilinx constraints** that govern when `VX_sp_ram` / `VX_dp_ram`
style inference can land on URAM vs BRAM vs distributed RAM on the U55C.

All citations are from AMD Technical Information Portal (docs.amd.com) and
the DS978 product data sheet.

---

## 1. Device resource budget (U55C)

| Resource   | Count / Size        | Notes                                  |
|------------|---------------------|----------------------------------------|
| LUTs       | 1,303,680           | CLB LUTs, SLR0+SLR1+SLR2               |
| FFs        | 2,607,360           |                                        |
| BRAM36     | 2,016 (≈ 70.9 Mb)   | Each RAMB36E2 = 36 Kb                  |
| URAM288    | **960** (≈ 270 Mb)  | Each URAM288 = 288 Kb, fixed 4K×72     |
| DSP48E2    | 9,024               |                                        |
| SLRs       | 3 (SSI device)      | HBM2 stacks on SLR0                    |
| HBM2       | 16 GB, 32 channels  |                                        |

Source: **DS978 Alveo U55C Data Sheet — Product Details**,
**UG1469 Alveo U55C User Guide**.

URAM288 blocks are distributed roughly uniformly across the three SLRs
(~320 per SLR). Cascade chains **cannot cross SLR boundaries**.

---

## 2. URAM288 primitive — hardware constraints

Source: **UG573 "UltraScale Architecture Memory Resources", Chapter 2 —
UltraRAM**.

### 2.1 Fixed geometry

- Each URAM288 block is **4096 deep × 72 bits wide** (288 Kb).
- Aspect ratio is **not configurable** — unlike BRAM (which supports
  32K×1, 16K×2, …, 512×72), URAM is always 4K×72.
- Narrower/shallower memories still consume a full URAM288 block → wasted
  capacity.

### 2.2 Port configuration

- **Dual port** (A and B). Each port can independently read or write every
  cycle.
- Both ports share the **same clock** (single-clock dual-port). There is
  no true asynchronous dual-clock URAM.
- Internally single-port: port A operates first, then port B, within one
  cycle. This yields a **write-before-read collision** for A→B on the same
  address in the same cycle (B sees port A's new data).

### 2.3 Byte-write enable

- **9-bit BWE bus per port** (`BWE_A`, `BWE_B`).
- `BWE_MODE = "PARITY_INDEPENDENT"`: 9 write-enable bits, one per 8-bit byte
  on the 72-bit word (8 data bytes + 1 parity byte column).
- `BWE_MODE = "PARITY_INTERLEAVED"`: only the lower 8 BWE bits are used;
  parity bits are written with the matching data byte.
- Granularity below 8 bits is **not supported**. No bit-write.

### 2.4 Read/write collision behavior

URAM **does not have** the BRAM-style `WRITE_MODE` attribute.
UG901 states explicitly:

> *"The write modes (read_first, write_first, no_change) do not exist in this
>  primitive."*

Read-during-write on the same port returns the **old data**
(read-first-like behavior), but this is a property of the primitive, not
something the designer configures.

### 2.5 Reset and initialization

- **No asynchronous reset.** Only the **output pipeline registers** can be
  reset, and only **to all zeros**.
- The memory array itself **powers up to zero** — there is no user-visible
  INIT mechanism (no `INIT_xx` attributes, no `$readmemh` / constant
  initializer from HDL). If you need non-zero boot contents, you must
  write them from logic at runtime.

### 2.6 Cascade

- Dedicated cascade routing allows multiple URAM288 blocks in the same
  **column** to form a deeper memory without fabric routing.
- Default cascade chain limit is **8 blocks** (override with
  `(* cascade_height = N *)`).
- Cascades **cannot cross SLR boundaries**. Max depth ≈ URAM column height
  within one SLR.
- Matrix cascade (column×row) is supported via `CASCADE_ORDER_A/B` and
  `CASCADE_*_A/B` attributes.

### 2.7 Other features

- Built-in SECDED **ECC** on both ports.
- Optional pipeline flip-flops on inputs, outputs, and cascade paths for
  timing closure.
- `SLEEP` input for dynamic power saving.

---

## 3. Vivado inference requirements

Source: **UG901 "Vivado Design Suite User Guide: Synthesis" — Inferring
UltraRAM in Vivado Synthesis, UltraRAM Coding Templates, Pipelining the
RAM**.

For Vivado to infer a `reg [W-1:0] mem [0:D-1]` array as URAM288, **all
of the following must be true**:

| # | Rule | Rationale |
|---|------|-----------|
| 1 | **`(* ram_style = "ultra" *)`** attribute on the signal (Verilog) / architecture (VHDL). | URAM is never inferred by default even if size crosses a threshold. |
| 2 | **Synchronous read** — the read must go through at least one pipeline register (`rdata_r <= mem[addr]`). **Combinational read is not legal.** | URAM is a synchronous-read primitive; async read forces LUTRAM. |
| 3 | **No `write_first` / `read_first` / `no_change`** modes. Do not use the BRAM idioms. | Not supported by URAM primitive. |
| 4 | **Synchronous reset only**, and the reset value must be **0** for any resettable register on the output path. | UG901: "The resets on the output registers can only be reset to 0." |
| 5 | **No async reset of the array** and **no non-zero initial content** (`initial` / constant-init on the array blocks URAM inference). | URAM cannot carry INIT data. |
| 6 | **Byte-enable** on writes is supported, but granularity is 8-bit (or 9-bit incl. parity). | Bit-granular write-enable → fall back to LUTRAM. |
| 7 | **Recommended**: **2+ pipeline stages** on the output for timing (OREG + additional fabric reg). | UG901 worked examples (8K×72, 16K×70) all use READ_LATENCY ≥ 2. |
| 8 | `CASCADE_HEIGHT` attribute if the inferred memory is deeper than 8×4096 = 32,768 entries in one chain. | Default chain limit = 8. |

Falling back mechanism: violating any rule → Vivado silently downgrades
to RAMB36 or LUTRAM, so check `report_utilization` after synthesis.

### 3.1 XPM memory primitives

The officially supported "black-box" way to get URAM is via the XPM
memory library (UG974):

- `XPM_MEMORY_SPRAM`, `XPM_MEMORY_SDPRAM`, `XPM_MEMORY_TDPRAM`
- Parameter `MEMORY_PRIMITIVE = "ultra"` → forces URAM.
- `READ_LATENCY_A` / `READ_LATENCY_B` **must be ≥ 2** when targeting URAM.
- Bypasses all the inference-pattern pitfalls above — useful as a fallback
  when inference is fragile.

---

## 4. When to prefer URAM over BRAM

Rules of thumb (derived from the fixed 4K×72 geometry):

| Memory shape              | Recommended primitive |
|---------------------------|-----------------------|
| ≤ 512 entries, ≤ 72 b wide | LUTRAM or BRAM        |
| 512–4096 entries, any width | BRAM (better fit)     |
| ≥ 4K entries, ≥ 64 b wide | **URAM**              |
| ≥ 32K entries (cascade)    | URAM (native cascade) |
| Needs INIT / non-zero reset | BRAM (URAM can't init) |
| Bit-granular BWE required  | BRAM or LUTRAM         |
| Needs WRITE_FIRST          | BRAM                   |
| Dual-clock true async      | BRAM                   |

A single URAM288 (288 Kb) equals roughly **8 RAMB36** in capacity, so
replacing one URAM with BRAM costs 8× more BRAM tiles and LUT-based
address/cascade logic.

---

## 5. Applying this to `VX_sp_ram` in Vortex

`hw/rtl/libs/VX_sp_ram.sv` already supports the URAM path
(`g_sync / g_uram`) under these conditions (see the `SELECT_URAM`
localparam):

- `OUT_REG = 1` (required — URAM needs synchronous read)
- `USE_URAM == 1`, **or** `USE_URAM == 0` and `FORCE_URAM(SIZE, DATAW)`
  returns true (auto size threshold)
- `RDW_MODE != "W"` — write-first is not URAM-compatible
- `WRENW == 1` — byte-enable disables the URAM branch in this library

Therefore, to migrate a `VX_sp_ram` instance to URAM on U55C, the caller
must choose **`OUT_REG=1`, `RDW_MODE="R"` or `"N"`, `WRENW=1`**, and size
the memory ≥ ~4K × 72 b so the URAM footprint isn't wasted.

For `VX_tensor_mem_bank` specifically:
- current shape is 64 entries × 512 bits (32 Kb total) → too shallow for URAM.
- write-first + 64-byte BWE → URAM ineligible anyway.
- → Target is BRAM via `OUT_REG=1` + `USE_BLOCK_BRAM` path, not URAM.

If a future design wants tensor memory on URAM, restructure the banks
to **≥ 4K entries deep** and replace byte-enable writes with
64-bit-wide whole-word writes (or use `XPM_MEMORY_*` with
`MEMORY_PRIMITIVE="ultra"`).

---

## 6. References

- **UG573** — *UltraScale Architecture Memory Resources* (Chapter 2: UltraRAM)
  - https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/UltraRAM-Summary
  - https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/UltraRAM-Key-Features
  - https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/Byte-Wide-Write-Enable-BWE_A-BWE_B
- **UG901** — *Vivado Design Suite User Guide: Synthesis*
  - https://docs.amd.com/r/en-US/ug901-vivado-synthesis/Inferring-UltraRAM-in-Vivado-Synthesis
  - https://docs.amd.com/r/en-US/ug901-vivado-synthesis/UltraRAM-Coding-Templates
  - https://docs.amd.com/r/en-US/ug901-vivado-synthesis/RAM-HDL-Coding-Guidelines
- **UG974** — *UltraScale Architecture Libraries Guide* (XPM_MEMORY_*)
- **DS978** — *Alveo U55C Data Sheet — Product Details*
  - https://docs.amd.com/r/en-US/ds978-u55c/Product-Details
- **UG1469** — *Alveo U55C Data Center Accelerator Card User Guide*
  - https://docs.amd.com/r/en-US/ug1469-alveo-u55c
