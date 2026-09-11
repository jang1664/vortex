# Naive PSUM admission and response capacity

Status: confirmed by the user on 2026-09-11.

## Goal

Prevent accepted inputs from missing their one-shot PSUM prefetch and measure
the resulting FPINT GEMM cycles with xrt-vcs-sim.

## Agreed implementation

- Increase naive accumulator read slots from 8 to 16 and physical response
  assembly slots from 4 to 16. Retain the existing tagged response mechanism
  and the separate two-entry transport FIFO for this first iteration.
- Accept an input requiring PSUM only when the accumulator adapter can reserve
  its prefetch slot. Inputs not requiring PSUM bypass this read-capacity gate.
- Use the existing naive input_admission_ready connection. Capacity must be
  computed without depending on the acceptance pulse. Already accepted work
  continues draining while Input is stalled.
- Do not add multi-stage retry multiplexers or redesign response storage.
- Preserve improve behavior at RTL level; no synthesis-based cost comparison.

## Verification

Run fpint_gemm_ffn_hw_naive using the existing TH16/MXU16 config in a configured
build directory through ci/run_black.sh xrt-vcs-sim. Run M=4 and M=256 with
K=N=512, QBLK=32, QCOL, WT=0, one invocation each. Require application PASS and
record GEMM observer cycles and kernel core cycles. No fine reset tests.
Keep validation details here; the hardware-analysis latency document contains
only current cycle comparisons.
