# TMEM Partial-Wide Weight Read Spec

## Status

Confirmed on 2026-08-04 from the user's explicit request to generalize the
WLOAD8 two-bank read path and validate WLOAD_NUM 4, 8, 16, and 32.

## Goal

Deliver one native GEMM weight beat per TMEM read transaction instead of
serially reading 64-byte beats and packing them in the local DMA.

With a 64-byte TMEM bank port and 32 INT4 columns:

| MXU_WLOAD_NUM | GEMM weight beat | Banks read together |
|---:|---:|---:|
| 4  | 64 B  | 1 |
| 8  | 128 B | 2 |
| 16 | 256 B | 4 |
| 32 | 512 B | 8 |

## Scope

- Generalize `VX_tmem_wide_read_switch` from all-bank-only reads to a
  power-of-two subset of consecutive, naturally aligned banks.
- Route the weight local DMA through the native weight width for all supported
  WLOAD values; remove the normal-path 64-to-wide serial packing dependency.
- Preserve bank interleaving and response ordering/tag restoration.
- Extend `ci/run_target_gemm.sh` with an explicit, validated WLOAD selector so
  all four configurations are reproducible without ad-hoc CONFIGS overrides.
- Add a focused unittest for 1/2/4/8-bank reads.

## Design Decisions

- `BANKS_PER_BEAT = WIDE_DATA_SIZE / DATA_SIZE` must be 1, 2, 4, or 8 and must
  divide `NUM_BANKS`.
- A wide request address is expressed in `WIDE_DATA_SIZE` units. Its low
  `log2(NUM_BANKS / BANKS_PER_BEAT)` bits select an aligned bank group; higher
  bits form the bank-local address.
- All banks in the selected group receive their request in parallel when they
  are ready. A request completes only after every selected bank accepts it.
- Responses may return with skew. Data is assembled by physical bank slice and
  exposed as one wide response after all selected responses arrive.
- Only the selected bank mask participates in request/response completion.
- This change guarantees simultaneous bank fan-out, but does not add multiple
  outstanding wide transactions inside the switch.
- `--wload` changes only `MXU_WLOAD_NUM`; it does not implicitly define
  `WLOAD_AT_ONCE`.

## Constraints

- Supported WLOAD values are exactly 4, 8, 16, and 32.
- `GEMM_WEIGHT_DATA_SIZE` must be a power-of-two multiple of the 64-byte TMEM
  bank width and no larger than the full bank stripe.
- Existing input, scale/zero, output, and HBM DMA paths are outside scope.
- Existing user changes in the dirty worktree must be preserved.

## Verification

1. New switch unittest, VCS via `tools/verify_rtl.py`:
   - instantiate 64B, 128B, 256B, and 512B variants;
   - verify exact same-cycle request fan-out masks of 1, 2, 4, and 8 banks;
   - verify bank-local address mapping and lane-to-bank data placement;
   - skew response timing and check assembled wide data/tag;
   - exercise backpressure and multiple bank groups/local addresses.
2. Existing relevant DMA/GEMM unittests after the new test passes.
3. `xrt-vcs-sim` blackbox using `fpint_gemm_ffn_hw`, fixed
   `-m 4 -n 256 -k 256 -q 32 -t 0 -d 1`, once for each WLOAD value.
4. Each blackbox must report `PASSED`, no VCS fatal, no psum underflow or
   accumulator conflict, and the expected weight-fire count:
   - WLOAD4: 512
   - WLOAD8: 256
   - WLOAD16: 128
   - WLOAD32: 64
