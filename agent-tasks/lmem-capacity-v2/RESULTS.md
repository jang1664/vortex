# LMEM capacity correction

Scope: implement and verify before PnR. No synthesis, PnR, FPGA programming, or alias-map changes were performed.

| Profile | Corrected config | LMEM | ACC | TMEM |
|---|---|---:|---:|---:|
| C1 | `configs/tcu_th16_c1_v2.sh` | 2 MiB | — | — |
| C2 | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v2.sh` | 1.5 MiB | 512 KiB | — |
| C3 | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh` | 1.5 MiB | 512 KiB | — |
| C4 | `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2.sh` | 1 MiB | 512 KiB | 512 KiB |

C4's original ACC depth was 1024 (256 KiB). Its corrected copy uses 2048. Every corrected profile preserves all original non-memory settings, including C2/C3 cache banking and memory ports. Existing C4 DMA variants and historical FPGA aliases remain unchanged.

`LMEM_SIZE` is the physical byte capacity; `LMEM_LOG_SIZE` is its ceiling-log2 address envelope. C2/C3 use 1572864 and 21. With 16 banks and 8-byte words, each SRAM bank has 12288 entries and a 14-bit address. CPU classification and software allocation bounds use the physical size.

The XRT capability query returns the exact size using a capability marker and read-only register at 0xD0. Updated XRT software remains compatible with old bitstreams. Fractional-capacity bitstreams require the updated runtime.

## Reproduction

The configured builds and verification logs are retained locally. For example, from the repository root:

```bash
source configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v2.sh
cd build_lmem_capacity_verify
ci/run_black.sh xrt-vcs-sim --app lmem_capacity --args ""
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args "-m 2 -n 160 -k 160 -q 32 -d 1 -t 1 -r 2 --lmem-offset 1048576 --tagged"
```

The full per-profile matrix runner is `verify/run_matrix.py`. It expects the fresh configured build directories created for this task and the shared Xilinx simulation-library/IP cache. All full-system runs use `ci/run_black.sh xrt-vcs-sim`.

## Verification evidence

All verification checks passed:

- VCS LMEM 1/1.5/2 MiB: all-bank endpoints, 1 MiB boundary, partial writes, conflicts, response backpressure and tags. Absolute system addresses pass; an access in the unused envelope triggers the expected fatal range assertion.
- VCS ACC 512 KiB: all four banks at rows 0/1023/1024/2047 retain independent data.
- VCS capability register: fractional, legacy, explicit power-of-two and disabled-LMEM profiles; ignored writes and AXI read backpressure.
- Invalid geometry: incomplete bank rows emit the expected static error diagnostic. VCS returns zero for this initial `$error`, so the negative checker explicitly requires the diagnostic and retains the raw log. A wrong envelope (`LMEM_SIZE=1572864`, `LMEM_LOG_SIZE=20`) emits RTL diagnostics and is rejected by XRT's exact-capacity query.
- 34 xrt-vcs-sim matrix cases: all four exact CPU capacities, C1/C2 TCU32x32x32, C2/C3 naive GEMM in upper LMEM, C4 improve GEMM, QROW/QCOL, WTRANS0/1, small and 160x160 shapes, two launches, default scratch placement and malformed/out-of-capacity offsets.
- Original C4 comparison: baseline and candidate under the unchanged original config pass both launches. All 20 reported PERF lines match exactly; GEMM total cycles 288 and core cycles 6021, each with zero delta. Counters are the final kernel's device-close report, not separate per-launch dumps.
- Vivado IP-XACT metadata check: the 0xD0 exact-size register accepts its 32-bit read-only declaration. This check creates metadata only.
- Original C4 selected RTL: `VX_core`, `VX_gpu_pkg`, improve GEMM node/compute core and AFU are identical after preprocessing and comment/whitespace removal. LSU/mem-unit differ only in equivalent default capacity expressions; local-memory geometry remains 1 MiB, 16 banks, 8192 words/bank and 13-bit bank addresses, with only a false validation generate added. Evidence: [verify/rtl_identity_review.json](verify/rtl_identity_review.json). This is source/preprocessing/constant-geometry evidence; synthesis was not run.
- `git diff --check` passes. Existing alias-map content, original C4 config, and the pre-existing export-util change are preserved.

Independent review: [verify/independent_review.md](verify/independent_review.md).

Machine-readable aggregate: [verify/summary.json](verify/summary.json). Individual logs, config/source fingerprints and per-profile commands are archived in `verify/`.

No routed timing or resource measurements are available: synthesis and PnR were explicitly excluded from this task.

## Cache capacity alignment update

C1 now explicitly sets `ICACHE_SIZE=32768` and `DCACHE_SIZE=32768`, matching C2/C3/C4. Its previously implicit defaults were 16384 bytes each. All four current profiles have L2/L3 disabled. No cache-bank/port settings or RTL were changed in this update.

| Profile | LMEM | ACC | TMEM | I-cache | D-cache | Total data capacity |
|---|---:|---:|---:|---:|---:|---:|
| C1 | 2048 KiB | 0 | 0 | 32 KiB | 32 KiB | 2112 KiB |
| C2 | 1536 KiB | 512 KiB | 0 | 32 KiB | 32 KiB | 2112 KiB |
| C3 | 1536 KiB | 512 KiB | 0 | 32 KiB | 32 KiB | 2112 KiB |
| C4 | 1024 KiB | 512 KiB | 512 KiB | 32 KiB | 32 KiB | 2112 KiB |

These totals count configured data capacity, excluding cache tags, metadata, FIFOs/registers and FPGA primitive allocation overhead. Matching total implemented SRAM bits or BRAM counts requires a separate resource accounting step.

Verification for this update: shell syntax, generated configuration-header evaluation with all four sourced configs, exact totals of 2162688 bytes and `git diff --check` pass. Current configuration hashes and totals are in [verify/equal_sram_data_capacity.json](verify/equal_sram_data_capacity.json). The earlier VCS/blackbox receipts remain historical evidence for their recorded hashes; C1 functionality was not rerun after this cache update. No synthesis or PnR was performed.
