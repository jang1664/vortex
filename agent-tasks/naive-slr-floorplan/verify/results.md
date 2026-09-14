# Simulation results

| Run | Classification | Pass | GEMM cycles | Core cycles |
|---|---|---|---|---|
| baseline-improve-off-m256 | simulation | True | [273807] | [279574] |
| baseline-improve-off-m4 | aborted infrastructure setup | False | [] | [] |
| baseline-improve-off-m4-v2 | simulation | True | [6459] | [12197] |
| baseline-improve-on-m256 | simulation | True | [306947] | [312726] |
| baseline-improve-on-m4 | aborted infrastructure setup | False | [] | [] |
| baseline-improve-on-m4-v2 | simulation | True | [8189] | [13997] |
| baseline-naive-off-short4 | simulation | True | [625] | [7167] |
| candidate-improve-off-m256-n512-k512 | simulation | True | [273807] | [279574] |
| candidate-improve-off-m4-n512-k512 | simulation | True | [6459] | [12197] |
| candidate-improve-on-m256-n512-k512 | simulation | True | [306947] | [312726] |
| candidate-improve-on-m4-n512-k512 | simulation | True | [8189] | [13997] |
| candidate-naive-off-m16-n16-k64 | simulation | True | [797] | [7392] |
| candidate-naive-off-m256-n512-k512 | simulation | True | [576763] | [583329] |
| candidate-naive-off-m4-n16-k64 | simulation | True | [625] | [7167] |
| candidate-naive-off-m4-n512-k512 | simulation | True | [15693] | [22254] |
| candidate-naive-on-m16-n16-k64 | simulation | True | [886] | [7467] |
| candidate-naive-on-m16-n64-k64-tag-w0-d0 | simulation | True | [1293, 1293] | [7812] |
| candidate-naive-on-m16-n64-k64-tag-w0-d1 | simulation | True | [1884, 1884] | [8412] |
| candidate-naive-on-m16-n64-k64-tag-w1-d0 | simulation | True | [1337, 1337] | [7887] |
| candidate-naive-on-m16-n64-k64-tag-w1-d1 | simulation | True | [1910, 1910] | [8412] |
| candidate-naive-on-m256-n512-k512 | simulation | True | [579075] | [585654] |
| candidate-naive-on-m4-n16-k64 | simulation | True | [729] | [7317] |
| candidate-naive-on-m4-n512-k512 | simulation | True | [15866] | [22404] |

## Improve cycle preservation

- SLR off, M4: PASS
- SLR off, M256: PASS
- SLR on, M4: PASS
- SLR on, M256: PASS
