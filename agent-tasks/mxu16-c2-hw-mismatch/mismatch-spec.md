# C2 hardware mismatch reproduction and repair

Status: Confirmed by the user's explicit request to reproduce and fix.

## Goal

Reproduce the C2 hardware fpint_gemm_ffn_hw mismatch in a smaller xrt-vcs-sim
case, identify the first incorrect data/control event, and implement a targeted
fix with failing-before/passing-after regression evidence.

## Reported failure

`ci/run_black.sh hw --fpga-bin temp --app fpint_gemm_ffn_hw --args "-m 256 -k 4096 -n 4096"`

The user reports 2048 mismatches at m=4. Confirm whether m=4 is a mismatch row
index rather than a matrix shape. The temp alias resolves to the C2 xclbin and
the primary MXU16 config with measured C2 timing cuts enabled.

## Scope and constraints

- Inspect application/kernel/layout/runtime and GEMM/DMA RTL as evidence directs.
- Reduce M/K/N while preserving the relevant multi-row, tile, or buffer rollover.
- Run RTL blackbox only through ci/run_black.sh xrt-vcs-sim in a configured build
  root after sourcing the MXU16 C2 config. Preserve source/config/binary identity.
- Preserve 64B HBM DMA, 32B local DMA/TMEM bank behavior and timing-cut intent.
- No speculative RTL change before locating a concrete failure mechanism.
- RTL implementation and verification are separated per rtl-improve skill.
- No FPGA hardware run, new P&R, commit, or unrelated cleanup in this request.

## Acceptance

- A reduced failing-before case and passing-after case, or an explicit statement
  if simulation cannot reproduce the hardware symptom.
- Focused regression for the identified bug and relevant shape/layout variants.
- Existing M4 K256 N256 C2 smoke remains passing.
- Record limitations: simulation PASS alone does not validate a new FPGA image.
