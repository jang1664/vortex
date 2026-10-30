# C4 FlashAttention regression

This regression exercises 128-dimensional W4A16/KV4 attention with 1–128
query rows and one or more 128-key tiles, including a partial final tile.
The target is the rev8 C4 TH16/MXU16 configuration. The generic `C4` FPGA
alias names an older configuration and must not be used as evidence for this target.

## Execution modes

The default legacy path writes GEMM intermediates to HBM. `-r` selects the
`GEMM_SRAM_FUSION` implementation: GEMM descriptors select LMEM output and
HBM/TMEM/LMEM input. Internal 32-byte/8-byte DMA transfers connect GEMM's TMEM
to LMEM before descriptor completion; SIMD executes online softmax through the
existing LMEM crossbar. All control uses the ordinary serialized GEMM MMIO
path; there is no separate fusion register bank. Scores, probabilities, and PV
partials share one LMEM workspace; the maximum, denominator, rescaling factor,
and output accumulator remain FP32 in LMEM. The final output is FP16 in HBM.

The resident schedule executes GEMM, DMA, and SIMD sequentially. It reads Q
once per query tile and advances K, V, scales, and zero points for each KV tile.
A larger score maximum rescales the previous output accumulator as well as
the denominator. Causal masking and invalid tail keys produce zero probability.

`-r -f` selects full FP32 QK/PV export (unified-MMIO capability revision3). Probabilities
and final output remain FP16. This avoids intermediate overflow when a finite
final answer requires scores or PV partials outside FP16 range. FP16 mode is
still available for bounded inputs. The opt-in `-s` cases are `extreme-logits`,
`alpha-underflow`, `pv-rounding`, `fp32-state`, `pv-overflow`, and `qk-overflow`.
The two overflow cases deliberately remain failures without `-f`.

`-d` explicitly exports final-tile intermediates for diagnosis. These exports
create HBM traffic and must be disabled for production traffic measurements.
`-P` is the legacy, single-tile PV-only diagnostic. `-R` compares the two host
references without opening a device.

## Build and simulation

From a Bash shell in a dedicated build directory configured with
`../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`:

```sh
source ../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh
make -C kernel
make -C runtime/stub
make -C tests/regression/flash_attn CXX=/usr/bin/g++
ci/run_black.sh xrt-vcs-sim --app flash_attn --args "-r -m 1 -n 128"
ci/run_black.sh xrt-vcs-sim --app flash_attn --args "-r -m 4 -n 256"
ci/run_black.sh xrt-vcs-sim --app flash_attn --args "-r -m 16 -n 257"
ci/run_black.sh xrt-vcs-sim --app flash_attn --args "-r -m 16 -n 384 -c -p 0"
```

The final causal example exercises fully masked later KV tiles. Other required
coverage includes M=8/128, diagnostic exports, and the legacy path. Commands
above describe the test procedure; they are not a claim that every case passed.
Use a separate configured directory for feature-off baseline tests.

## Numerical checks and traffic accounting

The tiled reference models quantized K/V, FP16 GEMM/P rounding, and FP32 online
state. An independent dense FP64 reference evaluates the same quantized inputs
without the tiled recurrence. Device output is checked against both; the dense
output limits are maximum absolute error 0.035 and relative L2 error 0.06.
Reference-only checks use 0.01 and 0.03 respectively. Nonfinite mismatches fail.
The deterministic input has distinct V tiles and later larger score maxima.

The kernel reports completed KV tiles, progress events, maximum updates, and
SRAM copy bytes derived from completed descriptors. For T KV tiles and padded
M rows, OBUF is initialized once and then reused. Each tile has QK output
copyback, PV input copy, and PV output copyback: `3*T+1` copies overall, with
no per-GEMM output prefill. The byte total is `(3*T+1)*M*128*2` for FP16
and `(5*T+2)*M*128*2` for FP32 output. These are software accounting values, not
independent DMA traffic counters. Internal DMA time is included in `gemm_wait`;
`sram_copy` measures the one-time OBUF initialization. Compare total/core cycles across ABI
versions rather than treating changed phase boundaries as a speedup.
These counters alone do not prove absence of intermediate HBM traffic; external
DMA address traces and the production path without `-d` are required.

ABI v3 uses 46 descriptor words rather than 44, and requires matching software
and RTL. The r5 hardware image uses ABI v2 and cannot run these new kernels.
See [unified MMIO](../../../docs/rtl/core/VX_gemm_unified_mmio.md).

## Implementation status

The no-output-prefill revision passes FP16/FP32 integrated node tests, including
publication, delayed physical LMEM commits, poisoned LMEM destinations, padding
reuse and actual DMA command-count assertions. Seven full-core attention cases
(FP16/FP32 multi-tile, FP32 tail/causal, legacy HBM and FP32 PV/QK overflow) pass.
Current cycle and copy-count comparisons are recorded in
[the corrected results](../../../agent-tasks/c4-unified-mmio/no-prefill/RESULTS.md).
Earlier serializer, 16-lane MMIO, 64 KiB early-return and scoped MMIO synthesis
evidence remains in [the initial report](../../../agent-tasks/c4-unified-mmio/RESULTS.md).
No ABI v3 FPGA image or routed Fmax has been measured. Hardware runs require a
matching new image and its explicit alias; the previous r5 resident image uses
ABI v2. Earlier architectural requirements and historical results remain in
`docs/future_optim/c4_flash_attention_tmem_lmem_dma_plan.md` and
`agent-tasks/c4-sram-flash-attention/STATUS.yaml`.

For FP32 numerical probes, use the same wrapper/config with arguments
`-r -f -m 1 -n 128 -s pv-overflow` and
`-r -f -m 1 -n 128 -s qk-overflow`. These are required device tests, not claims
of pass based only on host references. See the results document for current
verification status.
