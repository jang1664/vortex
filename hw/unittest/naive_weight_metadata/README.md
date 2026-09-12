# Naive Weight metadata transport

Run with `tools/verify_rtl.py unittest --path BUILD/hw/unittest/naive_weight_metadata --sim vcs` from a configured XLEN64 build after sourcing the geometry config.

The actual Weight gather is instantiated with `NAIVE_METADATA=1`, command depth four, and the geometry's full microtile response-slot capacity. Eight one-group descriptors run in two waves without reset. Each descriptor uses a different stride, source address above 4GiB, writer target, destination and work ID. Lane responses are delayed until all four commands are admitted, returned highest slot first with lane skew, and checked against immutable address-derived data. The test requires an observed out-of-order source-completion event.

All four source captures must complete while installation is held. The writer fence then releases each command independently, with destination backpressure. Checks cover every physical lane address, every installed payload word, byte enables, writer-head metadata, source IDs exactly once, ordered install IDs, and terminal queue/assembly quiescence. A finite watchdog bounds progress. This transport test intentionally uses one group per descriptor to put four distinct source owners in the response slots simultaneously. Full microtile execution and actual node numeric behavior require additional executor/integration tests.

Bring-up: the initial new Makefile omitted its companion `vcs.mk`; this was supplied. The first simulation fixture updated the ready-pattern cycle using a blocking assignment at the sampling edge, causing DUT/monitor handshake disagreement. Changed only the fixture cycle update to nonblocking. The address checks and DUT were unchanged; both geometries then passed.
