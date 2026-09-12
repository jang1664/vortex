# VCS verification results

All sixteen v2 runs passed the deterministic verification gates.

| Read quota | Case | PASS | GEMM cycles | Core cycles |
|---:|---|---|---:|---:|
| 1 | short4 | PASS | 625 | 7167 |
| 1 | short16 | PASS | 797 | 7392 |
| 1 | m4 | PASS | 15693 | 22254 |
| 1 | m256 | PASS | 576763 | 583329 |
| 2 | short4 | PASS | 625 | 7167 |
| 2 | short16 | PASS | 797 | 7392 |
| 2 | m4 | PASS | 15981 | 22554 |
| 2 | m256 | PASS | 583150 | 589704 |
| 4 | short4 | PASS | 625 | 7167 |
| 4 | short16 | PASS | 797 | 7392 |
| 4 | m4 | PASS | 15942 | 22479 |
| 4 | m256 | PASS | 583658 | 590229 |
| 8 | short4 | PASS | 625 | 7167 |
| 8 | short16 | PASS | 797 | 7392 |
| 8 | m4 | PASS | 15942 | 22479 |
| 8 | m256 | PASS | 583658 | 590229 |

Short cases use K64/N16 and M4 or M16. Benchmark cases use K512/N512.

Every run has an identical 488-file RTL/config/app source hash map,
no source changes during execution, and an unchanged per-quota config profile.
The canonical source-map SHA-256 is `352791088fd280b615049c85bd4a11306698550996ba38eea2e6e51a88d14975`.

Each run required wrapper and runner status zero, `tools/verify_rtl.py` PASS
without strict failure, exactly one GEMM/core measurement, and a nonempty FSDB.
Hazard and arbitration coverage are analyzed separately by the task owner.

Iteration v1 stopped on an undeclared-identifier compilation error before simulation;
v2 includes the declaration-order fix and is the completed sweep.

Raw manifests, logs, and waveforms are retained under `../runs/v2/r<quota>-<case>/`.
No production config or RTL was changed by the verification agent.
