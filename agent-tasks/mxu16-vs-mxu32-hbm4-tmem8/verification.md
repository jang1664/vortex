# Directed verification

2026-09-06 16:29 KST: all five directed VCS profiles PASS via
`tools/verify_rtl.py unittest --sim vcs --timeout 60`. Additional
case-insensitive `Error:`, `Fatal:`, and `Error-[` scans of both compilation
and simulation logs found no errors. Results are in
`units_iter1/results.json`; each profile manifest records its configuration
and isolated configured build directory. No clean targets were used.

| Profile | Physical word | Banks / DMA channels | Bank depth | Result |
|---|---:|---:|---:|---|
| New selected-bank, release tags | 64 B | 8 / 4 | 1024 | PASS |
| New selected-bank, debug UUID tags | 64 B | 8 / 4 | 1024 | PASS |
| Deeper paired-bank MXU16 | 32 B | 8 / 4 | 2048 | PASS |
| Legacy paired-bank MXU16 | 32 B | 16 / 8 | 1024 | PASS |
| Legacy direct-bank MXU32 | 64 B | 8 / 8 | 1024 | PASS |

## Coverage

The new `hw/unittest/tmem_dma_bank_select` uses the real subsystem and
64-KiB banks. Only the idle DMA engine's outgoing bus is replaced by a
directed transaction driver; engine bookkeeping assertions alone are
disabled because descriptor issue is intentionally bypassed. Transport and
physical-bank assertions remain enabled.

- All four DMA channels and all eight physical banks.
- Physical bank `channel + 4 * address[0]`, physical row `address >> 1`.
- Addresses selecting rows 0, 1, 511, and 1023 on both owned banks.
- Independent bank request stalls and concurrent unrelated-channel traffic.
- Bank 4 returns before delayed bank 0; tag-based payload association.
- A stalled bank-4 response remains stable when bank 0 becomes ready.
- Late write ACKs on all eight banks, read tag zero and all-ones tag,
  delayed bank responses, and DMA response backpressure.
- Exact physical request/response counts and absence of duplicate or
  unsolicited responses.

The existing write-ACK integration test additionally checks paired/direct
transport, delayed ACK drain while DMA read-ready is low, reset with pending
ACKs, unchanged local-output write-ACK behavior, and the final physical row.
The latter now covers the 2048-word MXU16 bank-depth boundary.

2026-09-06 16:32 KST: supplementary depth-retention check PASS in a sixth
fresh build, `build_dma4_units_iter1_pair_depth_retention`.
`pair_depth_retention_verify.json` records deterministic-runner PASS;
case-insensitive compilation/simulation Error/Fatal scans are empty.
This test writes different payloads to rows 1023 and 2047 before reading
either row, explicitly excluding a self-consistent address-truncation alias.

## Blackbox performance

Started at 2026-09-06 16:29 KST using the prepared `run_comparison.py
--run-id perf_iter1`. It uses separate fresh configured MXU16 and MXU32
builds and the mandatory `ci/run_black.sh xrt-vcs-sim --perf 3` wrapper.
Completed at 2026-09-06 16:42 KST: all 18 blackbox launches strict-PASS.
Application return codes are zero, each application prints exactly one
`PASSED`, and no Error/Fatal markers appear in wrapper or simulator logs.
Source/config integrity checks pass for both profiles; simulator and kernel
hashes remain unchanged across repeats. The kernel binary hash is also
identical between MXU profiles.

| M (K=N=256) | MXU16 GEMM-node cycles, all 3 repeats | MXU32 GEMM-node cycles, all 3 repeats |
|---:|---:|---:|
| 1 | 1821 / 1821 / 1821 | 791 / 791 / 791 |
| 4 | 1896 / 1896 / 1896 | 822 / 822 / 822 |
| 256 | 72032 / 72032 / 72032 | 18077 / 18077 / 18077 |

Raw records and hashes: `perf_iter1/mxu16/`, `perf_iter1/mxu32/`.
Computed comparison: `perf_iter1/comparison.json`.
Only GEMM-node `total_cycles` is compared; no PnR-frequency or wall-clock
performance conclusion is implied.

## Procedure fallback

The Verification-agent definition references `harness/rules/testbench.md`,
`harness/skills/run-test/SKILL.md`, and
`harness/skills/add-test-case/SKILL.md`; these files are absent in this
checkout. Existing unittest conventions, project execution rules,
`run-bb-common`, and the deterministic verification runner were used instead.
