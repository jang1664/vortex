# LMEM-Only Versus LMEM/ACC/TMEM SRAM Area Scaling

## 1. Purpose

This document compares the raw SRAM macro area of a monolithic LMEM against a
partitioned memory organization with the same total logical capacity:

```text
LMEM-only capacity X
versus
LMEM X/2 + ACC X/4 + TMEM X/4
```

The comparison covers total logical capacities of 1, 2, 4, and 8 MiB. All
storage is implemented with Samsung 28LPP SRAM macros; register-array area is
not included.

This analysis extends
[`gemm_sram_area_comparison.md`](gemm_sram_area_comparison.md) with a capacity
scaling study.

## 2. Assumptions

### 2.1 Banking

- LMEM has 32 banks with a 64-bit data width per bank.
- ACC has four banks with a 1024-bit data width per bank.
- TMEM has eight banks with a 512-bit data width per bank.
- The total logical capacity is identical between each LMEM-only point and its
  partitioned counterpart.

### 2.2 Macro-selection policy

LMEM uses HD macros. ACC and TMEM also use HD macros whenever their logical
depth is 512 or greater.

| Logical depth | ACC/TMEM physical macro | Treatment |
|---:|---|---|
| 512 | `1024x64m8` HD | Use only the lower 512 entries; discard half the depth |
| 1024 | `1024x64m8` HD | Use the complete macro depth |
| 2048 | `2048x64m16` HD | Use the complete macro depth |
| 4096 | `4096x64m16` HD | Use the complete macro depth |

The generated 28LPP inventory does not contain a `512x128` HD macro or a
`1024x128` HD macro. ACC and TMEM therefore tile 64-bit HD macros across the
required data width.

### 2.3 Raw macro area only

The calculation includes only Liberty/LEF macro area. It excludes:

- Address decode and depth-stack output muxes.
- Clock, chip-enable, and write-enable distribution.
- Macro placement halos and routing channels.
- Congestion-driven whitespace.
- ACC/TMEM controller and interconnect logic.

Consequently, the partitioned design's final placed area can have a larger
overhead than the raw-macro results reported here.

## 3. SRAM Macro Areas

The calculation uses the following generated macro areas:

| Macro | Capacity | Area (um^2) |
|---|---:|---:|
| `cmos28lpp_ra1w_hd_1024x64m8` | 64 Kbit | 16,418.485692 |
| `cmos28lpp_ra1w_hd_2048x64m16` | 128 Kbit | 37,191.086856 |
| `cmos28lpp_ra1w_hd_4096x64m16` | 256 Kbit | 59,077.446472 |
| `cmos28lpp_ra1w_hd_8192x64m16` | 512 Kbit | 103,043.390384 |

No HD macro deeper than `8192x64` is used. Larger LMEM banks are constructed by
depth-stacking multiple `8192x64` macros.

## 4. Capacity and Shape Mapping

| Total logical capacity | LMEM-only | Partitioned LMEM | ACC | TMEM |
|---:|---:|---:|---:|---:|
| 1 MiB | 1 MiB | 512 KiB | 256 KiB | 256 KiB |
| 2 MiB | 2 MiB | 1 MiB | 512 KiB | 512 KiB |
| 4 MiB | 4 MiB | 2 MiB | 1 MiB | 1 MiB |
| 8 MiB | 8 MiB | 4 MiB | 2 MiB | 2 MiB |

The corresponding per-bank logical depths are:

| Total logical capacity | LMEM-only depth | Partitioned LMEM depth | ACC depth | TMEM depth |
|---:|---:|---:|---:|---:|
| 1 MiB | 4096 | 2048 | 512 | 512 |
| 2 MiB | 8192 | 4096 | 1024 | 1024 |
| 4 MiB | 16384 | 8192 | 2048 | 2048 |
| 8 MiB | 32768 | 16384 | 4096 | 4096 |

At the 1 MiB point, each ACC/TMEM logical depth-512 slice uses a depth-1024 HD
macro. The physical SRAM capacity of ACC and TMEM is therefore twice their
logical capacity at this point.

## 5. Raw Macro-Area Results

### 5.1 Partitioned component areas

| Total logical capacity | Partitioned LMEM HD | ACC HD | TMEM HD | Partitioned total |
|---:|---:|---:|---:|---:|
| 1 MiB | 1.190115 mm^2 | 1.050783 mm^2 | 1.050783 mm^2 | **3.291681 mm^2** |
| 2 MiB | 1.890478 mm^2 | 1.050783 mm^2 | 1.050783 mm^2 | **3.992044 mm^2** |
| 4 MiB | 3.297388 mm^2 | 2.380230 mm^2 | 2.380230 mm^2 | **8.057848 mm^2** |
| 8 MiB | 6.594777 mm^2 | 3.780957 mm^2 | 3.780957 mm^2 | **14.156690 mm^2** |

### 5.2 LMEM-only versus partitioned

The overhead is defined as:

```text
partition overhead = (partitioned area / LMEM-only area - 1) * 100
```

| Total logical capacity | LMEM-only area | Partitioned area | Area increase | Partition overhead |
|---:|---:|---:|---:|---:|
| 1 MiB | 1.890478 mm^2 | 3.291681 mm^2 | +1.401203 mm^2 | **+74.119%** |
| 2 MiB | 3.297388 mm^2 | 3.992044 mm^2 | +0.694656 mm^2 | **+21.067%** |
| 4 MiB | 6.594777 mm^2 | 8.057848 mm^2 | +1.463071 mm^2 | **+22.185%** |
| 8 MiB | 13.189554 mm^2 | 14.156690 mm^2 | +0.967136 mm^2 | **+7.333%** |

### 5.3 Hypothetical exact-depth-512 HD macro

The current inventory does not contain a depth-512 HD macro. The 1 MiB point
therefore uses depth-1024 HD macros for the logical depth-512 ACC and TMEM
arrays, wasting half of their physical capacity.

To estimate the result if a suitable depth-512 HD macro existed, this analysis
uses the following model:

1. Fit the LEF height growth of the valid `2048x64m16`, `4096x64m16`, and
   `8192x64m16` HD family against the number of physical rows.
2. Use the resulting row-height slope, approximately 0.257434 um per row.
3. Anchor the fixed/peripheral component to the actual `1024x64m8` LEF size,
   `333.262 x 49.266 um`.
4. Reduce the physical row count from 128 rows at depth 1024 to 64 rows at
   depth 512.

This gives the following central estimate:

```text
estimated 512x64m8 HD height
  = 49.266 - 64 * 0.257434
  = 32.790 um

estimated 512x64m8 HD area
  = 333.262 * 32.790
  = 10,927.7 um^2
```

A logical `512x128` slice would use two of these estimated `512x64` macros, or
approximately 21,855.5 um^2. This is an extrapolation, not compiler output; a
native generated macro can differ because of array folding, mux choice,
redundancy, power routing, and compiler layout constraints.

Using this estimate, the hypothetical 1 MiB partition is:

| Storage | Logical capacity | Estimated macro count | Estimated area |
|---|---:|---:|---:|
| LMEM HD | 512 KiB | 32 | 1.190115 mm^2 |
| ACC exact-depth HD | 256 KiB | 64 | 0.699375 mm^2 |
| TMEM exact-depth HD | 256 KiB | 64 | 0.699375 mm^2 |
| Partitioned total | 1 MiB | 160 | **2.588865 mm^2** |

Compared with the 1 MiB LMEM-only area of 1.890478 mm^2, the estimated
partition overhead is:

```text
(2.588865 / 1.890478 - 1) * 100 = 36.942%
```

The exact-depth macro would reduce the partitioned area by approximately
0.702816 mm^2 relative to the current oversized-depth estimate. The 1 MiB
overhead would fall from 74.119% to approximately 36.942%, a reduction of
37.177 percentage points.

Because only one valid m8 data point is available, a +/-10% uncertainty on the
estimated depth-512 macro area is appropriate for early planning:

| Estimate case | Partitioned area | Overhead versus LMEM-only |
|---|---:|---:|
| Estimated macro area -10% | 2.448990 mm^2 | 29.543% |
| Central estimate | 2.588865 mm^2 | **36.942%** |
| Estimated macro area +10% | 2.728740 mm^2 | 44.341% |

Therefore, a reasonable planning statement is that an exact-depth-512 HD
macro would likely reduce the 1 MiB partition overhead from 74.119% to roughly
37%, with an indicative range of approximately 30-44% until an actual macro is
generated.

## 6. Macro Counts

| Total logical capacity | LMEM-only macro count | Partitioned LMEM | ACC | TMEM | Partitioned total |
|---:|---:|---:|---:|---:|---:|
| 1 MiB | 32 | 32 | 64 | 64 | **160** |
| 2 MiB | 32 | 32 | 64 | 64 | **160** |
| 4 MiB | 64 | 32 | 64 | 64 | **160** |
| 8 MiB | 128 | 64 | 64 | 64 | **192** |

The partitioned organization has substantially more macros than LMEM-only,
even when its raw macro-area overhead is small. This can increase clock/control
fanout, floorplan fragmentation, and routing overhead.

## 7. Interpretation

### 7.1 The 1 MiB point

The 1 MiB partition has the largest overhead, 74.119%. ACC and TMEM each have a
logical depth of 512, but the selected HD macro has a depth of 1024. The design
therefore instantiates:

```text
logical capacity:  LMEM 512 KiB + ACC 256 KiB + TMEM 256 KiB = 1 MiB
physical capacity: LMEM 512 KiB + ACC 512 KiB + TMEM 512 KiB = 1.5 MiB
```

The discarded depth and the much larger macro count dominate this point.

### 7.2 The 2 MiB and 4 MiB points

ACC and TMEM use their complete macro depth at these points. The partition
overhead is approximately 21-22%. The 4 MiB overhead is slightly higher than
the 2 MiB overhead because the generated `2048x64` HD macro is less
bit-area-efficient than the deeper `8192x64` HD macro used by the LMEM-only
baseline.

### 7.3 The 8 MiB point

The raw macro-area overhead falls to 7.333%. Deeper ACC/TMEM macros become more
area-efficient, and the LMEM-only baseline requires four-way depth stacking per
bank. The partitioned design still uses 192 macros, however, so the post-route
overhead may be materially higher than 7.333%.

## 8. Summary

| Total capacity | Partition overhead | Main cause |
|---:|---:|---|
| 1 MiB | **74.119%** | Depth-1024 HD macros are half unused for ACC/TMEM |
| 1 MiB, hypothetical exact-depth HD | **approximately 36.942%** | Estimated depth-512 HD macros eliminate discarded capacity |
| 2 MiB | **21.067%** | Width tiling and higher macro count |
| 4 MiB | **22.185%** | Width tiling plus macro bit-area efficiency differences |
| 8 MiB | **7.333%** | Deeper macros improve raw area efficiency |

The partitioned LMEM/ACC/TMEM organization becomes more area-competitive as
capacity increases. The raw macro-area penalty falls from 74.119% at 1 MiB to
7.333% at 8 MiB. Final architecture selection must also account for the
partitioned design's bandwidth benefit, controller area, macro placement,
routing congestion, timing, and power.

If an exact-depth-512 HD macro becomes available, the estimated 1 MiB overhead
is approximately 36.942% rather than 74.119%. This estimate must not be treated
as characterized macro data until the memory compiler produces Liberty and LEF
views for the target shape.

## 9. Implementation Status

`VX_sp_ram` now has an `SRAM_TYPE` parameter whose default is `"HS"`. The
28LPP compiled-SRAM dispatcher implements both `"HS"` and `"HD"` for every
registered single-port shape. Therefore the all-HD results above remain a
selectable planning alternative, while all existing call sites use HS unless
they explicitly override the parameter.

The implemented wide-memory mapping is:

- TMEM: four RA1-HS x128 width tiles for each 512-bit logical bank.
- ACC: eight RA1-HS x128 width tiles for each 1024-bit logical bank.
- LMEM: one native RA1-HS x64 macro for each 64-bit logical bank.
- ICACHE: four RF1-HS x128 width tiles for each 512-bit logical bank.

The default-HS top configuration also contains smaller 512-bit arrays. A
logical `128x512` full-write array and a logical `32x512` byte-write array are
each implemented with four `256x128` RA1-HS tiles. Their addresses are
zero-extended into the physical depth-256 macros. The corresponding HD mode
uses eight `1024x64` tiles with zero-extended addresses.

Native RA1-HS x512 and x1024 macros are not legal in the installed compiler;
the maximum supported width is 144 bits for the selected m4/m8 organizations.
The x128 tiling is therefore required rather than an optional decomposition.

## 10. Implemented All-HS Comparison

### 10.1 Generated macro dimensions

The x64 RA1-HS and RF1-HS macros were generated with the Samsung LN28LPP
hwexplorer memory-compiler flow. The synthesis slow corner is
`ss_0p900v_0p900v_125c`; the corresponding fast corner is
`ff_1p100v_1p100v_m40c`. Raw area below is taken directly from each LEF `SIZE`
statement.

| Macro | LEF size (um) | Area (um^2) |
|---|---:|---:|
| `cmos28lpp_ra1w_hs_512x64m8` | 413.552 x 43.794 | 18,111.096288 |
| `cmos28lpp_ra1w_hs_1024x64m8` | 413.552 x 60.682 | 25,095.162464 |
| `cmos28lpp_ra1w_hs_2048x64m8` | 413.552 x 107.562 | 44,482.480224 |
| `cmos28lpp_ra1w_hs_4096x64m8` | 413.552 x 201.196 | 83,205.008192 |
| `cmos28lpp_ra1w_hs_8192x64m16` | 826.824 x 201.196 | 166,353.681504 |
| `cmos28lpp_rf1_hs_64x128m2` | 214.034 x 21.545 | 4,611.362530 |
| Existing `cmos28lpp_ra1w_hs_512x128m8` | 826.824 x 43.794 | 36,209.930256 |
| Existing `cmos28lpp_ra1w_hs_1024x128m8` | 826.824 x 60.682 | 50,173.333968 |

### 10.2 Equal-capacity LMEM versus LMEM/ACC/TMEM

For 1 MiB total logical storage:

```text
LMEM-only
  = 32 * area(4096x64 HS)
  = 2.662560 mm^2

LMEM 512 KiB + ACC 256 KiB + TMEM 256 KiB
  = 32 * area(2048x64 HS) + 64 * area(512x128 HS)
  = 3.740875 mm^2
```

For 2 MiB total logical storage:

```text
LMEM-only
  = 32 * area(8192x64 HS)
  = 5.323318 mm^2

LMEM 1 MiB + ACC 512 KiB + TMEM 512 KiB
  = 32 * area(4096x64 HS) + 64 * area(1024x128 HS)
  = 5.873654 mm^2
```

| Total logical capacity | LMEM-only HS | Partitioned all-HS | Area increase | Overhead |
|---:|---:|---:|---:|---:|
| 1 MiB | 2.662560 mm^2 | 3.740875 mm^2 | +1.078315 mm^2 | **+40.499%** |
| 2 MiB | 5.323318 mm^2 | 5.873654 mm^2 | +0.550336 mm^2 | **+10.338%** |

These are raw macro areas. They exclude control logic, macro halos, routing
channels, and congestion. The partitioned design has 96 macros at both points
(32 LMEM macros plus 64 ACC/TMEM x128 tiles), versus 32 macros for LMEM-only,
so its placed-and-routed overhead can exceed the LEF-only result.

### 10.3 Top elaboration/link validation

The `improve_th32_tcol32_hwexp_dcache` top was elaborated with the default
`SRAM_TYPE="HS"` setting and all 30 compiled-SRAM DBs loaded. The resulting
hierarchy selected HS mappings for LMEM (`2048x64`), ACC (`512x1024`), TMEM
(`512x512`), and the smaller cache arrays (`128x512` and `32x512`). The final
link report contains no unresolved references, and the elaborated DDC was
written successfully. Full `compile_ultra` was intentionally stopped after
this validation at the user's request; no mapped-area report is claimed for
this run.
