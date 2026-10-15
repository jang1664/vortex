# Rectangular FPFP MXU verification

Date: 2026-10-14. Status: complete; all scoped verification passed. Baseline: the preceding uncommitted FPFP implementation,
archived before this change in `build_fpfp_rect_baseline/source_before.tar.gz`.

FPFP-only images now support independent power-of-two MXU_ROW and MXU_COL.
ROW is the K reduction width; COL is the N output width. The tested SIMT thread
count remains 16 and is independent of the FPFP array dimensions.

## Changes

- Relax the naive FSM's square-array restriction for FPFP-only builds.
- Reuse the operand DMA with whole native-word input widths, rather than
  limiting it to the old 32/64-byte square configurations.
- Select row-only FP16 weight registers at elaboration. This removes the
  unused transpose indexing that was invalid when ROW exceeded COL.
- Exclude unused zero-lane INT4 interfaces from narrow FPFP-only builds.
- Apply INT4 tree latency assertions only where that tree is present.
- Give this MMIO regression app its own compile-time geometry checks;
  existing vector and FPINT thread/MXU equality checks remain unchanged.
- Strengthen the frontend test with distinct row and column data.

No external-memory layout, FSM loop order, ACC address mapping, or partial-sum
precision changed. Existing generators already use ROW for K and COL for N.
FP32 accumulation and final FP16 conversion remain unchanged.

## Legal geometry

Both dimensions are positive powers of two, subject to existing transport and
storage constraints:

- ROW/COL must each divide the 128-element DMA tile dimension.
- FP16 input/output vectors contain whole 8-byte native LMEM words:
  ROW/COL must each be at least 4.
- Input/output vectors, grouped weight requests and ACC transports must fit
  physical LMEM ports. With the tested 16-port configuration, ROW can be
  4/8/16/32/64 and COL can be 4/8/16; this describes parameter limits, not an
  exhaustive test of every combination.
- WLOAD divides ROW and `2*COL*WLOAD` bytes fit the physical request lanes.
  COL_TILE divides COL; tested configs set COL_TILE=COL.
- Internal ACC capacity must hold a 128x128 FP32 tile (64 KiB).

Use only `GEMM_NAIVE_FP16_ENABLE` for rectangular images. Enabling FPINT,
including the legacy `GEMM_NAIVE` macro, retains its existing square geometry
requirements. Neither vector kernels nor FPINT were extended to rectangular
arrays in this task.

The scratch reservation remains 224 KiB, fitting the configured 1,280 KiB LMEM.
The static capacity/address audit passes for 8x16, 16x8 and 4x4 with ACC depth
1024; see [capacity_preflight.json](capacity_preflight.json).

## Verification

All 17 integration cases, four frontend unit configurations, and 12 host
configuration checks passed in verification iteration 1. Two invalid RTL
configurations were rejected as expected. No unexpected RTL failure occurred.
All simulation tests use VCS and the configured Xilinx FP32 IP.
FPFP output comparison is bit exact against the reference for that geometry
(signed zero is accepted as equal). Changing ROW changes floating-point
reduction order; bit identity between different geometries is not promised.

| MXU ROW x COL | Shape M/K/N | WLOAD | Core cycles | GEMM cycles | Result |
|---|---|---:|---:|---:|---|
| 8x16 | 1/32/32 | 1 | 8,298 | 444 | PASS |
| 8x16 | 1/32/32 | 4 | 8,298 | 428 | PASS |
| 8x16 | 3/24/17, tails | 1 | 8,298 | 440 | PASS |
| 8x16 | 3/24/17, tails | 4 | 8,298 | 434 | PASS |
| 8x16 | 2/136/144, multiple K/N tiles | 1 | 11,461 | 3,587 | PASS |
| 8x16 | 2/136/144, multiple K/N tiles | 4 | 11,161 | 3,341 | PASS |
| 8x16 | 129/8/16, multiple M tiles | 4 | 9,348 | 1,503 | PASS |
| 16x8 | 3/32/9, tails | 1 | 8,298 | 485 | PASS |
| 4x4 | 3/12/5, minimum word width | 1 | 8,223 | 371 | PASS |
| 8x16, LMEM ACC | 2/24/17 | 4 | 8,298 | 425 | PASS |

Directed subnormal integration cases also pass at 8x16 WLOAD1/4 and 16x8 WLOAD1.
For M2/K136/N144, WLOAD4 reduces core cycles by 2.62% and GEMM cycles by 6.86%
relative to WLOAD1. These counters exclude host wall time.

| Existing regression | Before core / GEMM cycles | After core / GEMM cycles |
|---|---:|---:|
| FPFP 16x16 WLOAD1, M1/K32/N32 | 8,298 / 441 | 8,298 / 441 |
| FPFP 16x16 WLOAD4, M1/K32/N32 | 8,223 / 414 | 8,223 / 414 |
| Improve, M1/K32/N32 | 7,510 / 167 | 7,510 / 167 |

The dual-capability 16x16 sequence FPFP -> FPINT -> FPFP also passes. Improve's
selected/preprocessed RTL token hash remains identical to baseline; no improve
synthesis was used. Detailed evidence: [FINAL_SUMMARY.json](verification/FINAL_SUMMARY.json).

Unit tests cover 8x16 WLOAD1/4, 16x8 WLOAD1 and 4x4 WLOAD1. Each passes 40
transactions with both weight banks, subnormal inputs, distinguishable row/column
patterns, result-FIFO wraparound and downstream backpressure.

Invalid configurations are also checked: host compile-time diagnostics reject
non-power-of-two dimensions, dimensions below one native word, non-dividing
WLOAD and oversized weight groups. The WLOAD=3 unit test reaches the explicit
RTL assertion. Full-node ROW=2 is rejected during RTL compilation because its
input lane array would have size zero, before the initial-block diagnostic can
run; the host has a clear whole-word diagnostic for this case. Expected failures
are classified in [negative_geometry_checks.json](verification/negative_geometry_checks.json).

## Reproduce

The configured directory `build_fpfp_rect_8x16_w4` contains the tested 8x16,
WLOAD4 setup. From that directory:

```bash
source ./config.sh
./ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --perf 3 \
  --args "--fp16-weights -m 3 -k 24 -n 17 --seed 1"
```

Use a separate configured build for each geometry. Exact resolved configuration
strings are saved in [configs.json](verification/configs.json); individual
verification reports retain commands and log paths. `iter11` in blackbox file
names is an inert build stamp that forces rebuilding previous simulation
binaries; this task's verification loop is iteration 1.

No PnR, frequency/area measurement, other floating-point backend validation, or
multicore job-partition validation was performed. The previous task's results
remain in `agent-tasks/naive-fpfp/RESULTS.md`.
