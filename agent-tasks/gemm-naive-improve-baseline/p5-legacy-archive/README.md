# Retired naive implementation and white-box fixtures

These files are preserved unchanged for historical analysis and baseline
reproduction. They are outside the production RTL/unittest source tree.
The manifest records every original path and SHA256 before the move.

The old node/controller tests inspect the removed explicit FSM states,
packetizer and combined S/Z owner. Current functional coverage is carried by
actual xrt-vcs-sim numerical/lifecycle/shape captures and FSDB ownership checks;
controller metadata, Input contexts, independent S/Z, external DMA programming,
ACC/physical fences and node reset have dedicated current tests. The new external
DMA executor test retains its snapshot/allocator/poll/backpressure and QROW
geometry checks using direct stimulus signals instead of the legacy interface.

This archive is not an active test source manifest. Use the frozen P0 source
archive when reproducing the complete historical design. Restoring individual
files into the current RTL does not restore the old node architecture.
