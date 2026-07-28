# Vortex-Local CVFPU Multiformat Slice Patch

## Goal

Keep the `third_party/cvfpu` submodule at its upstream pinned commit while retaining the Vortex-specific FPNEW INT64 conversion fix in the main Vortex repository.

## Scope

- Add `hw/rtl/fpu/patched_cvfpu/fpnew_opgroup_multifmt_slice.sv` based on the pinned upstream file.
- Restore `third_party/cvfpu/src/fpnew_opgroup_multifmt_slice.sv` to the pinned submodule version.
- Update every FPNEW-capable synthesis, simulation, and relevant unittest source list so the patched file replaces the upstream file exactly once.
- Update Synopsys source enumeration and any specialized GEMM synthesis/power scripts that perform CVFPU path substitution.
- Add or update focused source-selection tests where existing test infrastructure permits.

## Design Decisions

- Use the existing `hw/rtl/fpu/patched_cvfpu` shadow-copy convention already used by `fpnew_pkg.sv` and `fpnew_opgroup_block.sv`.
- Do not change the CVFPU submodule URL or pinned commit.
- Do not create a commit inside the CVFPU submodule.
- The patched file must record its upstream base and explain that the lane-width change is required by Vortex's cross-width scalar conversion policy.
- Build flows must never analyze both upstream and patched definitions of `fpnew_opgroup_multifmt_slice`.
- Preserve the previously verified INT64-aware CONV lane-width behavior.

## Constraints and Assumptions

- Preserve unrelated user changes and generated build outputs.
- Keep FPU_DSP and non-FPNEW flows unchanged.
- Source ordering must keep `fpnew_pkg` before dependent CVFPU modules.
- Verification must include source-list uniqueness and the Synopsys FPNEW top elaboration path.

## Final Agreed Spec

Status: **confirmed**

The user explicitly selected the Vortex-local patch-copy approach and requested all affected Makefiles/source lists be updated together.
