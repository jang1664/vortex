# Optional FP32 resident export: ABI revision 2

This extension executes the conditional numerical requirement in section 6 of
the agreed plan. FP16 remains an available resident output format. The new mode
preserves full FP32 ACC values for both QK scores and PV partials while retaining
the same 32-byte TMEM/LMEM DMA and the existing bank routes.

## Triggering evidence

The opt-in `pv-overflow` case has Q=0 and V=7*128=896. Its unnormalized
128-key PV partial is 114688, outside FP16, although normalized output896 is
finite and exactly representable. The `qk-overflow` case has Q=128, K=7,
and scale1: raw dot114688 overflows FP16 before attention scaling although the
dense output0.4375 is finite. The original references fail these cases; they
are not accepted by widening tolerances or treating infinity as success.

The eleven decoder fixtures have observed maximum rawQK88.375 and a
conservative PV bound800.625. These observations do not establish general
support bounds. The standalone stress cases exercise the additional mode.

## Hardware and software contract

- Capability changes from `0x53465201` to `0x53465202`.
- Extension flags bit0 resident A, bit1 resident output, bit2 FP32 output.
  Valid FP32 combinations are6/7;4/5 must be rejected. Legacy descriptor
  layout remains44words and all feature-off declarations/ports remain unchanged.
- FP16 output uses the existing compressed ACC byte address. FP32 output uses
  the full ACC byte address, with two consecutive32-byte reads per16-column row.
  The first beat contains columns0–7; the second columns8–15.
- C-tiled element order is unchanged. The output microtile pitch is
  `align8(original_M)*16*4`; only `target_M*16*4` active bytes are copied.
  Software initializes padding and owns the entire padded output range.
- SRAM copy completion and resident completion still require physical writes
  and drained responses. Format is scoped to each invocation/request and must
  not survive into a later FP16 or legacy job.
- Shared software args append `output_fp32`; standalone `-r -f` enables it.
  Q/K/V formats and FP16 probability/final-output formats do not change.
- LMEM score/partial storage is FP32. Probability storage is a distinct FP16
  allocation: in-place32-to16-bit compaction is unsafe across concurrent rows.
  FP16 mode retains the original shared workspace.

At128rows, TMEM allocation grows from120KiB to152KiB. LMEM needs64KiB
score/partial workspace +32KiB probabilities +64KiB FP32 accumulator +1.5KiB
row state, below the reserved lower512KiB arena. HBM runtime stacks are
separate and still contribute traffic; this feature does not remove spills.

For T KV tiles, O=`padded_M*128*output_element_bytes`, P=`padded_M*128*2`:
copy bytes are `(2*O+P)*T+O`, and command count is `3*T+1`. The extra O
is the initial output padding clear. FP32 mode increases SRAM traffic.

## Evidence and remaining gates

CPU reference cases pass for both former overflows with FP32 mode and retain
the original FP16 failures as negative evidence. Host/device build passed.
Logs are under `logs/numerical/` and `logs/flash_fp32_build.log`.
RTL M1/M4/M16 and full-core normal/publication, PV-overflow and QK-overflow cases now pass. Broader matrix and hardware gates remain pending; see `fp32-export-test-request.md` and STATUS.yaml.

The first FPGA build was stopped after confirming these failures because it
lacks revision2. Its extracted source and partial artifacts remain available;
`logs/fpga_r1_superseded.json` records the reason and process tree. A new image
must be built after revision2 passes verification. No old binary or rev8 alias
was replaced.
