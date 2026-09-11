# P0 captured QROW S/Z install and repeated-generation checks

Actual retained naive QROW/WTRANS1 captures pass exact accepted-payload checks
for both th16/MXU16 and th16/MXU32. The test shape is M3/K64/N64, QBLK32,
`--tagged -r 3`. The repeated jobs have RTL resets between them; these results
are not evidence of a no-reset lifecycle.

| Evidence | MXU16 | MXU32 |
|---|---:|---:|
| Quant wide beat | 32 B | 64 B |
| Native physical lane size | 8 B | 8 B |
| Reset epochs / host data generations | 1,2,3 / 0,1,2 | 1,2,3 / 0,1,2 |
| S/Z commands over all three jobs | 96 | 24 |
| Actual masked register installs | 1,536 | 768 |
| Useful FP16/int16 elements checked at install | 1,536 | 768 |
| Unique tensor elements per job per resource | 128 | 128 |
| Tagged physical lane responses correlated | 6,144 | 6,144 |
| Physical responses with nonzero source byte mask | 1,536 | 768 |
| Distinct installed scalar masks | 16 | 32 |
| Register banks | 0 and 1 | 0 and 1 |
| Install / physical enabled-payload mismatches | 0 / 0 | 0 / 0 |
| Representative corruption controls detected | 10 / 10 | 10 / 10 |
| Entire previous-job stale commands detected | 64 / 64 | 16 / 16 |
| Immediately previous same-job commands: detectable / equivalent | 42 / 48 | 18 / 0 |

Each stale previous-job command is checked across **every** accepted masked
segment: 16 segments on MXU16, 32 on MXU32. Every active element differs and is
detected. This tests complete multi-segment QROW commands, unlike the QCOL
case where one command is one full beat.

## Files and reproduction

Additional QROW/WTRANS0 coverage uses the retained M1/K64/N64 tagged two-job
capture `p0-baseline/naive-qrow-wt0-tagged-repeat2`. The generalized checker
requires a single M microtile, the same K64/N64 physical layout, at least two
tagged reset-separated generations, and checks the actual WTRANS field against
the manifest. It verified 1,024 masked installs, 4,096 physical lane responses,
64 commands, and 128 unique tensor elements per job/resource with zero
mismatches. All ten representative controls and 32 previous-job stale commands
were detected. The 32 same-group equivalent predecessor commands are explicitly
excluded from detected-fault counts. Results are
`p0-install-naive-qrow-wt0-repeat2-{snapshot,results}.json`. The original
MXU16/WTRANS1 capture was replayed successfully after generalization.

```sh
PYTHONPATH=tools python3 agent-tasks/gemm-naive-improve-baseline/p0-install-qrow.py --run agent-tasks/gemm-naive-improve-baseline/p0-baseline/naive-qrow-wt0-tagged-repeat2 --prefix agent-tasks/gemm-naive-improve-baseline/p0-install-naive-qrow-wt0-repeat2
```

`p0-install-qrow.py` extends the task-local analysis using the stable helpers in
`p0-install-check.py`. It does not change any RTL or simulator stimulus.

```sh
PYTHONPATH=tools python3 agent-tasks/gemm-naive-improve-baseline/p0-install-qrow.py
PYTHONPATH=tools python3 agent-tasks/gemm-naive-improve-baseline/p0-install-qrow.py --run agent-tasks/gemm-naive-improve-baseline/p0-baseline/naive32-qrow-wt1-tagged-repeat3 --prefix agent-tasks/gemm-naive-improve-baseline/p0-install-naive32-qrow-repeat3
```

The input captures are `p0-baseline/naive-qrow-wt1-tagged-repeat3` and
`p0-baseline/naive32-qrow-wt1-tagged-repeat3`. The checker requires a finalized
manifest with returncode 0 and a `PASSED` wrapper result before snapshotting.
It verifies the waveform hash for cached snapshots, records the manifest hash,
and requires the current vector header and host repeated-generation loop to
match the captured source hashes. MXU32 comes from the hash-matched default
`VX_config.vh` when the captured config has no explicit MXU_COL override.

Raw transition snapshots and detailed command/physical/install records are:

- `p0-install-naive-qrow-repeat3-snapshot.json`
- `p0-install-naive-qrow-repeat3-results.json`
- `p0-install-naive32-qrow-repeat3-snapshot.json`
- `p0-install-naive32-qrow-repeat3-results.json`

MXU16 waveform SHA256: `abd499ad78a315953f5c49ea13a9247d9f54df0eef9df3ef0c392111a06432db`.
MXU32 waveform SHA256: `fa2a8cbe29f621d376becf4d29168d2768e3d487fcb531f34c6bd89656e24be7`.

The original M4 QCOL checker was rerun after adding exact one-time command
sequence coverage checks and still passes. It retains its own captured data,
results, and fault census.

## QROW physical mapping and independent oracle

A QROW tensor is `[K, ceil(N/QBLK)]`, so this shape has 64 rows and two quant
columns. The immutable tensor formula uses host data generation g:

- Scale: `1 + ((k % 17 + g % 17) % 17)/16 + (ng % 7)/8`, encoded as FP16.
- Zero: `((3*(k % 7) + ng % 7 + g % 7) % 7) - 3`, encoded as signed int16.

Tagged initialization affects A/W identity selection; S/Z still follow these
explicit generation-dependent formulas. No observed payload determines the
expected tensor. Each job covers all 128 unique S and all 128 unique Z elements.

For NT128/QBLK32 the LMEM quant tile has an 8-byte row stride; the source DRAM
tensor has a 4-byte row stride. The checker joins the accepted external S/Z load
descriptor and its completion to each quant source address, then independently
requires that source mapping to agree with the fixed N-fast work sequence.
Each command has MXU_ROW scalar segments, source stride 8, destination stride 2,
and segment size 2. These actual descriptor fields are checked against the
source-derived geometry, not used to silently redefine expected data.

For scalar segment j, its requested source address is `source_base + 8*j`.
The memory request is aligned down to 32 or 64 bytes. Physical lane l addresses
that aligned base plus `8*l`, with exactly the independently expected slice of
the scalar's two-byte source mask. The checker observes each lane request and
tag, rejects tag reuse before response, and correlates all returned lane data.
Only explicitly enabled bytes contribute to the data comparison. Inactive
payload may legitimately contain irrelevant or unknown bits; the snapshot
preserves partial unknown vectors instead of discarding known active elements.

At install, destination segment j targets `destination_base + 2*j`. The
accepted wide bus address and byte mask must equal the independently calculated
aligned destination address and scalar mask. The actual scale/zero register
write pulse, valid/ready, selected register bank, retained opcode and work_seq
must all match the owned command. Missing/extra/reordered/duplicated command
identities are rejected. All scalar positions in both banks are observed.

## Reset, invocation identity, and one corrected checker assumption

The three accepted configurations occur in reset epochs 1/2/3. The host loop
rebuilds/reuploads tensors with data generation 0/1/2 and poisons output before
each `vx_start`; that source file is hash matched to the captured manifest.
The checker binds these full-capture configuration/reset ordinals to the host
loop's immutable generation schedule.

The internal controller `entry_id` is **0 in all three epochs**. It is not the
host `job_eid` or `job_generation` token. The first checker draft incorrectly
expected internal entry_id to increment and rejected the second configuration.
The waveform showed all three IDs are 0; the checker now validates entry_id 0
and uses the independently observed reset epoch plus configuration order for
invocation identity. No data expectation was relaxed to resolve that mismatch.

## Negative controls and semantic equivalence

For each resource the representative controls replace only captured payload
copies, preserving target command/address/bank/generation/byte-enable metadata:

1. One active two-byte element at install.
2. Its full eight-byte physical-lane chunk in the accepted wide install.
3. The full 32-byte or 64-byte install beat.
4. Every segment of one complete stale QROW command.
5. An actual tagged eight-byte physical response lane with a nonzero source mask.

The stale source is the corresponding command/segment from the prior host data
generation, so expected active data differ without changing the oracle. For a
single masked install, replacing a larger lane/beat still changes only one
architecturally enabled element; the checker reports one detected element,
not four/sixteen/thirty-two useful elements. Whole-command substitution detects
all sixteen or thirty-two independently enabled segments.

On MXU16, adjacent N slices can address the same QROW quant group. Replacing a
command with the immediately previous same-job command therefore has 48
**semantically equivalent** cases and 42 detectable cases over the three jobs.
The equivalent cases have exactly the same logical `(k,ng)` sequence and are
explicitly not counted as successful detections. Previous-job generation
substitution supplies a distinct expected-payload case for all 64 eligible
whole commands. On MXU32 each N slice is one QBLK32 group, yielding 18 detectable
same-job predecessor cases and no equivalent cases.

These controls demonstrate the captured source/install checker can detect
mapped payload corruption. They are post-capture substitutions, not live RTL
fault-injection tests, and do not claim that unobservably identical data are
wrong.

## Remaining scope

These captures add QROW, WTRANS1, both geometries, changing host generations,
reused source buffers, both register banks, and every masked install position.
M3 is an M-row tail; K/N are multiples of the MXU dimensions. Arbitrary K/N tails,
QCOL/WTRANS1 combinations, improve backend mapping, independent-engine contention,
live RTL fault injection, post-edge register-array readback and no-reset repeated
invocations remain separate coverage. The core's internal zero-point negation is
not independently read back by this accepted-interface checker.
