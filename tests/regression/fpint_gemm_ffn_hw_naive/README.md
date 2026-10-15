# Naive FPINT / FPFP regression

The default remains FP16 x INT4. `--fp16-weights` selects FP16 x FP16 with
row-major A `[M,K]`, B `[K,N]`, and FP16 C `[M,N]`. It does not transpose B or
quantize either operand. FPFP rejects `-t 1` and ignores `-q` / `-d` values.

Build with the same configuration as the image under test:

- `GEMM_NAIVE_ENABLE`: FPINT capability (legacy `GEMM_NAIVE` also enables it).
- `GEMM_NAIVE_FP16_ENABLE`: FPFP capability.
- Both capabilities: either format can be selected for each job.
- Neither: the app rejects GEMM dispatch.

The app validates its compiled capabilities; it cannot discover a mismatched
FPGA image's format support through the current device-capabilities API.
Rebuild both the host and kernel after changing configuration or `common.h`.
The separate `_bench` executable remains INT4-only.

From a configured build directory, with the required config sourced, use
`ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --perf 3 --args "..."`.
Representative argument strings:

| Purpose | Arguments |
|---|---|
| Small random FPFP | `--fp16-weights -m 1 -k 32 -n 32 --seed 1` |
| Address-tagged FPFP | `--fp16-weights --tagged -m 4 -k 256 -n 256` |
| Subnormal A, B, and output | `--fp16-weights --subnormal -m 2 -k 32 -n 32` |
| Multiple K tiles | `--fp16-weights -m 4 -k 384 -n 256 --seed 2` |
| Repeated jobs with changed data | `--fp16-weights -m 1 -k 32 -n 32 -r 3` |
| FPFP / FPINT / FPFP, dual-capability build | `--fp16-weights --alternate-formats -m 1 -k 32 -n 32 -r 3` |
| Three queued formats within one kernel | `--queued-formats -m 4 -k 256 -n 32` |
| Ignored legacy quantization fields | `--fp16-weights -m 1 -k 32 -n 32 -q 0 -d 57005` |

Use separate configured build directories for `FPFP_MXU_WLOAD_NUM=1` and `4`.
The same seed, shape, and repetition number produce identical input bytes
regardless of WLOAD. Existing INT4 invocations retain their input generator and
verification tolerance.

FPFP has independent geometry: `FPFP_MXU_ROW` is the K reduction width,
`FPFP_MXU_COL` is the N output width, and `FPFP_MXU_WLOAD_NUM` is the number of
weight rows per group. These default to the corresponding legacy `MXU_*`
values, preserving existing FPFP-only rectangular configurations.
Both dimensions must be positive powers of two;
the MMIO driver does not require either dimension to equal `NUM_THREADS`.
For example, in a dual image keep FPINT `MXU_ROW=MXU_COL=16` and set
`FPFP_MXU_ROW=8`, `FPFP_MXU_COL=8` (or 16), and `FPFP_MXU_WLOAD_NUM=1` or 4.
An FPFP-only image can instead keep its legacy `MXU_ROW=8`, `MXU_COL=16`
configuration without explicit `FPFP_*` overrides. Remove the
legacy `GEMM_NAIVE` token as well as `GEMM_NAIVE_ENABLE` for an FPFP-only build.
K must be divisible by the selected format's ROW; alternating or queued tests
require divisibility by both enabled formats. N may have an output tail.

The current native 8-byte LMEM transfers require ROW and COL at least 4.
Both dimensions must divide the 128-element DMA tiles, and operand/weight/ACC
lanes must fit the physical ports. WLOAD must divide its format's ROW.
See `docs/rtl/core/gemm/VX_gemm_fpfp_front.md` for the complete geometry
constraints. Enabling FPINT retains its existing square geometry contract.

FPFP reference calculation widens the uploaded half operands to FP32,
multiplies without an intermediate FP16 rounding, reduces adjacent pairs in a
balanced tree of `FPFP_MXU_ROW` lanes, and accumulates K slices in FP32. Only the
final result is rounded to FP16 (round-to-nearest-even). Comparison is bit exact
except that positive and negative zero are accepted as equal; raw bit
differences are reported separately. A separate FP64 dot product supplies the
mathematical-error diagnostic, not the pass/fail threshold. Verification also
reports max absolute/relative error and output NaN/Inf counts. Output is
poisoned before each run so missing stores fail.

FPFP scratch uses two 128x128 FP16 A tiles and two 128x128 FP16 B tiles.
Shared C/partial-sum storage has `128 * (128 / min_COL) * physical_COL`
elements, where `physical_COL` is the maximum enabled COL and `min_COL` is
the minimum enabled COL. This reserves padding between physical microtile
slots when frontend widths differ: 224 KiB for one COL width; 320 KiB for
dual FPINT COL=16 and FPFP COL=8. The C elements are FP16 and partial sums are
FP32. There are no
scale/zero buffers or uploads. All allocations retain 64-byte alignment and
are checked against the reported LMEM size. `--lmem-offset` moves the whole
scratch region. Alternating formats reuses this region after each job drains.

`--queued-formats` reserves three job entries, programs all descriptors, then
publishes FPFP / FPINT / FPFP with consecutive CONTROL writes before waiting,
within a single kernel launch. Jobs have distinct inputs,
outputs, and scratch regions; all three outputs are validated. The host checks
the combined scratch capacity and requires at least two jobs still valid after
submission to demonstrate queued overlap. Increase the shape if it completes
too quickly to observe overlap. This test runs on core 0, requires a dual-format
image with at least three descriptor entries, and cannot be combined with
repetition, power, poll-only, or alternating-launch modes.
Set `JOB_MMIO_NUM_ENTRIES=4` in both the image and software configuration for
this test; the default one-entry configuration is rejected before device open.

Descriptor CONTROL bit `JOB_MMIO_CTRL_FP16_BIT` (23) selects FPFP; bit 0 starts
the job. Owner/generation fields retain their existing locations. The added
kernel arguments are appended to preserve existing field offsets. Poll-only
mode has an explicit argument so a legacy QDIR value cannot select it in FPFP.
