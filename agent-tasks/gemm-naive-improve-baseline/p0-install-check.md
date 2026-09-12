# P0 captured naive S/Z install check

The retained naive M4/K512/N512, th16/MXU16, QCOL/WTRANS0 baseline passes a
bit-exact source-to-install check using `fsdb_cli`. This is actual accepted RTL
payload evidence for this configuration; it does not complete the full P0
QROW/layout/tail/repeated-job test matrix.

| Check | Observed result |
|---|---:|
| Accepted scale register installs | 1,024 |
| Accepted zero-point register installs | 1,024 |
| Accepted FP16/int16 elements per resource | 16,384 |
| Unique logical tensor elements per resource | 8,192 |
| Register banks covered per resource | 0 and 1 |
| Work generations covered per resource | 1,024 |
| Actual physical 8-byte lane responses checked | 8,192 |
| Physical lane / install payload mismatches | 0 / 0 |
| Representative element, lane, beat, stale-command fault controls | 8/8 detected |
| Previous-group 8-byte lane substitution census | 7,680/7,680 detected; zero missed |

The census exercises all four physical lane positions and both resources
(3,840 substitutions each). It checks every captured install whose previous
quant-group payload is available, including both MXU halves of each QBLK32
group. Each substituted lane changes four elements and all four are detected.
These are post-capture payload-copy corruptions; no fault was injected into a
live RTL simulation. The expected tensor stays unchanged throughout.

## Evidence and reproduction

- Checker: `p0-install-check.py`.
- Raw signal transition snapshot: `p0-install-naive-m4-snapshot.json`.
- Accepted-command, physical-response, ownership and check results:
  `p0-install-naive-m4-results.json`.
- Waveform: `p0-baseline/naive-m4-retry1/wave.fsdb`.
- Run configuration/source hashes: neighboring `manifest.json`.

```sh
PYTHONPATH=tools python3 agent-tasks/gemm-naive-improve-baseline/p0-install-check.py
```

The checker verifies the waveform SHA256 before using cached transitions and
checks that the corrected vector header SHA256 matches the captured run
manifest. Unknown values on relevant accepted payloads invalidate the check.
It samples values strictly before each rising edge, excluding that edge's
nonblocking updates. Snapshot signal names and time units are retained.

Waveform SHA256: `8895227251bd619dc720ab1b93d8a42535f05630ed3fe866b02550c4c007f890`.
Vector source SHA256: `0826a0d8a17813ab57911186562c40fffb965c03ebd906fd0060b13a01bf6f97`.

## Independent expected-data and ownership mapping

The oracle uses the generation-zero, untagged logical tensor formula from
`tests/regression/fpint_gemm_ffn_hw/test_vectors.h`:

- Scale at `(kg,n)` is `1 + (kg % 17)/16 + (n % 7)/8`, encoded as IEEE FP16.
- Zero point is `((3*(kg % 7) + n % 7) % 7) - 3`, encoded as signed int16.

No observed install or response payload determines expected values. The
checker obtains original tensor base addresses from the accepted configuration,
then tracks actual accepted external DMA Scale/Zero descriptors (`rd=2/3`),
their source and destination addresses, row counts, and completion pulses.
A quant command must address exactly one completed LMEM tile load. With NT128,
its local source offset is split into a 256-byte row stride and column offset;
the original tensor uses a 1,024-byte row stride. This reconstructs `(kg,n)`.
The source mapping follows `VX_gemm_fsm_naive` tensor address functions and
`VX_gemm_dma_ctrl_naive` strided load mapping, not linear-copy assumptions.

An independent fixed N-fast work-sequence decode must agree with that mapping:
each 128-column N tile contains 256 microtiles, each KT128 tile contains 64,
and each MXU K step contains eight consecutive N slices. This check prevents
an early overwrite of a reused LMEM buffer from silently redefining an old
command's expected tensor generation to the newest load's contents.

Each quant command records source DMA identity, LMEM address, bank, work_seq,
logical row/column and acceptance edge. The accepted register write must match
that exact command and the node's retained opcode/bank/target. The checker also
checks the compute core's actual selected bank and valid/ready handshake.
Every supported QCOL install must write the full 32-byte mask. Missing, extra,
overlapping or unowned legacy combined-quant installs are rejected.

## Physical lanes and installed payload

`VX_mem_bus_split` maps wide byte slice `[8*lane +: 8]` to the corresponding
64-bit LSU lane. This geometry has four physical lanes for a 32-byte quant
beat. The checker captures every `sz_lane_mem_if[lane]` accepted request and
response, joins them by lane/tag, verifies the request byte address is the
owning quant source plus `8*lane`, and compares all four returned FP16/int16
words with the immutable expected tensor. That validates the physical lane
mapping directly from the captured interfaces.

At the destination it samples `scale_gemm_bus_if` / `zero_gemm_bus_if` data and
byte enables only when the corresponding `gemm_unit_v2_if` register-write
pulse is accepted. The core's byte-enable selected register writes occur on
that edge (`VX_gemm_compute_core.sv:1168-1194`). Zero data are checked in their
incoming signed-int16 encoding; the core internally negates them when storing
its zero-point representation. This revision does not independently read back
the post-edge register arrays or verify that internal negation implementation.

Fault controls retain command/address/generation metadata and replace only a
copy of the captured accepted payload with the previous group's captured
payload for the same columns. They exercise one 2-byte element, one 8-byte lane,
one 32-byte beat, and an entire stale command for each resource. In this QCOL
geometry a quant command produces exactly one full beat, so the beat and
whole-command data fault shapes coincide; they are not independent multi-beat
coverage. Their scope is explicitly recorded in the result JSON.

## Remaining coverage

- QROW strided scalar sources and masked install rows now have separate
  MXU16/MXU32 evidence in [p0-install-qrow.md](p0-install-qrow.md); this M4
  checker itself remains QCOL-only.
- WTRANS1 job configuration, tails and nonaligned legal dimensions.
- Repeated invocations with changed/poisoned source buffers and generation1+.
- New independent S/Z engines, backpressure/reordering and stale command owner
  tests after implementation; this checker currently enforces the legacy single
  combined install owner and must be adapted to separate ownership queues.
- Improve's different source-memory/descriptor layout.
- Live RTL fault injection and independent post-edge register-state checking.

Both register banks and their reuse across 1,024 microtile generations are
covered here, but that is not repeated-job generation coverage. The existing
whole-GEMM numerical pass and this direct payload check complement each other;
neither proves the pending independent-engine progress or latency gates.
