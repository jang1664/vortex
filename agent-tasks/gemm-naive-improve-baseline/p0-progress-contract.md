# Independent S/Z directed progress contract

This freezes the finite stimulus and acceptance bounds required by plan.rev3
section 6.1 before implementing the independent engines. It is a test contract,
not evidence that the current combined quant engine satisfies that design.
The M4 performance and sustained-service gates remain separate and unchanged.

Run both QCOL and QROW at MXU16 and MXU32. Use four descriptor entries per
engine, eight response slots per engine, both register banks, and a fixed
N-fast compute stream. The final elaborated storage ledger must validate the
payload partition before integration.

## Fair service model

- Once source service is enabled, accept a continuously eligible request within
  16 cycles. Exercise all delay values from 0 through 15 across requests.
- Return every accepted physical lane request exactly once within 64 cycles.
  Reorder distinct tags and lanes, including youngest-before-oldest schedules,
  without changing response ownership. Never return a response before request
  acceptance or without reserved destination capacity.
- An install sink whose consume-generation fence is satisfied accepts a
  continuously valid beat within 16 cycles. Exercise 0, 1, 7, and 15-cycle
  backpressure; assert stable data, byte mask, bank, and owner while stalled.
- Deliberately withheld source service is released after 257 cycles. This
  exception applies only to the selected test engine before its release edge.
  It cannot excuse starvation of the other engine after release.
- Use deterministic schedules and record their sequence, rather than relying
  on an unbounded probabilistic fairness assumption.

## Cross-progress sequence and bounds

For each direction, first install generation 0 of the selected blocking
resource. Fill its descriptor queue and advance a later same-bank install to
its real, unsatisfied consume-generation fence. Hold the complementary
generation-0 source service until the release edge above. The complementary
descriptor must be the eligible head of its own queue; unrelated unsatisfied
dependencies cannot be hidden in front of it.

After release, require an actual complementary request within 64 cycles and
complete that descriptor's physical responses and enabled register installs
within 32,768 cycles. At least one complementary response capture and install
must occur while the original writer still waits for its consume fence. Merely
observing ready, descriptor enqueue, or a completion pulse is insufficient.
The blocked writer may resume only after the real matching GEMM consumption.

The conservative install bound covers a full MXU32 QROW command: at most
32 segments times 8 physical lanes, each charged 16 request-service plus
64 response cycles, plus 32 install stalls and control allowance. Even charging
these serially gives 256 * 80 + 32 * 16 + 128 = 21,120 cycles, below 32,768.
The actual executor may overlap them; this bound does not mandate serialization.

Require all four admitted descriptors of both engines and their reachable
consumers to retire within 262,144 cycles after release. Assert queue saturation
was actually reached, no response crossed engine ownership, every completion
was emitted once for its owner, and all source/install generation counts return
to their expected quiescent values. Repeat with scale and zero-point reversed.

A timeout, missing blocked-writer overlap, or numerical/payload mismatch fails
the test. Do not increase these bounds merely to accept a candidate. Any
proposed contract revision must explain the invalid original assumption and
retain the required independent progress; it cannot weaken the fixed latency
or service gates.
