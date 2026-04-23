# 06 — Execute pipeline trim

## Target

- `hw/rtl/core/VX_execute.sv` and its children
  (`alu_unit`, `fpu_unit`, `lsu_unit`)
- `hw/rtl/core/fpu/*`

## Problem

The CPU execute pipeline consumes 22,833 LUTs total:
- `fpu_unit` = 11,762 (`fpu_fma` 6 k, `fpu_cvt` 1.6 k, `fpu_div` 1.7 k)
- `alu_unit` = 5,722 (`muldiv_unit` 4.3 k)
- `lsu_unit` = 4,020

Not large in absolute terms, but the `fpint_improve` branch uses an
instruction-stream model where the new GEMM node is **always on** and
handles the heavy compute; the RISC-V pipeline mostly runs control
code (job dispatch, DCR, sync).

If the hot path never exercises FPU FMA or serial_div in production
workloads, those units are dead silicon.

## Change

1. **Parameterize each execute unit out** with an `EXT_*_ENABLE`
   flag, gated similarly to how `EXT_TCU_ENABLE` gates the legacy
   WMMA TCU:
   - `EXT_FPU_ENABLE` (separate from TCU)
   - `EXT_MULDIV_ENABLE`
2. **Default to disabled** on the fpint_improve u55c config. Enable
   selectively only for configs that need them.
3. Remove unreachable opcode handling from the issue / commit stages
   when units are disabled (dead-code elimination in the decoder).

## Expected savings

- Disabling `fpu_div` + `fpu_fma` + `muldiv_unit`:
  **~12 k LUT**, plus a small drop in issue/commit muxing.
- Keeping integer ALU + LSU only: ~5 k – 6 k LUT for the CPU slice.

## Risks

- Software kernels must not reach a removed opcode. Add an illegal-
  instruction trap path and verify kernel binaries never emit those
  opcodes under the new config.
- Scope: the kernel/include/ math functions (`kernel/src/tinyprintf.c`,
  etc.) must avoid float.

## Verification

- Build kernel with `-msoft-float` (or equivalent) and inspect the
  generated asm for any FDIV/FMA remnants.
- `hw/unittest/core_top`, `core_tmem` with disabled flags.
