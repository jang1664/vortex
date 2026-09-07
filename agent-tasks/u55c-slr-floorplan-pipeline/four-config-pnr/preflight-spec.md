# Four-config SLR preflight and TH32 physical builds

Status: confirmed by the user on 2026-09-07.

## Goal and scope

Prepare the TH16/TH32 x t4/t8 MXU32 W4 big-memory profiles for source-based
U55C implementation. Validate all four with xrt-vcs-sim, extend full-SLR
floorplan validation to t4 without weakening ownership or crossing checks,
then launch normal source-based P&R for TH32/t4 and TH32/t8 only.

## Agreed constraints

- t4/t8 specify equal TMEM bank, HBM port and DMA channel counts.
- Preserve 512 KiB TMEM capacity, MXU32x32, WLOAD4, eight response slots,
  existing timing-cut defaults, and explicit SLR RTL transports.
- Keep SLR0 memory/HBM DMA, SLR1 local DMA/control/ACC, SLR2 MXU.
- Use full-SLR pblocks only; no DMA clock-region assignments or DCP retries.
- Preserve the existing MXU16/16-TMEM/8-DMA paired profile in the hook.
- Derive and validate expected TMEM/DMA/HBM/MXU geometry from CONFIGS.
- Use configured isolated builds and source the selected config before tests
  or synthesis. RTL blackbox mode is xrt-vcs-sim via ci/run_black.sh.
- Test smoke, overlap, QROW/transpose and partial tails for each profile;
  record functional results and host cycles without inventing a baseline.
- Extend Tcl/Makefile fixture coverage. Physical hook success is established
  only by actual implementation, not by mock Tcl tests.
- Launch TH32 builds with Explore/AlternateCLBRouting, ultrathreads disabled,
  100 MHz and congestion fail-fast disabled. Do not launch TH16 P&R.
- No commit, push, or unrelated cleanup is requested.

## Work sequence

1. Generalize strict geometry checks and update fixtures and configs.
2. Configure isolated builds, run deterministic hook tests and four-profile
   xrt-vcs-sim functional coverage; repair in-scope failures before launch.
3. Freeze source/config evidence, check tools/platform/resources and launch
   two separately logged TH32 source-based builds with unique postfixes.
4. Record build identifiers, output paths and observed completion status;
   distinguish successful launch from successful P&R/timing closure.
