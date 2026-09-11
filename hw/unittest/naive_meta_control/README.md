# Integrated naive metadata control test

This VCS `new_tb` instantiates `VX_naive_gemm_control`: actual new FSM,
metadata controller and source generation join. Source the matching naive
configuration and use a configured XLEN64 build with `tools/verify_rtl.py`.
Optional `+M/+K/+N/+QROW/+WTRANS` select the workload.

The fixture models five finite executors with one owned command each and
different completion delays. It obeys writer-consume and Input admission
metadata, supplies source-read completion at modeled source acquisition,
emits consumes on modeled Input completion, and delays invocation notification
acceptance. It checks full producer command counts, command stability during
backpressure, source closure identity and retained invocation completion.

This is control-plane integration evidence. The modeled source acquisition and
terminal/LOAD completion do not prove actual memory response capture, bank
visibility, payload correctness, datapath overlap or numerical performance.
Real executors must replace the fixture at node integration. The new control
plane is not yet selected in the legacy naive node.

The initial fixture expected entry ID17 despite the configured four-bit entry
interface. Corrected the fixture to legal entry ID7; production code was
unchanged. Source-join iteration2 also removes an invalid completion-order
assumption discovered by inspecting the actual stream DMA response-owner path.
