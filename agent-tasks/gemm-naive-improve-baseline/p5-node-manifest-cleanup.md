# Naive node integration source cleanup

Removed eight unused legacy files from the naive_node_integration compile
manifest: old controller/FSM and their interfaces, synchronization helper,
external DMA controller/interface, and packetizer. The actual node already uses
metadata control and independent executors, so this changes only its test source
list. No production RTL or functional behavior changed.

Fresh VCS compile/reset-quiescence tests pass at XLEN64/TH16/MXU16 and MXU32.
The retained compile logs confirm the obsolete modules are absent. Source
hashes remain stable. Evidence: p5-verification/node-manifest-iteration1/.
This remains an elaboration/reset smoke, not a numerical or physical-stall test.

The old gemm_node fixture still refers to the removed internal hierarchy and
must migrate before legacy helper files can be deleted from production RTL.
