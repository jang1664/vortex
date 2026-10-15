# Independent FPINT/FPFP geometry with exclusive jobs

Status: confirmed by the user, 2026-10-14.

Implement independently configured FPINT and FPFP naive arithmetic arrays in
one FPGA image. Execute only one job at a time across both formats, holding
the selected format and geometry until operand DMA, arithmetic, accumulator,
output DMA and outstanding transactions have drained. Reuse DMA, accumulator
and output infrastructure where possible. Separate FSM instances are allowed,
but duplicate complete nodes are not the intended solution.

Preserve legacy MXU parameters for FPINT; introduce FPFP-specific ROW/COL/WLOAD
parameters with backward-compatible defaults. FPFP ROW/COL are independent
powers of two subject to actual native-word, DMA tile, port and ACC limits.
Keep FPINT's existing supported geometry and behavior. Verify FPINT16x16 with
FPFP8x16, then a different output width such as FPFP8x8/16x8, including format
transitions. FPFP-only rectangular builds from the previous task must continue
to work. All four capability combinations remain legal.

FPFP is FP16 x FP16, FP32 products/reduction/partial sums, final FP16 output;
no transpose or quantization. Reuse row-major operands and 128-element macro
tiles. Different COL values must not alias partial sums or output locations.
Physical buses may use a shared envelope with format-specific valid lanes.
Keep separate arithmetic frontends/weight registers where this avoids a
larger change. No requirement for simultaneous execution.

Scope includes RTL parameter/control/transport/ACC changes, existing naive
regression app geometry/reference checks, focused verification and docs.
Preserve improve selected RTL and exact core/GEMM cycle counts; do not synthesize
improve. No PnR, commit or unrelated changes are requested.

Use rtl-improve and run-bb-common procedures: separate RTL and verification
agents, configured isolated builds, sourced configs, VCS unit tests and
ci/run_black.sh xrt-vcs-sim --perf 3. Start with small shapes, include tails,
subnormals, multi-tile reuse, format transitions and exclusive dispatch/drain
checks. Parent owns STATUS/results; agents coordinate through parent.

Baseline: current rectangular FPFP implementation, archived before edits in
build_fpfp_shared_baseline/source_before.tar.gz.

## Implementation decisions

- Public independent parameters: `FPFP_MXU_ROW`, `FPFP_MXU_COL`, and
  `FPFP_MXU_WLOAD_NUM`, each defaulting to its corresponding legacy `MXU_*`.
  Legacy parameters describe FPINT when both capabilities are present.
- Share the input and accumulator buses using the maximum geometry among
  enabled formats. Keep separate format-specific arithmetic and weight buffers.
  A single mode-aware FSM is sufficient; a second FSM is not required.
- Use physical-COL padded accumulator microtile slots. Address a slot as
  `nb * MT * physical_COL * 4 + row * physical_COL * 4`; `nb` is the
  microtile index, not its logical column coordinate. Only active columns
  are copied to the compact external result.
- Reserve C/PSUM scratch for `MT * (NT / min_enabled_COL) * physical_COL`
  elements, respectively FP16/FP32. For FPINT16x16 + FPFP8x8 with 128-element
  DMA tiles, scratch grows from 224 KiB to 320 KiB, within the chosen LMEM.
  Same-COL/single-format configurations retain the old capacity requirement.
- Internal ACC output already stages into an NT-stride LMEM buffer before
  writing compact DRAM. Padded LMEM ACC output must separately trim the last
  N microtile so an edge segment cannot overwrite the next output row.
- Physical LMEM port limits still apply. In particular, a shared COL32 ACC
  requires at least 32 ports under the current 64-bit port mapping; independent
  geometry does not remove that transport constraint.
- Add a regression-only queued-format mode: submit FPFP/FPINT/FPFP descriptors
  before waiting inside one kernel, verify pending overlap and all outputs.
  Separate host kernel launches are insufficient to establish job serialization.

Job completion means format-dependent internal transactions and queues have
retired. Existing external cache write ownership remains unchanged; the DMA
completion notification is not a new HBM physical-acknowledgement guarantee.

The default core job descriptor capacity remains one. `JOB_MMIO_NUM_ENTRIES`
can be overridden to four in the queued-job verification images. The app uses
that actual core capacity and rejects `--queued-formats` below three entries.
This override tests arbitration/exclusion; normal sequential dispatch requires
no increase in descriptor capacity.
