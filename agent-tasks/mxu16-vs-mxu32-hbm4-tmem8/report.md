# MXU16 versus MXU32: HBM4 / DMA4 / TMEM8, fixed 512 KiB

## Configuration

Both configurations use thread16, four external HBM AXI ports, four DMA
channels, eight physical TMEM banks, 512 KiB total TMEM, and C2 timing cuts.
The platform still has 32 physical HBM pseudo-channels.

| Property | MXU16 | MXU32 |
| --- | ---: | ---: |
| MXU rows/columns | 16/16 | 32/32 |
| Physical TMEM word | 32 B | 64 B |
| Bank capacity | 64 KiB | 64 KiB |
| Words per bank | 2048 | 1024 |
| HBM/DMA beat | 64 B | 64 B |
| Banks used by one DMA beat | Two, simultaneously | One, address-selected |

Configuration paths:

- `configs/improve_th16_tcol16_m16_hwexp_dcache_sxbar_f16_bigmem_hbm4_tmem8.sh`
- `configs/improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm4_tmem8.sh`

The sourced `CONFIGS` differ only in `MXU_ROW`, `MXU_COL`, and `MXU_COL_TILE`.
Both bank capacities are 65536 bytes. For MXU16 this doubles bank depth
relative to the original 32 KiB-bank profile rather than reducing total capacity.

## RTL change

`VX_tmem_subsystem.sv` supports an additional equal-width organization with
two banks owned by each DMA channel. The DMA descriptor controller already
removes the channel-select bits from the flat address. For MXU32/DMA4/TMEM8,
the remaining channel-local word-address bit0 selects the owned bank:

`bank = channel + 4 * word_addr[0]`, `row = word_addr >> 1`.

This means channels0-3 respectively own bank pairs (0,4), (1,5), (2,6), (3,7).
Each 64B request accesses exactly one bank. Request routing is fixed ownership
with an address select, not an all-to-all crossbar. The two response inputs
are round-robin arbitrated and the selected response remains locked under
backpressure. The implementation declares three control FFs per channel,
with no new payload FIFO or reorder RAM. Existing DMA tagged slots handle
out-of-order read returns. TMEM write ACK filtering remains before this mux.

MXU16 still uses the existing 64-to-2x32B adapter and adjacent bank pairs.
The legacy MXU32 one-channel/one-bank direct path is also preserved.
GEMM-node assertions retain the 512 KiB capacity check and allow valid
1024-word or 2048-word banks. Address widths derive from bank geometry.
The application and kernel already derive layout/capacity from the MXU and
TMEM configuration; no software algorithm/layout edit was needed.

## Verification and performance methodology

Directed verification and performance measurement completed successfully on
2026-09-06 at 16:42 KST. All 18 independent blackbox launches PASS, with no
simulator error markers or output mismatches.

| Directed profile | Result |
| --- | --- |
| MXU32 DMA4/TMEM8 selected-bank, release tags | PASS |
| MXU32 DMA4/TMEM8 selected-bank, debug tags | PASS |
| MXU16 DMA4/TMEM8 pair, depth2048 | PASS |
| Legacy MXU16 DMA8/TMEM16 pair | PASS |
| Legacy MXU32 DMA8/TMEM8 direct | PASS |

All five unit runs have zero case-insensitive `Error:`, `Fatal:`, or
`Error-[` matches. The additional MXU16 low/high-row retention test also
passed: rows1023 and2047 retain different payloads after both are written,
directly checking that the new high address bit is not lost. Its fresh-build
compile and simulator logs likewise contain no strict error markers.

Directed tests cover routing, data/tags, bank-row addressing, independent
backpressure, response ordering and stability, and late write ACKs.
Unit checks use `tools/verify_rtl.py` plus explicit case-insensitive error
scanning. The latter also checks nonfatal VCS `Error:` messages, which were
missed in the earlier 256 KiB comparison.

Fresh configured builds source each config and run:

```sh
./ci/run_black.sh xrt-vcs-sim --perf 3 --app fpint_gemm_ffn_hw \
  --args "-m M -k 256 -n 256 -q 32 -d 0 -t 0 -r 1"
```

M is 1,4,256. Each profile/shape is independently launched three times.
Only `total_cycles` on `PERF: jobs=... total_cycles=... busy_cycles=...`
is compared. This is the GEMM-node invocation-active/compute-active counter,
not processor cycles, host elapsed time, achieved Fmax, or board throughput.
No `--debug` is added to performance runs; C2 cuts are enabled in both.
The runner preserves wrapper/simulator logs, manifests and binary/source
hashes, and rejects errors even when the application reports PASSED.

No PnR or hardware run is performed in this task.

## GEMM-node cycle results

K=N256, QBLK32, QDIR0, WTRANS0. Values are the median of three launches;
all three readings were identical for every shape/profile, so min=median=max.

| M | MXU16 total_cycles | MXU32 total_cycles | MXU32 cycle reduction | Cycle speedup (MXU16/MXU32) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1,821 | 791 | 56.56% | 2.30x |
| 4 | 1,896 | 822 | 56.65% | 2.31x |
| 256 | 72,032 | 18,077 | 74.90% | 3.98x |

These compare only GEMM-node cycles. The ratios do not assert equivalent
post-route clock frequency, area, power, or board-level speedup.

Both profiles recorded the same 369-file RTL/kernel/runtime/application
source snapshot. Source/config integrity checks remained clean at completion,
and simulator/kernel hashes remained unchanged within each profile. The host
logs explicitly confirm the expected MXU16 or MXU32 profile, qdir/transpose,
and execution shapes. No old 256 KiB measurement was reused.

Evidence:

- [Machine-readable comparison](perf_iter1/comparison.json)
- [MXU16 repetitions](perf_iter1/mxu16/results.json)
- [MXU32 repetitions](perf_iter1/mxu32/results.json)
- [Directed verification details](verification.md)
- Per-case `wrapper.log`, `simv.log`, and `command.json` under
  `perf_iter1/mxu16/m*_r*/` and `perf_iter1/mxu32/m*_r*/`.
