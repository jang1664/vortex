# TCU FP16 widening regression

This VCS test instantiates the production `fp16_to_fp32` module in
`hw/rtl/tcu/VX_tcu_fedp_dsp.sv`. Berkeley SoftFloat supplies an independent
reference for all 65,536 half encodings. Finite values, signed zero and
infinities must match exactly. NaNs must remain quiet NaNs; their payload
mapping is deliberately not changed by this fix.

Run from a configured build directory:

```bash
source ../configs/tcu_th16_c1_v3.sh
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
make -C hw/unittest/tcu_fp16_convert compile
make -C hw/unittest/tcu_fp16_convert run
```

The old exponent expression fails for all 2,046 nonzero signed subnormals.
The corrected expression `127 - 15 - leading_zeros` passes all inputs.
The test checks the explicit PASS marker because a VCS `$fatal` may not
produce a nonzero process status in every invocation.

## TCU integration check

The existing `sgemm_tcu` app has opt-in `-p subnormal-a` and `-p subnormal-b`
patterns. These place positive and negative subnormal inputs in one operand
and an exact normal power of two in the other. Small sums are exactly
representable before final FP16 rounding; outputs use a bit-exact comparison.
The default random input and tolerance are unchanged.

```bash
source ../configs/tcu_th16_c1_v3.sh
export CC=/usr/bin/gcc CXX=/usr/bin/g++
ci/run_black.sh xrt-vcs-sim --app sgemm_tcu \
  --args '-m 4 -n 16 -k 32 -p subnormal-a' \
  --configs-extra '-DTCU_DSP -DDISABLE_FSDB'
# Repeat with subnormal-b and random. Use a separate configured build for C2:
# configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3.sh
```

`TCU_DSP` must be explicit: ordinary simulation otherwise defaults to the TCU
DPI implementation and can miss this converter bug. Within the DSP module,
the non-synthesis `DSP_TEST` branch models FP32 multiplication/addition with
DPI while retaining the actual converter and pipeline RTL. This validates
the converter and integration, not post-route timing or a rebuilt FPGA image.
