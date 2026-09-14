# Merge verification results

Final gate: **PASS**.

No manual product-code changes relative to the automatic merge tree.

## Blackbox results

| Revision / profile | Case | Pass | GEMM cycles | Core cycles |
|---|---|---|---|---|
| baseline_improve_off | m4 | True | [6459] | [12197] |
| baseline_improve_off | m256 | True | [273807] | [279574] |
| baseline_improve_on | m4 | True | [8189] | [13997] |
| baseline_improve_on | m256 | True | [306947] | [312726] |
| candidate_improve_off | m4 | True | [6459] | [12197] |
| candidate_improve_off | m256 | True | [273807] | [279574] |
| candidate_improve_on | m4 | True | [8189] | [13997] |
| candidate_improve_on | m256 | True | [306947] | [312726] |
| candidate_l16_off | m4 | True | [16257] | [22854] |
| candidate_l16_off | m256 | True | [606387] | [612954] |
| candidate_l16_on | m4 | True | [16087] | [22629] |
| candidate_l16_on | m256 | True | [571360] | [577929] |
| candidate_l32_off | m4 | True | [13034] | [19629] |
| candidate_l32_off | m256 | True | [414891] | [421479] |
| candidate_d256_off_lmem | m4 | True | [14759] | [21381] |
| candidate_d256_off_lmem | m256 | True | [411384] | [417981] |
| candidate_d256_off_acc | m4 | True | [14953] | [21531] |
| candidate_d256_off_acc | m256 | True | [295631] | [302256] |
| candidate_d256_on_lmem | m4 | True | [16061] | [22656] |
| candidate_d256_on_lmem | m256 | True | [412553] | [419181] |
| candidate_d256_on_lmem | tag_w0_d0 | True | [1241, 1241] | [7762] |
| candidate_d256_on_lmem | tag_w0_d1 | True | [1832, 1832] | [8362] |
| candidate_d256_on_lmem | tag_w1_d0 | True | [1245, 1245] | [7762] |
| candidate_d256_on_lmem | tag_w1_d1 | True | [1832, 1832] | [8362] |
| candidate_d256_on_acc | m4 | True | [16178] | [22806] |
| candidate_d256_on_acc | m256 | True | [296685] | [303306] |
| candidate_d256_on_acc | tag_w0_d0 | True | [1252, 1252] | [7837] |
| candidate_d256_on_acc | tag_w0_d1 | True | [1908, 1908] | [8437] |
| candidate_d256_on_acc | tag_w1_d0 | True | [1256, 1256] | [7837] |
| candidate_d256_on_acc | tag_w1_d1 | True | [1890, 1890] | [8437] |

## Preservation and unit gates

- improve_cycles/off/m4: PASS
- improve_hbm/off/m4: PASS
- improve_cycles/off/m256: PASS
- improve_hbm/off/m256: PASS
- improve_cycles/on/m4: PASS
- improve_hbm/on/m4: PASS
- improve_cycles/on/m256: PASS
- improve_hbm/on/m256: PASS
- unit_bridge_l16_on: PASS
- unit_bridge_d256_on_lmem: PASS
- unit_dma_l16_on: PASS
- unit_dma_d256_on_lmem_wide: PASS
- unit_gemm_improve_off: PASS
- unit_gemm_d256_off_lmem: PASS
- unit_gemm_d256_off_acc: PASS
- unit_lmem32: PASS
- splitter_29: PASS
- improve_selected_rtl: PASS
- improve_elaborated_hierarchy: PASS
- improve_inspected_executables: PASS
- automatic_merge_unchanged: PASS

## Evidence limits

- All blackboxes use the configured-build xrt-vcs-sim wrapper and identical timing models for matched improve runs.
- DISABLE_FSDB disables waveform storage only; latency observers, numerical checks, and VCS failure scanning remain enabled.
- No synthesis or P&R was run; this merge does not establish new FPGA timing closure for L32/D256/ACC combinations.
- Raw logs, source hashes, effective CONFIGS, commands, and HBM manifests are under execution/.
- Improve hierarchy comparison preserves distinct instances while canonicalizing only line-derived macro names.
- Historical imported CSV/SVG whitespace is preserved; hw/ and configs/ pass diff whitespace checks.
