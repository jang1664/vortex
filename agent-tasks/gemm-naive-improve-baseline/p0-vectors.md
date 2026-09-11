# P0 shared vectors and repeated-job verification

Scope: plan.rev3.md section 7.2 items 1, 4, and the host portion of item 5. These changes do not modify RTL, kernel code, or the command ABI.

## Production changes

- Both apps use `tests/regression/fpint_gemm_ffn_hw/test_vectors.h` for the corrected logical A/W/S/Z initializer. Generation zero without `--tagged` retains naive's corrected defaults. Improve now receives exactly those same logical values. Padded K/N elements in improve remain zero; logical N, rather than padded N, determines the W pattern.
- LMEM row-major/transposed packed W and TMEM tiled packed W stay backend-specific. Both references decode generated packed bytes. The TMEM decoder computes random-access offsets independently of the sequential conversion loop. The reference rounds the QROW A*S product to FP16 before accumulation; the bounded dyadic vectors make that rounding exact.
- `--tagged` selects a deterministic mixed-index A/W pattern for directed address-identity testing. It does not alter the default performance vectors or S/Z formulas. It distinguishes all A rows and all 1,024 16x16 W microtiles in the tested M4/M256, K512/N512 cases. This is finite tested coverage, not a uniqueness proof for arbitrary dimensions.
- Each `-r` iteration regenerates A/W/S/Z for its generation, uploads every source, writes FP16 NaNs throughout the destination, launches, waits, reads status, and verifies that job before continuing. A mismatch stops the sequence immediately. Consecutive jobs change each tensor and the expected output. `-r 0` is rejected.
- Power and poll-only modes retain their lack of numerical verification and say so. Status is checked per job in those modes as well. Their successful exit is not numerical evidence.
- Both comparators retain the user-required 0.001 relative tolerance and the expected-zero absolute branch.

## Host evidence

`p0-vectors-check.cpp` includes each production main.cpp separately and uses an independent double-precision accumulation oracle. Each backend covers 72 combinations: M4/K512/N512, M256/K512/N512, M3/K65/N33; QCOL/QROW; both W layouts; default/tagged data; generations 0, 1, 2.

The checker validates finite expected results, exact agreement with the independent oracle, exact QROW A*S representability, both NaN poison patterns being rejected, generation changes in every tensor and output, and tagged row/microtile distinctions. Tagged stale W K microtile 0 substituted for microtile 7 and A row 0 substituted for row 7 are numerically rejected. The latter A check applies to M256. It also checks every TMEM packed W entry against the generated raw W, including padding.

Five per-case digests cover logical A, decoded W, S, Z, and expected C. Exact line-by-line equality between the two backend logs establishes parity for the listed cases, including improve's padded K/N conversion. This is host payload/oracle evidence, not proof of DMA transfer or RTL execution. The K65/N33 case is host-only until device tail support is independently established.

- `p0-vectors-naive.log`, `p0-vectors-improve.log`: th16/MXU16 host packing checks using the sourced backend configs below.
- `p0-vectors-mxu32.log`: matching 72-case digests also obtained with the include tree's default MXU32 configuration, covering that alternate TMEM packing size.
- `p0-vectors-legacy-check.log`: the pre-existing rev3 checker passes unchanged, including the 7,680 single-scale substitutions, 24 sparse local S/Z controls, broad controls, and tolerance branches. This establishes retention of the corrected generation-zero defaults.
- Both production files pass `/usr/bin/g++ -std=c++17 -Wall -Wextra ... -fsyntax-only` without diagnostics.

All 72 digest lines match exactly across both MXU16 backend logs and the MXU32 log. SHA-256 of each matching log: `eb8c847248fb0097200978b2b659934f146c4f4c6849e6860f80e0104add7570`.

## Reproduction

Run these host checks from the repository root in Bash. The include paths below are existing configured build trees. Explicit CONFIGS is necessary: generated VX_config.h alone defaults to a different MXU/thread configuration.

```bash
source configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh
/usr/bin/g++ -std=c++17 -O2 -ffunction-sections -fdata-sections -DXLEN_64 $CONFIGS \
  -Iruntime/include -Ibuild_fpint_latency_naive_vcs/hw -Wl,--gc-sections \
  agent-tasks/gemm-naive-improve-baseline/p0-vectors-check.cpp -o /tmp/gemm-p0-vectors-naive16
source configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh
/usr/bin/g++ -std=c++17 -O2 -ffunction-sections -fdata-sections -DP0_IMPROVE -DXLEN_64 $CONFIGS \
  -Iruntime/include -Ibuild_fpint_latency_improve_vcs/hw -Wl,--gc-sections \
  agent-tasks/gemm-naive-improve-baseline/p0-vectors-check.cpp -o /tmp/gemm-p0-vectors-improve16
/tmp/gemm-p0-vectors-naive16 > agent-tasks/gemm-naive-improve-baseline/p0-vectors-naive.log
/tmp/gemm-p0-vectors-improve16 > agent-tasks/gemm-naive-improve-baseline/p0-vectors-improve.log
cmp agent-tasks/gemm-naive-improve-baseline/p0-vectors-naive.log \
    agent-tasks/gemm-naive-improve-baseline/p0-vectors-improve.log
```

## Device verification request and remaining limits

Use configured build directories, source the selected backend config, and run `ci/run_black.sh xrt-vcs-sim` with the respective app. Required baseline args are `-m 4 -k 512 -n 512` and `-m 256 -k 512 -n 512`. Additional directed runs need both `-d 0/1` and `-t 0/1`, `--tagged`, and at least `-r 3`; each normal repetition must print its own `Verified job X/3`. Exercise the supported power and `--pol` modes without counting them as numerical coverage.

A device/output or status fault in the first or middle repetition must terminate before the next launch. Confirm each invocation's source uploads and output poisoning in runtime/FSDB evidence. These host changes and tests do not themselves verify that device lifecycle, cache visibility, physical lane/beat/descriptor S/Z fault models, normalized latency, synthesis cost, or any RTL redesign gate. No simulation was run by the vector subtask.
