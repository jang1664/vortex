# TCU input subnormal conversion: RTL fix and VCS verification

2026-10-09. C1/C2 share the FP16 input converter in
`hw/rtl/tcu/VX_tcu_fedp_dsp.sv`. The subnormal exponent was two too large:
`127 - 14 - leading_zeros + 1`. It is now `127 - 15 - leading_zeros`, since
the 10-bit fraction represents `fraction * 2^-24`.
Normal/special-value branches, ports, pipeline registers and latency are unchanged.

| Verification | Before fix | After fix |
|---|---|---|
| VCS converter, all 65,536 FP16 encodings | 2,046 mismatches: every nonzero signed subnormal | 0 mismatches |
| C1 DSP GEMM, A subnormal, M4/N16/K32 | 64/64 outputs wrong; 15,707 cycles | Bit-exact PASS; 15,707 cycles |
| C1 DSP GEMM, B subnormal, M4/N16/K32 | Not run | Bit-exact PASS; 15,707 cycles |
| C1 DSP GEMM, ordinary random input, M4/N16/K32 | Not run | Existing reference check PASS; 15,720 cycles |
| C2 DSP GEMM, B subnormal, M4/N16/K32 | Not run | Bit-exact PASS; 15,706 cycles |

The converter oracle is Berkeley SoftFloat. Finite values, signed zeros and
infinities are checked bit-exactly; NaNs are checked for quiet-NaN class without
changing existing payload behavior. Directed GEMM patterns include both signs,
the smallest subnormal, and the largest subnormal. The other operand is 1024,
making the accumulated outputs normal and exposing the input defect independently
of subnormal output conversion. GEMM uses the existing b_colmajor kernel unchanged.

## Reproduction and provenance

Separate configured builds: `build_tcu_subnormal_c1/`, `build_tcu_subnormal_c2/`.
Source configs respectively:

- `configs/tcu_th16_c1_v3.sh`
- `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3.sh`

Both were configured with
`../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`.
Commands run from each build, after sourcing its config:

```bash
export CC=/usr/bin/gcc CXX=/usr/bin/g++
make -C hw/unittest/tcu_fp16_convert compile
make -C hw/unittest/tcu_fp16_convert run
timeout 300 ci/run_black.sh xrt-vcs-sim --app sgemm_tcu \
  --args '-m 4 -n 16 -k 32 -p subnormal-a' \
  --configs-extra '-DTCU_DSP -DDISABLE_FSDB'
```

Repeat the GEMM command with `subnormal-b` or `random` as shown in the table.
Both blackbox compile logs explicitly show `VX_tcu_fedp_dsp` and `fp16_to_fp32`.
The standalone converter test was run in the C1 build. Source/log hashes and
exact result markers are in [the JSON evidence](TCU_SUBNORMAL_VCS_FIX.json).
The C1 baseline compile and simulation logs were preserved before rebuilding.

## Scope

`TCU_DSP` is forced to prevent the ordinary simulation default `TCU_DPI` from
bypassing this converter. The non-synthesis DSP module still uses its existing
`DSP_TEST` FP32 multiply/add models; the converter and pipeline are actual RTL.
This is not post-route or newly synthesized FPGA validation.

No MXU multiplier/converter, SIMD FPU converter, decoder tolerance, historical
latency database, FPGA image or release tag was changed. The zero cycle delta
above applies to that one identical C1 test; no resource/timing synthesis claim
is made. C1/C2 full-decoder FPGA acceptance remains pending a rebuilt image.
