# GEMM LMEM, ACC, and TMEM SRAM Area Comparison

## 1. Purpose

This document compares the SRAM macro area of monolithic LMEM organizations
against designs that split the same logical capacity across LMEM, accumulator
memory (ACC), and tensor memory (TMEM).

The analysis is based on:

- Samsung 28LPP generated SRAM Liberty and LEF data.
- The Synopsys DC area reports for the following configurations:
  - `Vortex_axi_naive_gemm_th32_tcol32_hwexp_dcache`
  - `Vortex_axi_improve_th32_tcol32_hwexp_dcache`
- `MXU_COL=32` and four ACC banks.
- Eight TMEM banks in the improve design.

All area values in the capacity-comparison sections are raw SRAM macro areas.
They do not include address/control logic, clock trees, placement halos, routing
channels, or congestion-driven whitespace.

## 2. Source Reports and Configurations

The source configurations are:

- [`configs/naive_gemm_th32_tcol32_hwexp_dcache.sh`](../../configs/naive_gemm_th32_tcol32_hwexp_dcache.sh)
  - `LMEM_LOG_SIZE=20`: 1 MiB LMEM
  - `GEMM_ACC_MEM_DEPTH=512`: 256 KiB logical ACC
- [`configs/improve_th32_tcol32_hwexp_dcache.sh`](../../configs/improve_th32_tcol32_hwexp_dcache.sh)
  - `LMEM_LOG_SIZE=19`: 512 KiB LMEM
  - `TMEM_BANK_SIZE=32768`: 256 KiB total TMEM with eight banks
  - `GEMM_ACC_MEM_DEPTH=512`: 256 KiB logical ACC

The corresponding area reports are generated under:

```text
build/hw/syn/synopsys/top_analysis/
  Vortex_axi_naive_gemm_th32_tcol32_hwexp_dcache/
  Vortex_axi_improve_th32_tcol32_hwexp_dcache/
```

The reports use logical-library macro area. The LEF dimensions independently
produce the same macro areas used below.

## 3. Available SRAM Macro Shapes

The relevant generated macro inventory under
`/home/data/memory_compiler/28LPP/genSEC` is:

| Type | Shape | Capacity | LEF dimensions (um) | Area (um^2) |
|---|---:|---:|---:|---:|
| HD | `8192x64m16` | 512 Kbit | `666.292 x 154.652` | 103,043.390384 |
| HD | `4096x64m16` | 256 Kbit | `666.292 x 88.666` | 59,077.446472 |
| HD | `2048x64m16` | 128 Kbit | `666.292 x 55.818` | 37,191.086856 |
| HD | `1024x64m8` | 64 Kbit | `333.262 x 49.266` | 16,418.485692 |
| HS | `512x128m8` | 64 Kbit | `826.824 x 43.794` | 36,209.930256 |

There is no generated `512x128` HD macro in the current inventory. There is
also no generated `1024x128` HD macro, but two `1024x64` HD macros can provide
the same 128-bit width.

## 4. HD Versus HS at Logical Depth 512

A logical `512x128` array can be implemented in either of the following ways:

| Implementation | Instantiated capacity | Macro count | Area (um^2) |
|---|---:|---:|---:|
| One `512x128` HS | 64 Kbit | 1 | 36,209.930256 |
| Two `1024x64` HD, upper half unused | 128 Kbit | 2 | 32,836.971384 |

Although the HD implementation instantiates twice the required bit capacity,
it is still 3,372.958872 um^2, or 9.315%, smaller than the HS implementation.

The trade-offs are:

- The HD implementation doubles the macro count.
- Half of the physical storage is unreachable or intentionally unused.
- The additional macro pins increase address, control, and clock fanout.
- HD access time must be checked against the target clock.
- Placement and routing overhead can reduce the 9.315% raw-area advantage.

## 5. Why ACC Is a Register Array in the Existing Reports

For `MXU_COL=32` and `GEMM_ACC_MEM_DEPTH=512`, each of the four ACC banks has
the following logical shape:

```text
DATAW = MXU_COL * FP32_WIDTH = 32 * 32 = 1024 bits
SIZE  = GEMM_ACC_MEM_DEPTH   = 512 entries

ACC total = 4 * 512 * 1024 bits = 256 KiB
```

[`hw/rtl/core/gemm/VX_gemm_unit.sv`](../../hw/rtl/core/gemm/VX_gemm_unit.sv)
instantiates four `VX_sp_ram` blocks with these parameters.

The report hierarchy contains `g_compiled/u_compiled`, but this hierarchy name
only indicates that the compiled-SRAM wrapper was selected. The `512x1024,
WRENW=1` shape did not match a registered macro binding in the analyzed build,
so [`hw/rtl/libs/VX_sp_ram_compiled.sv`](../../hw/rtl/libs/VX_sp_ram_compiled.sv)
used its `g_unsupported` synchronous register-array fallback:

```systemverilog
reg [DATAW-1:0] ram [0:SIZE-1];
```

This is visible in the mapped hierarchy as `g_unsupported_ram_reg_*` cells.
It is also consistent with the macro counts:

- Naive: 32 macros, all belonging to LMEM.
- Improve: 64 macros, belonging to LMEM and TMEM.
- Neither report contains ACC SRAM macros.

The mapped ACC areas are therefore standard-cell areas, not SRAM macro areas:

| Design | Mapped ACC area (um^2) | Implementation in report |
|---|---:|---|
| Naive | 1,391,667.1269 | Register array and associated logic |
| Improve | 1,388,007.9519 | Register array and associated logic |

The RTL has since added a `SIZE=512`, `DATAW=1024`, `WRENW=1` compiled-SRAM
binding. New synthesis runs map each logical ACC bank to eight
`cmos28lpp_ra1w_hs_512x128m8` macros, for 32 ACC macros in the complete design.
The values above remain useful as a description of the two archived reports,
which predate that binding.

## 6. Existing 1 MiB LMEM Versus 512+256+256 KiB Split

### 6.1 Existing report macro areas

The macros present in the reports are:

| Storage | Implementation | Macro count | Macro area (mm^2) |
|---|---|---:|---:|
| Naive LMEM 1 MiB | 32 x `4096x64` HD | 32 | 1.890478 |
| Improve LMEM 512 KiB | 32 x `2048x64` HD | 32 | 1.190115 |
| Improve TMEM 256 KiB | 32 x `512x128` HS | 32 | 1.158718 |

ACC is excluded from this table because the existing report implements it with
standard cells.

### 6.2 Split configuration with HS ACC and TMEM

If ACC is converted to `512x128` HS macros, the logical 1 MiB split requires:

| Storage | Logical capacity | Macro area (mm^2) |
|---|---:|---:|
| LMEM HD | 512 KiB | 1.190115 |
| ACC HS | 256 KiB | 1.158718 |
| TMEM HS | 256 KiB | 1.158718 |
| Total | 1 MiB | 3.507550 |

Compared with a 1 MiB monolithic HD LMEM at 1.890478 mm^2, the split is
1.855x, or 85.538%, larger in raw macro area.

### 6.3 Split configuration using oversized depth-1024 HD macros

ACC and TMEM can instead use `1024x64` HD macros and leave half the depth
unused. Each logical 256 KiB memory then instantiates 512 KiB of physical SRAM:

| Storage | Logical capacity | Physical macro capacity | Macro area (mm^2) |
|---|---:|---:|---:|
| LMEM HD | 512 KiB | 512 KiB | 1.190115 |
| ACC HD | 256 KiB | 512 KiB | 1.050783 |
| TMEM HD | 256 KiB | 512 KiB | 1.050783 |
| Total | 1 MiB | 1.5 MiB | 3.291681 |

This all-HD split is 1.741x, or 74.119%, larger than a monolithic 1 MiB HD
LMEM. It saves 0.215869 mm^2 relative to the HS ACC/TMEM split, but it doubles
the ACC and TMEM macro counts and wastes 512 KiB of physical capacity.

## 7. LMEM 2 MiB Versus 1+0.5+0.5 MiB Split, All HD

At doubled logical capacity, depth 1024 is fully used by ACC and TMEM, so the
split configuration does not waste SRAM depth.

### 7.1 Monolithic LMEM 2 MiB

With 32 LMEM banks:

```text
32 * (8192 entries * 64 bits) = 2 MiB
```

| Storage | Macro shape | Macro count | Area (mm^2) |
|---|---|---:|---:|
| LMEM 2 MiB | `8192x64` HD | 32 | 3.297388 |

### 7.2 Split LMEM 1 MiB + ACC 512 KiB + TMEM 512 KiB

The all-HD split uses:

- LMEM: 32 banks, each `4096x64`.
- ACC: four logical `1024x1024` banks, each width-tiled with sixteen
  `1024x64` macros.
- TMEM: eight logical `1024x512` banks, each width-tiled with eight
  `1024x64` macros.

| Storage | Logical shape | Physical macro shape | Macro count | Area (mm^2) |
|---|---|---|---:|---:|
| LMEM 1 MiB | 32 x `4096x64` | `4096x64` HD | 32 | 1.890478 |
| ACC 512 KiB | 4 x `1024x1024` | `1024x64` HD | 64 | 1.050783 |
| TMEM 512 KiB | 8 x `1024x512` | `1024x64` HD | 64 | 1.050783 |
| Total | 2 MiB | | 160 | 3.992044 |

The comparison is:

| Organization | Total logical capacity | Macro count | Macro area (mm^2) |
|---|---:|---:|---:|
| Monolithic LMEM | 2 MiB | 32 | 3.297388 |
| LMEM + ACC + TMEM split | 2 MiB | 160 | 3.992044 |
| Split minus monolithic | 0 | +128 | +0.694656 |

The all-HD split is 1.211x, or 21.067%, larger in raw SRAM macro area.

## 8. Summary

| Comparison | Monolithic area | Split area | Split overhead |
|---|---:|---:|---:|
| 1 MiB LMEM HD vs. 512+256+256 KiB, ACC/TMEM HS | 1.890478 mm^2 | 3.507550 mm^2 | +85.538% |
| 1 MiB LMEM HD vs. 512+256+256 KiB, oversized ACC/TMEM HD | 1.890478 mm^2 | 3.291681 mm^2 | +74.119% |
| 2 MiB LMEM HD vs. 1+0.5+0.5 MiB, all HD | 3.297388 mm^2 | 3.992044 mm^2 | +21.067% |

The main conclusions are:

1. HD macros are substantially more bit-area-efficient than the available
   depth-512 HS macro.
2. Using depth-1024 HD macros for logical depth 512 remains 9.315% smaller than
   using depth-512 HS macros, even though half the HD capacity is unused.
3. The benefit of monolithic LMEM decreases as the LMEM macro becomes deeper:
   the all-HD split penalty is 74.119% at the 1 MiB comparison point but
   21.067% at the 2 MiB comparison point.
4. The split organization has many more macros. Its post-placement area penalty
   can therefore exceed the raw macro-area difference.
5. Timing, power, macro placement, and routing must be verified before choosing
   oversized HD macros over HS macros.

## 9. Interpretation Caveat

The capacity tables above compare a conceptual monolithic LMEM pool with a
conceptual LMEM/ACC/TMEM split. The current naive GEMM RTL also instantiates a
separate ACC memory. A full top-level architecture comparison must either:

- include the naive ACC implementation in the baseline, or
- explicitly remove the naive ACC and use LMEM as the accumulator storage.

Otherwise, a statement such as "LMEM 1 MiB versus LMEM 512 KiB + ACC 256 KiB +
TMEM 256 KiB" does not describe the complete storage instantiated by the two
existing top-level reports.
