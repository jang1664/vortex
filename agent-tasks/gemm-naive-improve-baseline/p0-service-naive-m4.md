# P0 actual corrected-naive M4 service baseline

The retained corrected naive M4/K512/N512, th16/MXU16, QCOL/WTRANS0 waveform
contains the required fixed N-fast command stream. In the middle command window,
useful Input service is **2,048 accepted rows / 30,233 cycles = 6.77405484%**.
There are **0 overlapping pairs out of 510 eligible pairs**. This is baseline
evidence only; no candidate performance result is claimed.

## Fixed window and acceptance gates

| Quantity | Actual baseline / required candidate value |
|---|---|
| Selected zero-based Input ordinals | 256–767 inclusive |
| First/last accepted Input edges | 24,510 / 54,742 |
| Interval | `[24510, 54743)`, 30,233 cycles |
| Accepted Input rows | 2,048, exactly four per selected command |
| Input-handshake density | 0.06774054840736943 |
| Candidate +25% service threshold | >= 0.08467568550921178 |
| Maximum candidate interval for the same 2,048 rows | 24,186 cycles |
| Adjacent pairs in the window | 511 |
| Eligible independent pairs | 510 |
| Excluded pair | (511,512), the output-owner boundary |
| Baseline overlap | 0/510 |
| Required candidate overlap | >=255/510 |

The ordinal selection and owner eligibility are fixed before examining timing.
No source stalls, output-store gaps, inconvenient pairs, or DMA boundaries are
removed from the density denominator. Both endpoint handshakes are counted.
The candidate must still perform all expected work exactly once; omitting work
cannot satisfy the rate gate.

## What the waveform shows

Across all 30,233 cycles of that interval, the actual core Input interface is
ready. It accepts a row on 2,048 edges and has no valid row on the other 28,185
edges. There are zero cycles with Input valid and ready low. These observations
establish missing supply at this interface; they do not by themselves apportion
that absence among external DMA, local transport, command serialization, or
other upstream causes.

| Distribution | Minimum | Median | P90 | Maximum |
|---|---:|---:|---:|---:|
| Input command acceptance -> first accepted row, 512 commands | 23 | 23 | 23 | 23 |
| Consecutive eligible command acceptance spacing, 510 pairs | 53 | 58 | 59 | 119 |
| Empty edges between consecutive command row bursts, 510 pairs | 49 | 54 | 54 | 115 |
| Last accepted Input row -> final accepted compute writeback, 512 commands | 16 | 16 | 16 | 20 |
| Final accepted compute writeback -> physical command done, 512 commands | 3 | 3 | 3 | 3 |
| Next first Input minus previous final compute writeback, 510 pairs | 33 | 39 | 39 | 100 |

The last distribution is strictly positive, so none of these eligible pairs
feeds its next Input before the preceding command's final compute writeback.
The interface accepts each command's four rows without Input backpressure, but
the complete invocation still repeatedly stops supplying the interface.

Per-DMA-tile evidence below uses the same selected commands. Each local density
uses the span from that tile's first selected row to its last selected row;
these local spans do not include inter-tile gaps. The aggregate metric above
includes those gaps and remains the acceptance-gate denominator.

| DMA tile | Command ordinals | Rows | Local interval cycles | Local density | Local overlaps/eligible |
|---|---|---:|---:|---:|---:|
| 4 | 256–319 | 256 | 3663 | 6.98881% | 0/63 |
| 5 | 320–383 | 256 | 3666 | 6.98309% | 0/63 |
| 6 | 384–447 | 256 | 3665 | 6.98499% | 0/63 |
| 7 | 448–511 | 256 | 3685 | 6.94708% | 0/63 |
| 8 | 512–575 | 256 | 3661 | 6.99262% | 0/63 |
| 9 | 576–639 | 256 | 3664 | 6.98690% | 0/63 |
| 10 | 640–703 | 256 | 3663 | 6.98881% | 0/63 |
| 11 | 704–767 | 256 | 3687 | 6.94331% | 0/63 |

There are 504 local eligible pairs in this table and six additional eligible
pairs across DMA-tile boundaries. The one remaining adjacent pair crosses an
output owner and is excluded from overlap eligibility only, not from the input
density interval.

## Input admission, compute writeback, and physical drain

The checker observes these independent RTL events immediately before rising
GEMM clock edges:

- Command acceptance: `packetizer_cmd_valid && packetizer_cmd_ready`.
- Useful Input service: `i_gemm_bus_if.req_valid && req_ready`, cross-checked
  against `u_VX_gemm_compute_core.input_fire` and the carried packet work_seq.
- Accepted compute writeback: `u_VX_gemm_compute_core.acc_write_fire`, identified
  by `acc_result_data_out.ctrl.work_seq` and the exact row write address.
- Last-row compute writeback: the fourth accepted writeback for that command,
  independently cross-checked with the actual tagged-writeback event.
- Physical command completion: `packetizer_command_done`, requiring the final
  compute writeback to have occurred and the node's pending narrow-write lane
  count to be zero.

Input acceptance is not compute completion. An accepted ACC writeback is not
proof that all physical lane buffers have drained. The physical command-done
boundary is the existing node pending-lane contract; final memory-bank/HBM
visibility remains a separate audit.

In the same fixed Input interval, 2,044 of the selected commands' ACC writeback
rows retire (0.06760824 rows/cycle) and 511 selected command physical drains
occur (0.01690206 commands/cycle). There are 16,112 actual narrow write handshakes
at the observed node drain boundary in that interval. The last command's four
writebacks and final drain occur after the Input window ends: its final compute
writeback is edge 54,762 and physical done is 54,765. Those events are retained
and verified, rather than extending the denominator to make Input density look
better or calling the late rows missing work.

## Actual descriptor identity versus the planned metadata contract

The complete capture has exactly 1,024 sequential Input work identities, each
with four accepted Input rows and four accepted writeback rows. The checker
correlates actual Weight descriptors and the already verified S/Z install
ownership evidence with actual accepted/completed external Input loads.
Original tensor offsets identify K, N, source-buffer generation, and output
owner; observed packet/writeback row addresses must match. All **23 canonical
geometry/address/owner fields** compare exactly to `p0-contract.stream` for
M4/K512/N512 MXU16 QCOL/WTRANS0. The canonical `terminal` boolean is
derived from the observed last-K flag and final N-slice coordinates; it is not
a claim that the legacy descriptor already carries a separate terminal-fence
field. `columns=16` follows the fixed full-width geometry of this shape.

Four real external output-store descriptors independently identify owners
1/2/3/4 from their output tensor addresses. Each owner's last command has drained
before its store is accepted. The store accept/completion edges are retained
in the results. `output_store_done` is cache-path retirement and is not relabeled
as final HBM visibility.

The JSON input trace follows `p0-contract.py --input-trace` field names, but
faithfully reports the **legacy** completion behavior: no attached planned
admission_wait and physical command drain followed by separate NOTIFY. The
planned contract instead requires attached admission and registered-ingress /
terminal-output-fence metadata. Running the CLI therefore correctly rejects
this baseline trace with `RTL descriptor stream differs from contract`.
The checker verifies that exact rejection and that the existing contract
artifacts are unchanged. It does not fill absent metadata with planned values
to manufacture a full-contract pass. The geometry/service checks pass; the
redesigned metadata contract remains an implementation requirement.

## Legacy final-address truncation and physical offset normalization

The captured LMEM origin is `0x1ffc00000`. For command 0 the PSUM base is
`0x1ffc1d000`, while the final-output base carried in 32-bit `cmd.stride` is
`0xffc15000`: its upper address bit has been truncated. A direct full-address
subtraction therefore differs from the plan's relative `0x15000` final offset.

The configured LMEM size is 1 MiB. `VX_mem_unit` fixes the local address width
to `LMEM_LOG_SIZE - log2(8)` and `VX_local_mem` extracts bank/row bits within that
range. This checker explicitly compares the physical LMEM offset as
`(raw_address - origin) modulo 1 MiB` for legacy final-address/writeback paths,
while retaining every raw command address in the results and snapshot.
This explains the baseline alias; it is **not** a claim that legacy final
addresses preserve full width. The redesign's required full-width naive
address metadata must not be waived based on this physical-offset comparison.

## Artifacts, provenance, and reproduction

```sh
PYTHONPATH=tools python3 agent-tasks/gemm-naive-improve-baseline/p0-service-check.py
```

Files owned by this analysis:

- `p0-service-check.py`: actual trace extraction, identity checks and metrics.
- `p0-service-naive-m4-snapshot.json`: raw `fsdb_cli` signal transitions.
- `p0-service-naive-m4-input-trace.json`: actual canonical baseline descriptors.
- `p0-service-naive-m4-results.json`: commands, edges, pair eligibility,
  per-tile distributions, endpoint definitions and baseline gate thresholds.

Input capture: `p0-baseline/naive-m4-retry1/wave.fsdb`.
Waveform SHA256: `8895227251bd619dc720ab1b93d8a42535f05630ed3fe866b02550c4c007f890`.
The neighboring run manifest records configuration/source hashes. Results also
pin the manifest and contract script hashes and require the reused S/Z ownership
JSON to refer to the same verified waveform. Sampling is strictly before rising
edges, excluding synchronous nonblocking updates. No simulation was rerun for
this analysis and no RTL, app, or historical report was changed.
