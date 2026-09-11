# Current M4 physical completion and readiness evidence

All checks use the same final qlog-fixed M4 waveform, SHA256
2fdfb237ab4ffa5975e596be7e778bc863a782716d067505098a2702e17a349e.
The numerical capture and normalized endpoint comparison already pass.

- All32256 node PSUM/final writes match actual bank commits, including address,
  byte enables and data. Physical commit occurs3–16cycles after the node write.
- All4 terminal output-owner completions and4STORE retirements have no pending
  physical write; no PSUM/OBUF read overtakes a required producer write.
- All22528 reserved external LOAD words match DMA-origin physical bank commits.
  The independent pending count matches the actual fence at every sampled edge.
  The3-bit commit classifier is combinational from the same bank write edge;
  it does not add a register stage.
- All64 LOAD worker completions occur with physical writes still outstanding.
  The frontend completion is held until bank drain (up to22cycles). All4STORE
  frontend completions are also accounted for.
- Every one of68 external command completions follows exactly one owned DMA
  frontend handshake. Each T0/T1 version is published only after four distinct
  I/W/S/Z LOAD members have completed. All16 source generations pass; final
  T0/T1 values are8/8. Expected readiness is reconstructed from accepted command
  identities and completions, independently of the RTL T register values.

Evidence under p4-regression/naive-m4-final1:
physical-visibility-results.json, load-fence/result.json and
load-readiness/result.json, with retained transition snapshots and command records.

These are actual observed finite bank delays and descriptor completion ordering
in one required M4 run, combined with the separately retained directed physical
fence component tests. They do not claim arbitrary-stall integration coverage.
The current source-generation release join and final reset/cleanup audit still
need requirement-level reconciliation before full task completion.
