# P1 physical commit implementation verification request

- Iteration: 3; test_type: new_tb; sim_tool: vcs.
- Test path:hw/unittest/naive_lmem_commit, absolute configured build path.
- Source naive th16/MXU16 configuration before configuration/build/test.
- Repeat at th16/MXU32 with ROW/COL/COL_TILE/LMEM_NUM_PORTS=32.
- Run through tools/verify_rtl.py; main coordinates verification/full blackbox.
- New RTL helpers:VX_naive_lmem_commit_decode and VX_naive_dma_write_fence.
- Modified production paths:VX_local_mem, VX_mem_unit, VX_core, VX_dma_node,
  and physical write-commit ports/counting in VX_gemm_node_naive only.
- No common command type, controller, FSM, or mem_bus_split changes by this
  implementation subtask.

Three-bit combinational bank events use kind00/01/10/11 for none/PSUM/final/DMA
plus PSUM set. No new tag or payload register. The DMA fence has exactly12-bit
pending and1-bit current-wide reservation, cap4095; completion retains existing
worker ownership. Legacy GEMM write/set counters now retire at bank commit;
empty/producer closure rejects same-edge reservations and held wide writes.

Directed coverage and limits are in the unittest README. No verification pass
is claimed until the deterministic verifier completes. Existing standalone
naive-node or DMA-node testbenches must connect the new commit input to actual
modeled bank writes; there is deliberately no fallback to node acceptance.
Full-core elaboration at both geometries and unchanged improve elaboration are
required in addition to this directed suite. End-to-end blackboxes are scheduled
by the parent after coordination with the other P1 subtask.

## Iteration 2 delta

Iteration 1 failed compilation at both MXU16 and MXU32 because the naive
commit decoder generate block referenced `per_bank_req_addr` before its
declaration in `VX_local_mem.sv`. Move that entire unchanged generate block
after all bank request declarations, including `per_bank_req_ready`. This is
a declaration-order fix only; classification, accounting, and test sources
are unchanged. No simulation started in iteration 1.

Rerun both geometries through the independent deterministic verifier and
capture reports under `p1-verification/physical-iteration2`. No compilation
or simulation result is claimed by the implementation agent.

## Iteration 3 root cause and request

Iteration 2 compiled but failed the origin/set assertion at both geometries.
The fixture Makefile included configured `config.mk` (`XLEN ?= 64`) but did
not pass `XLEN_64` to VCS. Both captured compile commands lack an XLEN define.
`VX_config.vh` defaults to `XLEN_32` when neither define is present, so the
production decoder elaborated `LSU_WORD_SIZE=4`, while this fixture instantiated
an 8-byte RAM and chose the second PSUM set address using 8-byte words.
At MXU16 the fixture selected word address 8, but the misconfigured decoder
read set bit 4; at MXU32 it selected word address 16 but read set bit 5.
Both second-set writes therefore decode as set 0. The failure log prints the
assertion expression, not actual counter values; it does not establish that
all four counters were 1.

Pass `+define+XLEN_$(XLEN)` from the configured Makefile. Add a time-zero
8-byte LSU geometry assertion and report all four counter values on any future
classification failure. Keep the original classification expectations and
all directed cases unchanged. No production RTL change is needed.

Reconfigure the MXU16 and MXU32 verification builds to refresh their Makefiles,
then rerun the same independent VCS suite via `tools/verify_rtl.py`. Capture
under `p1-verification/physical-iteration3`. Implementation inspection only;
no independent verification or PASS is claimed here.
