# Current QROW masked-install verification

All three retained current-revision captures pass independent, generation-aware
checks of accepted S/Z GEMM register writes. Numerical simulation had already
passed before this read-only FSDB analysis.

| Geometry / W layout | Jobs | Masked installs | Owned command completions | Previous-job stale commands detected |
|---|---:|---:|---:|---:|
| MXU16 / WT0 | 2 | 1024 | 64 | 32 |
| MXU16 / WT1 | 3 | 1536 | 96 | 64 |
| MXU32 / WT1 | 3 | 768 | 24 | 16 |

All3328 masked installs match the immutable QROW tensor formula, using the
reset-separated host generation and fixed N-fast command sequence. Checks cover
command segment count/stride/useful bytes, exact command ownership and one-time
completion, every segment index, write handshake, bank, address, byte mask, and
the enabled FP16/int16 element. No inactive unknown byte is treated as useful data.

For every case and both resources, element, mapped8-byte-lane chunk and whole
install-beat substitutions from the previous job are detected (18 representative
controls total). All112 complete previous-job stale commands are detected in
every active segment. These are copied captured-payload negative controls,
not live RTL fault injection. Mapped lane chunks at the install boundary do not
claim correlation of the physical source-response transactions.

Reproduce with `python3 p5-qrow-install-check.py RUN --mxu 16`
(or `--mxu 32` for MXU32). RUN is one of:

- p4-regression/naive-qrow-wt0-iteration2
- p4-regression/naive-qrow-wt1-iteration1
- p4-regression/naive32-qrow-wt1-iteration2

Each RUN/qrow-install-oracle/ retains signals.json, records.json and result.json
with waveform/manifest hashes. The original P0 oracle is reused for independent
logical values and mixed-unknown masking; the command/install mapping is new
for the independent metadata engines.
