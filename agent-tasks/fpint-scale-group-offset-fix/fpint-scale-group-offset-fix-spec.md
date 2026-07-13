# FPINT Scale Group Offset Fix

**Status**: confirmed

## Goal

Fix QCOL FPINT GEMM results when scale and zero-point values vary across K
quantization groups. The improve FSM currently reuses group 0 for every K
microtile because its SCBUF/ZPBUF microtile address omits the group offset.

## Scope

- Modify `hw/rtl/core/gemm/VX_gemm_fsm.sv` only.
- Add the current `g0` offset to QCOL scale and zero-point LMEM addresses.
- Add the next `g0_n` offset to QCOL scale and zero-point preload addresses.
- Do not modify the naive FSM, QROW addressing, host layouts, or tests.

## Design

The improve QCOL LMEM layout is `[nb][groups][MXU_NT]`. Therefore each
microtile address is:

```
buffer_base
  + nt_mxu * scale_nb_stride
  + group * MXU_NT * element_bytes
```

`group` is `g0` for the current microtile and `g0_n` for the next preload.
Scale and zero-point elements are both 16 bits in this path.

## Verification

Run the reported blackbox case from the configured `build/` directory with the
defines from `configs/improve_th16_tcol32_hwexp_dcache.sh`:

```
./ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw \
  --args "-m 128 -k 128 -n 128 -q 32" --debug 3
```

The expected result is `PASSED` with all 16384 output elements matching.
