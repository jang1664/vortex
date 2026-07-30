# C1--C4 Area Comparison with a 2 MiB HD Memory Budget

## Summary

This report compares C1--C4 using high-density (HD) compiled SRAM and a
2 MiB total local-memory budget per design. It evaluates two naive GEMM
architectures and all four combinations of including or excluding memory macro
area and the common backbone.

All area values are provisional estimates in mm².

## Configuration

| Design | Naive with ACC | Naive without ACC |
|---|---:|---:|
| C1 | LMEM 2048 KiB | LMEM 2048 KiB |
| C2 | LMEM 1536 KiB + ACC 512 KiB | LMEM 2048 KiB |
| C3 | LMEM 1536 KiB + ACC 512 KiB | LMEM 2048 KiB |
| C4 | LMEM 1024 KiB + ACC 512 KiB + TMEM 512 KiB | Same as ACC case |

The area categories have the following meanings:

- **Memory**: LMEM, ACC, and TMEM compiled-SRAM macro rectangles. SRAM wrapper,
  arbitration, switching, DMA, and control logic remain part of design logic.
- **Common backbone**: the reused C3 f16 SIMT pipeline, cache hierarchy,
  socket/cluster logic, and top-level infrastructure. The HD-corrected common
  backbone area is 5.8237 mm².
- **Naive with ACC**: the previous naive GEMM hierarchy is used, with its
  register fallback ACC replaced by HD compiled SRAM.
- **Naive without ACC**: the current naive GEMM hierarchy is used and PSUM data
  is stored in LMEM.

## Case 1: Naive GEMM with a 512 KiB ACC

| Memory | Common backbone | C1 | C2 | C3 | C4 |
|---|---|---:|---:|---:|---:|
| Included | Included | 10.1331 | 12.0691 | 11.5220 | 11.2137 |
| Included | Excluded | 4.3094 | 6.2454 | 5.6983 | 5.3900 |
| Excluded | Included | 6.8357 | 8.0770 | 7.5299 | 7.2216 |
| Excluded | Excluded | 1.0120 | 2.2534 | 1.7062 | 1.3980 |

The fully included design areas rank as follows:

```text
C2 (12.0691) > C3 (11.5220) > C4 (11.2137) > C1 (10.1331)
```

## Case 2: Naive GEMM without an ACC

| Memory | Common backbone | C1 | C2 | C3 | C4 |
|---|---|---:|---:|---:|---:|
| Included | Included | 10.1331 | 11.4596 | 10.9125 | 11.2137 |
| Included | Excluded | 4.3094 | 5.6359 | 5.0888 | 5.3900 |
| Excluded | Included | 6.8357 | 8.1622 | 7.6151 | 7.2216 |
| Excluded | Excluded | 1.0120 | 2.3385 | 1.7914 | 1.3980 |

The fully included design areas rank as follows:

```text
C2 (11.4596) > C4 (11.2137) > C3 (10.9125) > C1 (10.1331)
```

## Component Breakdown

### Naive with ACC

| Design | Design logic | Memory macros | Common backbone | Fully included |
|---|---:|---:|---:|---:|
| C1 | 1.0120 | 3.2974 | 5.8237 | 10.1331 |
| C2 | 2.2534 | 3.9920 | 5.8237 | 12.0691 |
| C3 | 1.7062 | 3.9920 | 5.8237 | 11.5220 |
| C4 | 1.3980 | 3.9920 | 5.8237 | 11.2137 |

### Naive without ACC

| Design | Design logic | Memory macros | Common backbone | Fully included |
|---|---:|---:|---:|---:|
| C1 | 1.0120 | 3.2974 | 5.8237 | 10.1331 |
| C2 | 2.3385 | 3.2974 | 5.8237 | 11.4596 |
| C3 | 1.7914 | 3.2974 | 5.8237 | 10.9125 |
| C4 | 1.3980 | 3.9920 | 5.8237 | 11.2137 |

The TCU remains the only difference between C2 and C3, so C2 is 0.5471 mm²
larger than C3 in every grid cell.

## HD SRAM Breakdown

| Design/storage | Capacity | HD macro area | Depth mapping per bank |
|---|---:|---:|---|
| C1/C2/C3 LMEM-only | 2048 KiB | 3.2974 | `8192x64` |
| Split LMEM | 1536 KiB | 2.9413 | `4096x64 + 1024x64 + 1024x64` |
| C4 LMEM | 1024 KiB | 1.8905 | `4096x64` |
| Naive ACC | 512 KiB | 1.0508 | 16 × `1024x64` per logical bank |
| C4 ACC | 512 KiB | 1.0508 | 16 × `1024x64` per logical bank |
| C4 TMEM | 512 KiB | 1.0508 | 8 × `1024x64` per logical bank |

The 512 KiB naive ACC, C4 ACC, and C4 TMEM all use the full 1024-entry
physical depth. Their total macro areas are identical because they store the
same number of bits, although ACC and TMEM use different bank widths and
width-tile counts.

Consequently, the C4 and ACC-based naive memory macros both occupy 3.9920 mm².
The LMEM-only naive design occupies 3.2974 mm².

## Effect of Removing the Naive ACC

For C2 and C3, removing the ACC changes area as follows:

| Contribution | Area change |
|---|---:|
| Memory macros | -0.6947 mm² |
| Naive logic | +0.0852 mm² |
| Net area | -0.6095 mm² |

The LMEM-only naive logic is slightly larger because it adds PSUM split,
queue, ordering, and LMEM interface logic. This increase is much smaller than
the SRAM reduction, so removing the ACC reduces C2 and C3 by 0.6095 mm².

## Method and Limitations

The fully included rows can be reproduced with the following base commands.

Naive with ACC:

```bash
conda run -n stable python analysis_workspace/top_breakdown/get_area_of_candidates.py \
  --sram-type HD --naive-acc \
  --c1-lmem-kib 2048 \
  --c2-lmem-kib 1536 --c2-acc-kib 512 \
  --c3-lmem-kib 1536 --c3-acc-kib 512 \
  --c4-lmem-kib 1024 --c4-acc-kib 512 --c4-tmem-kib 512
```

Naive without ACC:

```bash
conda run -n stable python analysis_workspace/top_breakdown/get_area_of_candidates.py \
  --sram-type HD --no-naive-acc \
  --c1-lmem-kib 2048 --c2-lmem-kib 2048 --c3-lmem-kib 2048 \
  --c4-lmem-kib 1024 --c4-acc-kib 512 --c4-tmem-kib 512
```

Use each candidate's `--no-cN-include-memory` and
`--no-cN-include-common` switches to reproduce the other grid rows.

- Areas are generated by `get_area_of_candidates.py` using the hwexplorer
  Design Compiler area parser and the checked-in physical dimensions in
  `lpp28_sram_macro_areas.csv`. Runtime access to memory-compiler LEFs is not
  required.
- The C3 f16 top supplies the common backbone, current naive GEMM logic,
  memory-unit logic, and DMA node.
- The previous non-f16 naive top supplies the ACC-based naive GEMM logic after
  its register fallback ACC is removed.
- The older C4 top supplies improve-GEMM and C4 memory-unit logic after LMEM,
  ACC, and TMEM storage is removed.
- SRAM depth tiling minimizes the sum of cataloged macro rectangle areas. A 1536 KiB
  LMEM therefore uses `4096x64 + 1024x64 + 1024x64`, rather than
  `4096x64 + 2048x64`, in every one of the 32 banks.
- Additional address decode, chip-select, and output-mux area associated with
  multi-macro depth tiling is not explicitly modeled.
- GPR, cache-tag, and DMA-buffer dual-port RAMs retain their source-report
  areas; only LMEM, cache data, ACC, and TMEM single-port SRAMs are normalized.
- Exact C1, C2, and f16 C4 top-level synthesis reports should replace these
  provisional compositions when they become available.
