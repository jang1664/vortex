# Complete samples and matched performance comparisons

Generated from retained JSON records; no measurement is replaced or selected by its speed.

Pre-merge rows enforce the 2% median total-cycle regression gate. Activation rows compare the combined candidate with its own cuts-off mode and are not pre-merge integration evidence.

## MXU32 SLR cuts off (primary)

Reference: pre-merge. Recorded 12/12 runs; functional matrix: PASS.

| Case | Reference samples | Candidate samples | Median before / after | Delta | Gate |
|---|---|---|---|---|---|
| smoke_qcol | 5799, 5874, 5800 | 5876, 5875, 5874 | 5800 / 5875 | +1.293% | PASS |
| overlap_qcol | 6548, 6548, 6547 | 6632, 6626, 6624 | 6548 / 6626 | +1.191% | PASS |
| qrow | 6178, 6174, 6174 | 6255, 6250, 6174 | 6174 / 6250 | +1.231% | PASS |
| odd_tail_qcol | 5872, 5872, 5872 | 5872, 5872, 5875 | 5872 / 5872 | +0.000% | PASS |

Internal intervals below are event spans, not active-cycle or stall-reason counters.

| Case | Compute span before / after | DMA span before / after | Final-store span before / after |
|---|---|---|---|
| smoke_qcol | 28 / 30 | 140 / 146 | 0 / 0 |
| overlap_qcol | 627 / 655 | 872 / 916 | 108 / 111 |
| qrow | 216 / 220 | 513 / 523 | 96 / 97 |
| odd_tail_qcol | 29 / 31 | 177 / 182 | 34 / 35 |

## MXU16 local C2

Reference: pre-merge. Recorded 60/60 runs; functional matrix: PASS.

| Case | Reference samples | Candidate samples | Median before / after | Delta | Gate |
|---|---|---|---|---|---|
| m4_k256_n256_d0_t0 | 7603, 7527, 7523 | 7605, 7609, 7604 | 7527 / 7605 | +1.036% | PASS |
| m4_k256_n256_d0_t1 | 7523, 7603, 7523 | 7613, 7605, 7600 | 7523 / 7605 | +1.090% | PASS |
| m4_k256_n256_d1_t0 | 7602, 7523, 7526 | 7601, 7600, 7532 | 7526 / 7600 | +0.983% | PASS |
| m4_k256_n256_d1_t1 | 7600, 7523, 7599 | 7531, 7605, 7524 | 7599 / 7531 | -0.895% | PASS |
| m1_k256_n256_d0_t0 | 7448, 7449, 7448 | 7539, 7456, 7467 | 7448 / 7467 | +0.255% | PASS |
| m1_k256_n256_d0_t1 | 7448, 7451, 7457 | 7450, 7450, 7533 | 7451 / 7450 | -0.013% | PASS |
| m1_k256_n256_d1_t0 | 7527, 7525, 7525 | 7525, 7526, 7529 | 7525 / 7526 | +0.013% | PASS |
| m1_k256_n256_d1_t1 | 7524, 7534, 7523 | 7537, 7524, 7525 | 7524 / 7525 | +0.013% | PASS |
| m16_k256_n256_d0_t0 | 10526, 10531, 10532 | 10539, 10534, 10529 | 10531 / 10534 | +0.028% | PASS |
| m16_k256_n256_d0_t1 | 10531, 10530, 10529 | 10526, 10532, 10532 | 10530 / 10532 | +0.019% | PASS |
| m16_k256_n256_d1_t0 | 10526, 10532, 10609 | 10533, 10534, 10527 | 10532 / 10533 | +0.009% | PASS |
| m16_k256_n256_d1_t1 | 10526, 10530, 10530 | 10528, 10526, 10533 | 10530 / 10528 | -0.019% | PASS |
| m32_k256_n512_d0_t0 | 23950, 23968, 23950 | 23953, 23965, 23954 | 23950 / 23954 | +0.017% | PASS |
| m32_k256_n512_d0_t1 | 23955, 23954, 23957 | 23955, 23959, 23953 | 23955 / 23955 | +0.000% | PASS |
| m32_k256_n512_d1_t0 | 23952, 24034, 23949 | 23951, 23954, 23949 | 23952 / 23951 | -0.004% | PASS |
| m32_k256_n512_d1_t1 | 24025, 24036, 24025 | 23956, 23952, 23950 | 24025 / 23952 | -0.304% | PASS |
| m64_k512_n256_d0_t0 | 40453, 40453, 40449 | 40459, 40455, 40454 | 40453 / 40455 | +0.005% | PASS |
| m64_k512_n256_d0_t1 | 40452, 40450, 40458 | 40457, 40461, 40454 | 40452 / 40457 | +0.012% | PASS |
| m64_k512_n256_d1_t0 | 40449, 40459, 40462 | 40448, 40450, 40459 | 40459 / 40450 | -0.022% | PASS |
| m64_k512_n256_d1_t1 | 40462, 40454, 40455 | 40451, 40451, 40452 | 40455 / 40451 | -0.010% | PASS |

Internal intervals below are event spans, not active-cycle or stall-reason counters.

| Case | Compute span before / after | DMA span before / after | Final-store span before / after |
|---|---|---|---|
| m4_k256_n256_d0_t0 | 1538 / 1537 | 1868 / 1884 | 210 / 210 |
| m4_k256_n256_d0_t1 | 1537 / 1541 | 1867 / 1884 | 210 / 210 |
| m4_k256_n256_d1_t0 | 1532 / 1532 | 1868 / 1875 | 210 / 210 |
| m4_k256_n256_d1_t1 | 1532 / 1532 | 1874 / 1868 | 210 / 210 |
| m1_k256_n256_d0_t0 | 1507 / 1507 | 1792 / 1801 | 168 / 168 |
| m1_k256_n256_d0_t1 | 1507 / 1507 | 1794 / 1794 | 168 / 168 |
| m1_k256_n256_d1_t0 | 1537 / 1537 | 1836 / 1836 | 168 / 168 |
| m1_k256_n256_d1_t1 | 1537 / 1537 | 1835 / 1833 | 168 / 168 |
| m16_k256_n256_d0_t0 | 4325 / 4325 | 4856 / 4859 | 379 / 379 |
| m16_k256_n256_d0_t1 | 4325 / 4325 | 4863 / 4862 | 379 / 378 |
| m16_k256_n256_d1_t0 | 4326 / 4326 | 4872 / 4868 | 378 / 379 |
| m16_k256_n256_d1_t1 | 4325 / 4325 | 4865 / 4870 | 378 / 378 |
| m32_k256_n512_d0_t0 | 17473 / 17473 | 18281 / 18284 | 616 / 616 |
| m32_k256_n512_d0_t1 | 17473 / 17473 | 18281 / 18290 | 616 / 616 |
| m32_k256_n512_d1_t0 | 17473 / 17473 | 18287 / 18287 | 616 / 616 |
| m32_k256_n512_d1_t1 | 17473 / 17473 | 18313 / 18287 | 616 / 616 |
| m64_k512_n256_d0_t0 | 33399 / 33399 | 34769 / 34790 | 1092 / 1092 |
| m64_k512_n256_d0_t1 | 33399 / 33399 | 34766 / 34768 | 1092 / 1092 |
| m64_k512_n256_d1_t0 | 33399 / 33399 | 34778 / 34780 | 1092 / 1092 |
| m64_k512_n256_d1_t1 | 33399 / 33399 | 34775 / 34779 | 1092 / 1092 |

## MXU32 local cuts off

Reference: pre-merge. Recorded 12/12 runs; functional matrix: PASS.

| Case | Reference samples | Candidate samples | Median before / after | Delta | Gate |
|---|---|---|---|---|---|
| m4_k256_n256_d0_t0 | 6478, 6472, 6472 | 6476, 6472, 6472 | 6472 / 6472 | +0.000% | PASS |
| m4_k256_n256_d0_t1 | 6474, 6473, 6475 | 6474, 6476, 6474 | 6474 / 6474 | +0.000% | PASS |
| m4_k256_n256_d1_t0 | 6473, 6473, 6474 | 6472, 6472, 6473 | 6473 / 6472 | -0.015% | PASS |
| m4_k256_n256_d1_t1 | 6475, 6479, 6474 | 6473, 6472, 6479 | 6475 / 6473 | -0.031% | PASS |

Internal intervals below are event spans, not active-cycle or stall-reason counters.

| Case | Compute span before / after | DMA span before / after | Final-store span before / after |
|---|---|---|---|
| m4_k256_n256_d0_t0 | 563 / 563 | 766 / 769 | 84 / 84 |
| m4_k256_n256_d0_t1 | 564 / 564 | 766 / 777 | 84 / 84 |
| m4_k256_n256_d1_t0 | 566 / 563 | 776 / 766 | 84 / 84 |
| m4_k256_n256_d1_t1 | 565 / 565 | 774 / 779 | 85 / 84 |

## MXU32 local C2

Reference: pre-merge. Recorded 12/12 runs; functional matrix: PASS.

| Case | Reference samples | Candidate samples | Median before / after | Delta | Gate |
|---|---|---|---|---|---|
| m4_k256_n256_d0_t0 | 6479, 6472, 6474 | 6472, 6480, 6472 | 6474 / 6472 | -0.031% | PASS |
| m4_k256_n256_d0_t1 | 6472, 6472, 6472 | 6472, 6476, 6472 | 6472 / 6472 | +0.000% | PASS |
| m4_k256_n256_d1_t0 | 6472, 6474, 6473 | 6473, 6472, 6472 | 6473 / 6472 | -0.015% | PASS |
| m4_k256_n256_d1_t1 | 6474, 6472, 6473 | 6472, 6474, 6474 | 6473 / 6474 | +0.015% | PASS |

Internal intervals below are event spans, not active-cycle or stall-reason counters.

| Case | Compute span before / after | DMA span before / after | Final-store span before / after |
|---|---|---|---|
| m4_k256_n256_d0_t0 | 573 / 569 | 780 / 777 | 87 / 87 |
| m4_k256_n256_d0_t1 | 571 / 569 | 780 / 781 | 87 / 87 |
| m4_k256_n256_d1_t0 | 572 / 572 | 780 / 780 | 87 / 87 |
| m4_k256_n256_d1_t1 | 573 / 570 | 781 / 781 | 87 / 87 |

## MXU16 SLR cuts off

Reference: pre-merge. Recorded 12/12 runs; functional matrix: PASS.

| Case | Reference samples | Candidate samples | Median before / after | Delta | Gate |
|---|---|---|---|---|---|
| m4_k256_n256_d0_t0 | 7973, 7974, 7978 | 8134, 8127, 8123 | 7974 / 8127 | +1.919% | PASS |
| m4_k256_n256_d0_t1 | 7981, 7979, 7975 | 8123, 8132, 8125 | 7979 / 8125 | +1.830% | PASS |
| m4_k256_n256_d1_t0 | 7982, 7973, 7977 | 8136, 8122, 8127 | 7977 / 8127 | +1.880% | PASS |
| m4_k256_n256_d1_t1 | 7978, 7974, 7988 | 8126, 8139, 8126 | 7978 / 8126 | +1.855% | PASS |

Internal intervals below are event spans, not active-cycle or stall-reason counters.

| Case | Compute span before / after | DMA span before / after | Final-store span before / after |
|---|---|---|---|
| m4_k256_n256_d0_t0 | 1901 / 2040 | 2291 / 2454 | 259 / 266 |
| m4_k256_n256_d0_t1 | 1901 / 2040 | 2294 / 2442 | 259 / 266 |
| m4_k256_n256_d1_t0 | 1873 / 2004 | 2286 / 2414 | 259 / 266 |
| m4_k256_n256_d1_t1 | 1873 / 2004 | 2276 / 2416 | 259 / 266 |

## MXU16 SLR C2

Reference: candidate cuts-off activation. Recorded 12/12 runs; functional matrix: PASS.

| Case | Reference samples | Candidate samples | Median before / after | Delta | Gate |
|---|---|---|---|---|---|
| m4_k256_n256_d0_t0 | 8134, 8127, 8123 | 8217, 8200, 8199 | 8127 / 8200 | +0.898% | Activation delta |
| m4_k256_n256_d0_t1 | 8123, 8132, 8125 | 8201, 8205, 8206 | 8125 / 8205 | +0.985% | Activation delta |
| m4_k256_n256_d1_t0 | 8136, 8122, 8127 | 8130, 8130, 8131 | 8127 / 8130 | +0.037% | Activation delta |
| m4_k256_n256_d1_t1 | 8126, 8139, 8126 | 8130, 8129, 8127 | 8126 / 8129 | +0.037% | Activation delta |

Internal intervals below are event spans, not active-cycle or stall-reason counters.

| Case | Compute span before / after | DMA span before / after | Final-store span before / after |
|---|---|---|---|
| m4_k256_n256_d0_t0 | 2040 / 2063 | 2454 / 2474 | 266 / 273 |
| m4_k256_n256_d0_t1 | 2040 / 2065 | 2442 / 2486 | 266 / 273 |
| m4_k256_n256_d1_t0 | 2004 / 2007 | 2414 / 2433 | 266 / 273 |
| m4_k256_n256_d1_t1 | 2004 / 2008 | 2416 / 2426 | 266 / 273 |

## MXU32 SLR S/Z sink only

Reference: candidate cuts-off activation. Recorded 12/12 runs; functional matrix: PASS.

| Case | Reference samples | Candidate samples | Median before / after | Delta | Gate |
|---|---|---|---|---|---|
| m4_k256_n256_d0_t0 | 6632, 6626, 6624 | 6623, 6627, 6629 | 6626 / 6627 | +0.015% | Activation delta |
| m4_k256_n256_d0_t1 | 6623, 6624, 6624 | 6623, 6625, 6623 | 6624 / 6623 | -0.015% | Activation delta |
| m4_k256_n256_d1_t0 | 6623, 6625, 6625 | 6626, 6625, 6626 | 6625 / 6626 | +0.015% | Activation delta |
| m4_k256_n256_d1_t1 | 6623, 6622, 6622 | 6622, 6628, 6625 | 6622 / 6625 | +0.045% | Activation delta |

Internal intervals below are event spans, not active-cycle or stall-reason counters.

| Case | Compute span before / after | DMA span before / after | Final-store span before / after |
|---|---|---|---|
| m4_k256_n256_d0_t0 | 655 / 660 | 916 / 910 | 111 / 111 |
| m4_k256_n256_d0_t1 | 657 / 659 | 906 / 908 | 111 / 111 |
| m4_k256_n256_d1_t0 | 659 / 659 | 909 / 919 | 111 / 111 |
| m4_k256_n256_d1_t1 | 658 / 655 | 908 / 918 | 111 / 111 |

## MXU32 SLR HBM write only

Reference: candidate cuts-off activation. Recorded 12/12 runs; functional matrix: PASS.

| Case | Reference samples | Candidate samples | Median before / after | Delta | Gate |
|---|---|---|---|---|---|
| m4_k256_n256_d0_t0 | 6632, 6626, 6624 | 6623, 6623, 6622 | 6626 / 6623 | -0.045% | Activation delta |
| m4_k256_n256_d0_t1 | 6623, 6624, 6624 | 6624, 6623, 6622 | 6624 / 6623 | -0.015% | Activation delta |
| m4_k256_n256_d1_t0 | 6623, 6625, 6625 | 6622, 6624, 6627 | 6625 / 6624 | -0.015% | Activation delta |
| m4_k256_n256_d1_t1 | 6623, 6622, 6622 | 6627, 6625, 6625 | 6622 / 6625 | +0.045% | Activation delta |

Internal intervals below are event spans, not active-cycle or stall-reason counters.

| Case | Compute span before / after | DMA span before / after | Final-store span before / after |
|---|---|---|---|
| m4_k256_n256_d0_t0 | 655 / 658 | 916 / 906 | 111 / 111 |
| m4_k256_n256_d0_t1 | 657 / 659 | 906 / 908 | 111 / 111 |
| m4_k256_n256_d1_t0 | 659 / 658 | 909 / 907 | 111 / 111 |
| m4_k256_n256_d1_t1 | 658 / 658 | 908 / 916 | 111 / 111 |

## MXU32 SLR C2

Reference: candidate cuts-off activation. Recorded 12/12 runs; functional matrix: PASS.

| Case | Reference samples | Candidate samples | Median before / after | Delta | Gate |
|---|---|---|---|---|---|
| m4_k256_n256_d0_t0 | 6632, 6626, 6624 | 6623, 6627, 6626 | 6626 / 6626 | +0.000% | Activation delta |
| m4_k256_n256_d0_t1 | 6623, 6624, 6624 | 6625, 6626, 6627 | 6624 / 6626 | +0.030% | Activation delta |
| m4_k256_n256_d1_t0 | 6623, 6625, 6625 | 6626, 6627, 6622 | 6625 / 6626 | +0.015% | Activation delta |
| m4_k256_n256_d1_t1 | 6623, 6622, 6622 | 6622, 6627, 6622 | 6622 / 6622 | +0.000% | Activation delta |

Internal intervals below are event spans, not active-cycle or stall-reason counters.

| Case | Compute span before / after | DMA span before / after | Final-store span before / after |
|---|---|---|---|
| m4_k256_n256_d0_t0 | 655 / 666 | 916 / 926 | 111 / 115 |
| m4_k256_n256_d0_t1 | 657 / 660 | 906 / 922 | 111 / 114 |
| m4_k256_n256_d1_t0 | 659 / 661 | 909 / 926 | 111 / 114 |
| m4_k256_n256_d1_t1 | 658 / 659 | 908 / 914 | 111 / 114 |
