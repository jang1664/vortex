# GEMM-shaped DMA diagnostic

Copy strided rows from DRAM to LMEM using the same 18-register MMIO DMA
descriptor ABI as the vector kernels and naive GEMM external DMA executor.
This runs on existing FPGA images; it does not invoke either MXU.

From a configured build directory:

```sh
ci/run_black.sh hw \
  --fpga-bin naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3_fix_sub_norm \
  --app gemm_dma_profile --power=off \
  --args '-r 128 -b 64 -s 7168 -t 32 -n 4 -p 2'
```

| Option | Meaning | Default |
|---|---|---:|
| `-r` | Rows per descriptor | 128 |
| `-b` | Bytes copied per row | 64 |
| `-s` | DRAM row stride in bytes | 7168 |
| `-t` | Consecutive K tiles | 32 |
| `-n` | Consecutive column tiles | 1 |
| `-p` | Repeated copies of each tile before advancing | 1 |

The source address is `base + k_tile * rows * stride + n_tile * row_bytes`.
Traversal is column tile, K tile, repeat. LMEM destination rows are contiguous.
An 8192-byte allocation prefix matches the usual K4096 GEMM input allocation
before the weight buffer; the resolved source address is printed.

All source data are deterministic integer patterns. Every copied 64-bit word
is verified after the timed interval, on every repeat. The host rejects
unaligned dimensions, tiles larger than 32 KiB, excessive result counts, and
source allocations larger than 256 MiB. Allocation/completion polling has a
one-million-cycle guard, reported through the per-sample status.

`setup_cycles` covers software descriptor allocation/programming up to the
post-kick timestamp. `kick_to_done_cycles` runs from that timestamp to observed
completion. Both use the device cycle CSR. They include MMIO ordering and
polling overhead and **are not the RTL executor's exact active-cycle counter**.
Use same-probe differences for controlled comparisons; do not add these
measurements directly to a pipelined GEMM's elapsed time.

The timed loop uses compiler barriers, not hardware FENCE. Vortex FENCE flushes
caches, which would invalidate a repeated-source cache experiment. The final
kernel fence publishes results after all timed intervals. With `-p 2`, even
samples are the first access to each tile and odd samples immediately repeat
that tile. Cache levels should be established from counters or address mapping,
not inferred solely from the labels "first" and "repeat".

To use RTL simulation, source the target config and replace `hw --fpga-bin ...`
with `xrt-vcs-sim`. Small `-r 16 -b 256 -s 28672 -t 1 -n 1 -p 2` cases are useful
for cache behavior checks without long simulation runtimes.
