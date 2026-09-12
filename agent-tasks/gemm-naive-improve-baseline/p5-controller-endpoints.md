# Metadata controller endpoint regression

All12 VCS cases pass at XLEN64/TH16, MXU16 and MXU32: completion delivery
D=0/1/17 crossed with modeled STORE execution delays0/19. The actual naive
metadata FSM, controller and source-generation join execute a complete M3K64N64
command stream. Testbench executors retain their command ownership until their
modeled completions; the DUT completion state is never forced.

An independent pre-edge scoreboard records cfg acceptance, final STORE
retirement, first done-valid and done handshake. Every observer metric and store
count matches those independently recorded edges. Done remains stable while
backpressured and is forbidden while an executor remains busy. D changes only
delivery/handshake latency; STORE delay19 shifts store and first-valid by exactly19
at both geometries. Controller-only finalize is2cycles; the full node's measured
3cycle finalize includes its registered STORE progress pulse.

Evidence: p5-verification/controller-endpoints-iteration1/{summary.json,
endpoint-comparison.json,source-hashes.json} and per-case command/compile/sim logs.
All12 compile logs include XLEN_64; recorded RTL/test source hashes are stable.

This is real control-plane verification with modeled executor delays, not
physical bank/HBM stall injection. Physical visibility remains a separate gate.
