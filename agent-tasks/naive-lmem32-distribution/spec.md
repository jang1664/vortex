# Generalized naive LMEM distribution

Status: confirmed; user authorized implementation.

## Contract

Derive distributed placement from LMEM_NUM_PORTS >= 2P+I+W+S+Z; no new macro. Lane counts are tensor bytes divided by LSU word bytes. Distributed offsets: PSUM read 0, write P (final shares first output lanes), Input 2P, Weight 2P+I, Scale 2P+I+W, Zero 2P+I+W+S. Preserve exact legacy placement/SZ sharing below the threshold. Extra GEMM ports inactive; retain CPU/DMA connectivity.

Ports and banks independently power-of-two. Ports >=2P, banks >=P. Preserve existing fanout/address constraints. Common naive-only placement constants drive connections, request classification and relative lane commit decoding. Separate S/Z memory lanes only, preserving scheduling and engine tag routing. Preserve bank addressing, layouts, read quota=1, buffer/slot depths and current single-cycle Input issue implementation. Preserve improve active RTL identity; no synthesis cost comparisons.

## Verification

Run frozen xrt-vcs-sim fpint_gemm_ffn_hw_naive for MXU16/TH16 ports/banks 16/16,32/16,16/32,32/32, each M4 and M256 with K=N512 and existing app arguments. Require PASS using tools/verify_rtl.py classification. Configured builds and ci/run_black.sh wrapper mandatory. Compile MXU32 32/32 and64/64. No reset-focused tests or synthesis.

Extract FSDB request classes/ports, S/Z separation, PSUM/final/DMA commits, Input stalls, PSUM latency, port/bank utilization and arbitration waits. Report DMA phase separately because DMA local width scales with port count. Verify improve active RTL identity and rerun M4/M256 under the original configuration to require zero GEMM/core-cycle delta, following the updated repository instructions. No automatic slot tuning or additional arbitration optimization.

## Outputs

New configs/naive_gemm_th16_b32_tcol16_hwexp_dcache_sxbar_f16.sh changes only port/bank counts. Preserve existing default config and total LMEM 1 MiB. Store runs and analysis here; latency doc cycle-only, separate detailed report with cycle/RTL annotations. No commit requested.
