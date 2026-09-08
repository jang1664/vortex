# Archived reference ABI inspection

Inspected 2026-09-08 14:57. This is a static compatibility check, not a claim
that the current program has executed on the archived design or on hardware.
The reference artifact is the `temp` candidate in `reference-evidence.md`.

## Established static matches

- Archived `src/VX_types.vh` and current `hw/rtl/VX_types.vh` are byte-identical:
  SHA-256 `10378ea4fba29737dda277cd41c3a81cdb955738d6cd05744f7f7900af8a92ef`.
  Thus the shared DCR/CSR and instruction constants in this header have not
  drifted. This does not prove decoder implementation equivalence.
- Runtime `runtime/xrt/vortex.cpp` uses control at 0x00, device capabilities at
  0x10/0x14, ISA capabilities at 0x18/0x1c and DCR writes at 0x20/0x24.
  Archived `src/VX_afu_ctrl.sv` defines those same addresses. Startup address
  halves use DCR 0x001/0x002 and argument halves 0x003/0x004, from the matching
  types header. The archived control block implements reset at control bit 4.
- The archived source manifest selects XLEN_64, EXT_D_DISABLE,
  EXT_ZFH_ENABLE, one cluster/core, 16 threads, eight DMA channels and
  JOB_MMIO_DMA_DESC_ONE_LANE. The current smoke program's kernel library build
  records `-march=rv64imaf_zfh -mabi=lp64f` with those same explicit defines in
  `build_hbm_reference/current_rtl_document_vecadd.log`.
- The archive exposes 34-bit global addresses and 32 physical memory banks;
  the current reference model manifest uses the same geometry. This is distinct
  from the number of kernel AXI ports.

## Confirmed source drift that must remain isolated

`diff -u <artifact>/src/VX_config.vh hw/rtl/VX_config.vh` shows two functional
default changes, besides comments:

| Define | Archived default | Current default |
| --- | --- | --- |
| GEMM_TIMING_REG_ACC_FREE | 0 | GEMM_TIMING_CUTS |
| GEMM_TIMING_REG_DMA_DEPS | 0 | GEMM_TIMING_CUTS |

The candidate has GEMM_TIMING_CUTS=1. Using current RTL/headers would therefore
change reference pipeline timing even with an apparently matching config name.
The temporary reference Makefile generates C++ headers from archived
`VX_config.vh` and `VX_types.vh`; its vlogan audit confirms archived RTL includes.
Do not copy current build headers into that stage. The current-RTL smoke result
must not be substituted for an archived-reference baseline.

## Remaining gates

- Read capability words from the actual archived VCS and hardware sessions and
  decode/check them against the expected ISA, threads, warps and memory geometry.
- Run the same hashed device program and inputs on archived VCS and hardware.
  The current smoke binary is recorded in `current-rtl-results.json`, but its
  success on current RTL alone does not establish historical compatibility.
- For DMA/GEMM workloads, verify descriptor layout and opcode implementations,
  not merely the common types header and compile flags.
- Do not enable scope/debug extensions absent from the archived control block.
  MMIO scope at 0x28 is conditional in the runtime; it is not part of the basic
  smoke compatibility established above.
- Recheck linked platform/runtime clock and memory allocation metadata on the
  board. Static xclbin metadata is not actual runtime clock reporting.

The normal blackbox script's message "kernel ABI consistency check" means it
rebuilds/checks the current kernel library. It is not an archived-design ABI
validator. Historical launch still awaits the requested wrapper run-only choice.
