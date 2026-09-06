# Confirmed SLR pipeline implementation specification

Confirmed by the user's request to execute `plan.md` on 2026-09-05.

- Goal: legal source-built U55C routing and setup/hold closure at 100 MHz.
- Baseline: merge `5d8fc73fbaae62cb5cebbd3320b5e8dc5ef0836e`, primary TH16,
  MXU32, W4 configuration named in the plan.
- Scope: explicit SLR crossing transport in TMEM, GEMM DMA control and MXU;
  three disjoint full-SLR placement groups and physical validation scripts.
- Decisions: memory/HBM DMA in SLR0; local DMA, controller and ACC in SLR1;
  complete MXU in SLR2. Keep eight response slots and RAM payload storage.
- Constraints: preserve local same-edge prepared DMA chaining, ordered write
  commit, weight installation/use/release ordering, and existing ACC hazards.
  Dedicated TX/RX registers must connect directly across each boundary.
  Existing synchronous resets on boundary FFs must map to dedicated reset
  pins (`EXTRACT_RESET="yes"`), not combinational reset masking on RX D.
  This is an implementation-mapping requirement, not a change to reset
  semantics, payload reset coverage or transport latency. See
  [AMD UG901 EXTRACT_RESET (2025.1)](https://docs.amd.com/r/2025.1-English/ug901-vivado-synthesis/EXTRACT_RESET).
- Verification: configured/source-matched VCS unit tests and W4 xrt-vcs-sim,
  with each primary case within 2% of its same-profile baseline; focused
  MXU16 compatibility. Only after functional gates pass, one source-based
  implementation; no DCP retry, no false-path workaround.
- Detailed boundary contracts and acceptance criteria: `plan.md`.
