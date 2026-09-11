# P0 QCOL/WTRANS1 repeated-job quant install evidence

**PASS:** retained `p0-baseline/naive-qcol-wt1-repeat2` waveform, th16/MXU16, M16 K64 N64, QCOL, WTRANS1, qblk32, default vectors, generations 0 and 1. Both jobs passed the host test. This supplements the original QCOL/WTRANS0 M4 check and the separate QROW checks; it does not establish improve payload correctness or no-reset lifecycle correctness.

## Reproduction and oracle

```sh
python3 agent-tasks/gemm-naive-improve-baseline/p0-install-qcol-repeat.py
```

The new script leaves `p0-install-check.py` and `p0-install-qrow.py` unchanged. It reuses their FSDB access, strictly-pre-rising-edge sampling and independent generation formula. The snapshot is bound to SHA256 of the retained waveform; results record manifest, checker/helper and captured RTL/host/vector source hashes. Current relevant sources must match the finalized passing run before checking.

Wave SHA256: `cdb03f24bb75283bf963807af6ab1c054394b579b81f87ce17025a6ba8042017`.

Expected S is independently encoded binary16 of `1 + ((row % 17 + generation % 17) % 17)/16 + (col % 7)/8`; expected Z is signed16 `((3*(row % 7) + col % 7 + generation % 7) % 7) - 3`. The oracle never derives an expected element from an observed payload. These match `tests/regression/fpint_gemm_ffn_hw/test_vectors.h:57`. WTRANS changes W packing; QCOL S/Z retain logical `[K/qblk, N]` layout.

## Actual ownership and source checks

- Capture actual accepted config, reset epochs, external DMA command starts/completions, quant starts, work sequence, resource opcode, physical request addresses/tags/byte masks, physical tagged responses, and accepted scale/zero register writes.
- Each quant read must map to a unique completed external S/Z load, using observed LMEM and tensor bases and groups count. QCOL external rows are padded to NT=128 elements in LMEM while host rows have N=64 elements (`VX_gemm_dma_ctrl_naive.sv:317`, `:334`). Thus LMEM offset is split by 256 bytes, then mapped with the 128-byte host row stride. Reports preserve the actual owning external descriptor and completion edge.
- Captured quant descriptor must be one 32-byte segment with 256-byte source stride and zero destination stride (`VX_gemm_node_naive.sv:489`–`:515`). Independent fixed N-fast identity uses 16 Input microtiles: `micro_k,micro_n = divmod(work_seq-1,4)`, tensor row `micro_k*16/32`, column `micro_n*16`. Actual DMA mapping must agree. Each resource has exactly work_seq 1..16 per job.
- Every physical lane request must access `source_lmem + 8*lane` with all eight bytes enabled. Accepted response must match an outstanding `(lane,tag)` reservation and four independent expected elements. Each installation requires exactly four unique completed lane responses and no remaining lane reservation.
- Actual install owner opcode/work sequence/bank must match the accepted descriptor; resource request-valid/ready and compute bank must agree. All 16 installed elements are checked. Missing legacy metadata is not invented: host generation is the independently verified reset/config order, and row/column are checker-derived logical identities rather than claimed physical command fields.

## Coverage and fault controls

| Measured coverage | Result |
|---|---:|
| Jobs / reset epochs | 2 / 1,2 |
| Accepted S/Z installs | 64 |
| Installed FP16/int16 elements checked | 1,024 |
| Accepted physical lane responses | 256 |
| Physical response elements checked | 1,024 |
| Unique tensor elements per job per resource | 128 |
| Actual banks | 0,1 |
| Actual install byte mask | 0xffffffff |
| Install / physical element mismatches | 0 / 0 |

Eight representative copied-payload controls cover element, 8-byte lane, 32-byte beat, and stale whole command for S and Z. All modified elements are detected. All 32 second-job commands substituted with the same command from job 0 are detected in all 16 elements; all 128 second-job physical lane responses substituted from job 0 are detected in all four elements. Substitution of the immediately previous same-resource command detects all 60 available cases; zero cases are payload-equivalent in this capture.

These are post-capture negative controls, not live RTL fault injection. Source-load mapping is checked from actual accepted external commands and completion ownership; this is not an independent AXI/HBM write-visibility proof. Accepted install data is checked at the register-write boundary; post-edge register arrays are not separately read back. Whole-command and wide-beat controls coincide for this one-beat QCOL command, so they are not independent multi-beat coverage. N/K are full MXU multiples. Reset-separated jobs demonstrate generation-sensitive payload checking but leave no-reset lifecycle evidence to the integrated-node test.

Artifacts: `p0-install-qcol-repeat.py`, `-snapshot.json`, `-results.json`, `.log`. No production edits or simulations were performed.
