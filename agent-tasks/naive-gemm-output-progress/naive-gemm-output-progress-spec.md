# Naive GEMM Output Progress MMIO Spec

Status: confirmed

## Goal

Expose a hardware-managed, read-only output-progress register for
`GEMM_NAIVE`, using the same descriptor register index as improve GEMM.
Software can poll the register to decide when a naive GEMM output DMA tile has
completed.

## Register ABI

- Both naive and improve GEMM descriptors contain 44 32-bit registers.
- Register 43 is `OUTPUT_PROGRESS` for both implementations.
- Registers 40 through 42 remain unused/reserved by naive GEMM.
- Descriptor allocation resets `OUTPUT_PROGRESS` to zero.
- Software writes to `OUTPUT_PROGRESS` are ignored.
- Hardware updates are accepted only while the descriptor is occupied and
  working.
- The final value remains readable after job retirement until the descriptor
  entry is allocated again.

## Naive Progress Semantics

- Progress increments once for each completed naive `OP_DMA_ST` command.
- A naive `OP_DMA_ST` transfers one output DMA tile from LMEM to global memory;
  its maximum logical extent is `GEMM_FSM_MT x GEMM_FSM_NT` (currently
  128 x 128).
- Completion means the cache-path DMA descriptor has retired. It does not
  guarantee that write-through traffic has reached HBM.
- This is intentionally weaker than improve GEMM, where progress advances only
  after all cache-bypass TMEM DMA write responses arrive.

## Scope

- Extend the naive GEMM descriptor register count and connect register 43 to
  the existing generic hardware-write path.
- Export naive external DMA store-completion and count it in the active GEMM
  controller.
- Keep improve GEMM behavior unchanged.
- Match the descriptor ABI and read-only behavior in SimX.
- Update naive/improve regression register-count constants to match the RTL.
- Add focused VCS coverage for reset, software-write rejection, progress
  increments, and retention.

## Constraints

- No cache fence or write-response tracking is added to the naive path.
- No interrupt is added; software continues to poll MMIO.
- Output progress is local to each core's descriptor entry.
