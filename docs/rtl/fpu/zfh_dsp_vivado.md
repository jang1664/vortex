# Scalar Zfh on the Vivado DSP FPU

The scalar DSP backend supports `rv64imaf_zfh/lp64f` when it is built with
Vivado floating-point IP. Double precision remains disabled.

Use the checked-in configuration:

```sh
source configs/rv64_zfh_lp64f_dsp_vivado.sh
```

Its relevant RTL defines are:

```text
EXT_D_DISABLE EXT_ZFH_ENABLE FPU_DSP VIVADO
```

`EXT_ZFH_ENABLE + FPU_DSP` is intentionally rejected without `VIVADO`.
The generic DSP/DPI implementations do not provide the required half-precision
operators. `FPU_FPNEW` remains the portable Zfh backend.

## Datapath contract

The DSP backend transports destination format, source format, add/subtract
modifier, and integer-width metadata independently. Floating-point values still
use 32-bit internal containers. A half result is stored in bits `[15:0]` and is
NaN-boxed as `32'hffff_hhhh` before returning to the core.

FP16 and FP32 divide/square-root requests use separate serializers and response
arbitration because their Vivado IP latencies differ. H-to-S and S-to-H
conversions also have independent serializers. This prevents a shorter result
from being associated with an older tag or lane mask.

| Operation | Vivado module | Latency |
| --- | --- | ---: |
| Half FMA/add/sub/mul | `xil_f16_fma` | 4 |
| Half divide | `xil_f16_div` | 15 |
| Half square root | `xil_f16_sqrt` | 15 |
| Half to single | `xil_f16_to_f32` | 2 |
| Single to half | `xil_f32_to_f16` | 3 |
| Single divide | `xil_fdiv` | 28 |
| Single square root | `xil_fsqrt` | 28 |

`VX_fpu_f2f` corrects the conversion IP's subnormal behavior in a parallel RTL
path. Nonzero half subnormals are normalized exactly when widened to single.
Finite single values with magnitude below `2^-14` are rounded to half with
gradual underflow, including signed zero and rounding up to the minimum normal
half value. This path uses the resolved RISC-V rounding mode and reports NX for
inexact conversion and UF when the result is tiny after precision rounding
assuming an unbounded exponent range. At the normal boundary, UF can therefore
be set even when the final half result rounds up to the minimum normal value.
Exact subnormal conversions raise neither flag.

The correction uses the existing rounding, leading-zero-count, and pipeline
helpers. It advances under the same PE enable as the IP, preserving the listed
latencies, serialization, lane masks, tags, and output backpressure behavior.
Normal and special-value conversions still use the existing IP path and retain
its rounding/exception limitations. Half arithmetic IPs still flush subnormal
inputs and results to zero; the conversion correction does not alter them.

Vivado's `C_Has_UNDERFLOW` option enables an exception output, not subnormal
support. The Floating-Point Operator v7.1 IP has no gradual-underflow switch for
these conversions, so the existing XCI generation settings remain unchanged.

The scalar IP names are distinct from the existing `xil_f16add` and
`xil_f16mul` tensor/GEMM IPs. Generate or refresh all XCI files with:

```sh
vivado -mode batch -nolog -nojournal -notrace \
  -source hw/scripts/xilinx_ip_gen.tcl \
  -tclargs "$FPU_IP" xcu55c-fsvh2892-2L-e
```

The generator reopens existing XCI files and only creates missing IP, so it is
safe to use with an incrementally populated IP directory. The VCS, standalone
Vivado synthesis, and XRT packaging manifests all include the five scalar Zfh
XCI files.

The integer conversion datapath remains a 32-bit container. The full
`is_int64` decoder metadata is preserved at the DSP boundary, but scalar DSP
integer conversions implement the Zfh W/WU forms; use FPNEW for L/LU
conversions.

## Regression scope

`hw/unittest/fpu_f2f_subnormal` checks conversion results and exception flags
against SoftFloat, including signed half subnormals, narrowing boundaries,
rounding modes, and serializer stalls. Run it with VCS from a configured build
directory after sourcing the DSP/Vivado configuration:

```sh
python3 ../tools/verify_rtl.py unittest \
  --path hw/unittest/fpu_f2f_subnormal --sim vcs
```

`tests/regression/fp16_zfh` always checks the backend-independent Zfh baseline:
half add/multiply, H-to-S and S-to-H conversion, and comparison. When
`FPU_DSP` is present in `CONFIGS`, the same kernel additionally checks half
divide, square root, fused multiply-add, minimum, classification, W/WU integer
conversion, rounding, and signed-zero special cases. The extra result fields
remain zero-initialized in the FPNEW baseline build so the host/kernel layout
is identical for both backends.

The enhanced suite is intentionally DSP-specific. The existing FPNEW wrapper
retires multi-lane operations using lane 0 ready/valid/tag signaling. Correctly
synchronizing independently completed, variable-latency FPNEW lane responses
requires a separate retirement redesign and is outside this DSP/Zfh change.
