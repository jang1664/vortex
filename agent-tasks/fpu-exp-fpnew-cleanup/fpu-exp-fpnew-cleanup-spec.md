# FPNEW exp cleanup spec

Status: confirmed

## Goal

Refactor `VX_fpu_exp_fpnew.sv` so the fpnew exp path is structurally close to the DSP exp path. The module should keep the same FPU exp interface and serializer-style scheduling, but it should use local fpnew-backed arithmetic wrappers for FP32 add/mul work instead of directly instantiating a bespoke multi-stage `fpnew_top` pipeline.

## Scope

- `hw/rtl/fpu/VX_fpu_exp_fpnew.sv`
- `hw/syn/synopsys/run_syn_vortex_axi.py`
- Focused verification scripts or task-local checks under `agent-tasks/fpu-exp-fpnew-cleanup/`

## Design Decisions

- Keep `VX_fpu_exp_fpnew` enabled only under `FPU_FPNEW`.
- Keep the external ready/valid and `VX_pe_serializer` structure aligned with `VX_fpu_exp.sv`.
- For fpnew-backed arithmetic, add small local FP32 add/mul wrappers that instantiate `fpnew_top` for a single operation and expose AXI-style valid/ready ports like the existing GEMM add/mul wrappers.
- Avoid direct algorithm-stage `fpnew_top` instantiation in the exp datapath.
- Enable `VX_ENABLE_HW_EXPF` in the Synopsys top-level synthesis script so Synopsys actually synthesizes the hardware exp path when `SYNOPSYS` selects `FPU_FPNEW`.

## Constraints

- Do not widen the cleanup into unrelated FPU, TCU, or GEMM refactors.
- Preserve existing public module names and interfaces.
- Use compile/smoke verification before reporting completion.
