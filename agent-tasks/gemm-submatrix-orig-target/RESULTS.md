# GEMM submatrix verification results

Date: 2026-10-07T16:33:53

**PASS: 13 directed cases, 20 GEMM jobs, plus the final VCS FSM unit test.**

Configuration: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh` (TH16, MXU16).
Blackbox: configured `build/`, `ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --perf 3`.
Numerical checks use the existing FP16 tolerance; no mismatch exceptions were used.
Every untouched logical C entry is checked for exact sentinel preservation.

| Case | Shape / region arguments | Verified jobs | Final-job core cycles | Result |
|---|---|---:|---:|---|
| [partial_m](bb_v3/partial_m.log) | `-m 4 -n 128 -k 320 --target-m 1 --target-k 288 --tagged` | 1 | 8785 | PASS |
| [partial_odd_m](bb_v3/partial_odd_m.log) | `-m 3 -n 128 -k 320 --target-m 1 --target-k 288 --tagged` | 1 | 8710 | PASS |
| [region_start](bb_v3/region_start.log) | `-m 132 -n 256 -k 320 --m-start 128 --n-start 128 --target-m 1 --target-n 128 --target-k 288 --tagged` | 1 | 8785 | PASS |
| [partial_n_beat](bb_v3/partial_n_beat.log) | `-m 1 -n 128 -k 128 --target-n-list 16,48 --tagged` | 2 | 7708 | PASS |
| [normal_m1](bb_v3/normal_m1.log) | `-m 1 -n 256 -k 256 --tagged` | 1 | 9535 | PASS |
| [normal_m4](bb_v3/normal_m4.log) | `-m 4 -n 256 -k 256 --tagged` | 1 | 9760 | PASS |
| [normal_m256](bb_v3/normal_m256.log) | `-m 256 -n 256 -k 256 --tagged` | 1 | 79660 | PASS |
| [kv_pv](bb_v3/kv_pv.log) | `-m 1 -n 128 -k 512 -q 128 -t 0 -d 1 --target-k-list 256,288,320 --tagged` | 3 | 8828 | PASS |
| [kv_qk](bb_v3/kv_qk.log) | `-m 1 -n 512 -k 128 -q 128 -t 1 -d 0 --target-n-list 256,288,320 --tagged` | 3 | 8901 | PASS |
| [pv_storage_tail](bb_v3/pv_storage_tail.log) | `-m 1 -n 256 -k 320 -q 128 -d 1 --target-k 288 --tagged` | 1 | 9828 | PASS |
| [kv_pv_1024](bb_v3/kv_pv_1024.log) | `-m 4 -n 128 -k 1024 -q 128 -d 1 --target-k-list 256,288,320 --tagged` | 3 | 8976 | PASS |
| [qk_storage_tail](bb_v3/qk_storage_tail.log) | `-m 1 -n 320 -k 128 -q 128 -t 1 --target-n 288 --tagged` | 1 | 8778 | PASS |
| [partial_m_multitile](bb_v3_multitile/partial_m_multitile.log) | `-m 3 -n 256 -k 320 --target-m 1 --target-k 288 --tagged` | 1 | 9835 | PASS |

Sequence cycle values are the counters emitted at device close for the final job.
They are not per-prefix measurements or total sequence latency. Individual jobs each passed verification.

## What changed

- Original matrix dimensions determine physical A/W/scale/ZP/C tile geometry and strides.
- Target dimensions determine the executed microtiles and reduction endpoint.
- Partial output rows or a partial final 64B beat preload existing C, overwrite active elements, and preserve the rest.
- Preload drains earlier output DMA locally, then uses the existing DMA-owned RID_O notification and copy dependency. No scheduler widening or new memory.
- Host CLI exposes target extents and DMA-aligned starts, plus fixed-input prefix sequences.

## KV interpretation

For PV with original K=512 and target K=288, the first three stored K tiles have physical sizes 128/128/128; computation uses 128/128/32. The fourth capacity tile is not computed. With original K=320, the third physical tile has size64 while target288 still computes32. Both cases passed.
For QK, original N fixes capacity-dependent storage while target N selects the output prefix. The 512-capacity sequence and original-N320/target-N288 physical-tail case passed.
Capacity1024 PV used M=4 and targets256/288/320 with identical packed inputs across jobs.

## Verification iterations

- Existing FSM unit passed before and after the integration fix.
- Initial wrapper runs reused an old simv; those are excluded from final results. The new runner forces a current RTL build before running cases.
- Integrated partial-M testing caught unsupported DMA wait slots. Static follow-up also caught notification ownership constraints. The final implementation reuses RID_O without controller changes.
- Final numerical and simulator logs contain no strict failure markers.

## Limits and reproduction

See [README.md](README.md) for commands, alignment constraints, padding responsibilities, and TVM integration scope. This validates generic GEMMs modeling KV-cache usage in RTL simulation; it does not change TVM or produce a new FPGA bitstream.

Final FSM SHA-256: `d3b1a900aff0f058dcb47f49ad369cba5e7b6313587e8fd0df22cf9f7e7c407c`.
Final unit log: [unittest-gemm-fsm-v3.log](unittest-gemm-fsm-v3.log).
