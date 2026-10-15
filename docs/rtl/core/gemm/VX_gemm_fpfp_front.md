# Naive FP16 operand frontend

`VX_gemm_fpfp_front` is instantiated only when `GEMM_NAIVE_FP16_ENABLE`
is present. It provides a second arithmetic frontend within the existing
naive node. The existing `VX_gemm_compute_core` accumulator transaction
queue, read-response join, RAW forwarding, accumulator backends, and final
FP32-to-FP16 output conversion remain shared.

## Configuration and job selection

- `GEMM_NAIVE_ENABLE`: FP16 x INT4 support.
- `GEMM_NAIVE_FP16_ENABLE`: FP16 x FP16 support.
- `MXU_ROW`, `MXU_COL`, `MXU_WLOAD_NUM`: existing FPINT geometry.
- `FPFP_MXU_ROW`, `FPFP_MXU_COL`, `FPFP_MXU_WLOAD_NUM`: independent
  FPFP geometry, each defaulting to its corresponding existing parameter.
  A dual image can therefore contain FPINT16x16 and FPFP8x16 or FPFP8x8.
- Legacy `GEMM_NAIVE` selects FPINT; either new capability enables the
  internal shared naive-node presence guard.
- CONTROL bit 23 selects FPFP in a dual-format build. Bits 0--22 retain
  their allocator/start interpretation. Single-format builds reject an
  unsupported request in the regression software and RTL assertions.
- A job retains its selected mode until all source reads, computation,
  writeback, and output DMA have drained.

FPFP uses row-major FP16 A `[M,K]`, B `[K,N]`, and output C `[M,N]`.
WTRANS, QDIR, and QBLK do not affect FPFP addresses or arithmetic. Only
Input and Weight participate in external DMA readiness and source-buffer
release; no synthetic Scale/Zero completion is generated.

## Arithmetic and ownership

Each admitted FPFP input slice has `FPFP_MXU_ROW` FP16 elements. Corrected half-to-
single widening feeds FP32 multipliers. Each of `FPFP_MXU_COL` columns reduces
products using an adjacent-pair FP32 tree. The core adds the resulting
FP32 vector to its FP32 partial sum. Narrowing occurs only on final output.

An admission reserves a result slot until the common post-processing
boundary accepts that result. Metadata is stored in admission order,
independently of operator latency. Arithmetic outputs remain ordered and
never stall; the reserved result FIFO absorbs downstream backpressure.
The multiplier admission checks operand readiness, and assertions check
adder readiness, cross-column valid agreement, and ownership bounds.

The two weight banks reuse `VX_gemm_weight_regs_v1` with 16-bit elements
and compile-time row-only loading. The unused transpose path is absent,
so different row and column counts never index a column payload as a row.
A bank's final input consumption releases
its writer fence only after the multiplier inputs have captured the old
weights. FPINT has a separate bank and frontend in a dual-format build.

## Weight transport

`FPFP_MXU_WLOAD_NUM` controls the number of FP16 rows gathered per group.
For a 16x16 array, one row is 32 bytes: values 1 and 4 therefore produce
32-byte and 128-byte groups, respectively. Each physical LMEM request is
still 8 bytes, and the physical LMEM port count is unchanged. The existing
gather descriptor ownership, response assembly, and completion path are
parameterized by weight width. Grouping must fit the configured port count.

A 128-column FP16 macro tile has a 256-byte row stride. Multiple rows can
alias the same LMEM banks, so four-row grouping does not imply four times
the achieved bandwidth. Compare measured cycles and bank stalls.

## Rectangular geometry

`FPFP_MXU_ROW` is the K reduction width and `FPFP_MXU_COL` is the N
output width. They are independent positive powers of two in single-format
and dual-format images. The FSM advances K by the selected ROW and N by
the selected COL. Neither FPFP dimension is implicitly the SIMT thread
count. FPINT retains its existing square 16/32 geometry restriction.

`JOB_MMIO_NUM_ENTRIES` retains its default of one; queued-job verification
sets it to four. Four 44-register GEMM descriptors and the allocation word
fit the existing MMIO window. Larger capacities require a separate address
window review.

Only one whole job executes at a time. Queued MMIO descriptors can request
different formats, but the active format, dimensions, and entry stay locked
until operand engines, compute/ACC transactions, final stores and physical
LMEM write queues have drained. The existing descriptor ownership and
completion protocol remains authoritative. DMA descriptor retirement does
not claim a separate HBM acknowledgement beyond the existing cache contract.

The physical input width is the maximum enabled ROW; the native-beat DMA
selects the active input slice into low lanes. Frontend weight banks retain
their own dimensions/load grouping, sharing the existing physical LMEM port
arbiter. One result/ACC transaction pipeline and one output transport serve
both arithmetic frontends.

The physical ACC width is the maximum enabled COL. A narrower result is
zero-extended into a physical vector. Microtile `nb`, row `m` uses byte
address `(nb * MT + m) * physical_COL * 4`. Using the logical N offset with
only a wider row stride would overlap adjacent microtiles, so the complete
microtile slot is padded. Storage required for one tile is
`MT * (NT / minimum_enabled_COL) * physical_COL * 4` bytes.

Internal ACC output uses the existing gather DMA to compact each logical
microtile into the existing NT-stride LMEM staging buffer. Different logical
column widths select the existing misaligned DMA implementation so partial
physical beats preserve adjacent output columns. The final lane splitter
still issues every physical lane, including zero-byte-enable lanes, matching
the existing write reservation/commit accounting. The LMEM ACC
backend keeps partial sums and final FP16 output in padded microtile slots;
its existing external DMA executor emits one descriptor per logical
microtile, trimming the last segment to valid N. It publishes one STORE
completion for the entire macro tile. No second ACC or output datapath is
introduced. Software must reserve the corresponding padded PSUM and C
scratch capacities.

The complete node additionally requires:

- ROW divides the 128-element K DMA tile; COL divides the 128-element N tile.
- Input (`2*ROW` bytes), each weight row (`2*COL` bytes), and output
  (`2*COL` bytes) contain whole 8-byte native LMEM words. Thus ROW/COL 1 or
  2 cannot use the current node interfaces. The standalone arithmetic
  frontend supports ROW=1 (one multiplier, no reduction adders).
- Input/output lane counts fit the physical LMEM ports. The existing
  accumulator transport additionally requires at least `2*(4*COL/8)`
  power-of-two LMEM ports. This constraint is preserved even when selecting
  internal ACC memory.
- WLOAD is positive, divides ROW, and its `2*COL*WLOAD/8` weight request
  lanes fit the physical LMEM ports. No ports are added automatically.
- The existing INT-tree `MXU_COL_TILE` remains associated with legacy
  `MXU_COL`; it does not define the FPFP frontend's number of columns.
- Internal ACC capacity holds the padded FP32 tile described above. Equal
  widths require 64 KiB; FPINT COL16 plus FPFP COL8 requires 128 KiB.
  The existing bank mapping derives from the shared physical width.

For example, with 16 LMEM ports, 8x16 has a 16-byte input and 32-byte output;
WLOAD 1/4 gathers 32/128 bytes. Conversely, 16x8 has a 32-byte input and a
16-byte output; WLOAD 1 gathers 16 bytes. Existing address generators,
metadata ownership, and accumulation transactions serve both orientations.
Padding belongs only to internal physical slots; DRAM matrices remain compact
row-major matrices. No new transpose mode is introduced.

## Verification

The original validated geometry is **TH16 / MXU16** with the configured
Xilinx FP32 operators in VCS. Rectangular validation results are tracked
separately in `agent-tasks/naive-fpfp-rect`; independent dual-format
geometry and queued-job verification is tracked in `agent-tasks/naive-fpfp-shared`. Structural parameter support is
not a claim that every legal geometry or other FP backends have passed
integration tests. No new FPGA place-and-route result is
claimed. SLR placement/floorplanning for the new frontend is not validated.
Multi-tile tests exercise nonzero K/N macro-tile offsets and differing
DRAM/LMEM row strides. Nonzero job-level M_START/N_START partition offsets
have not been tested by the single-core regression invocation.

`hw/unittest/gemm_fpfp_front` uses actual Xilinx latency-one FP32 operators
in VCS. It checks both weight banks, normal and smallest-subnormal inputs,
metadata order, a full result FIFO, and variable downstream stalls.
The extended `fpint_gemm_ffn_hw_naive` regression provides the full FSM,
DMA, accumulator, and format-transition checks. Verification results and
the WLOAD 1/4 comparison are recorded under `agent-tasks/naive-fpfp`.
