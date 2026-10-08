# Original-storage / target-region GEMM verification

The C4 FSM uses original M/N/K for physical packed matrix addressing and
target M/N/K for computation. Existing DMA-tile-aligned M/N starts select a
submatrix; K starts at zero. No cache-specific RTL field or command ABI was added.

For each job:

```
C[m_start+i, n_start+j] = sum(A[m_start+i, k] * dequant(W[k, n_start+j]))
                         for k in [0, target_K)
i in [0, target_M), j in [0, target_N)
```

Partial M and partial final output beats use read-modify-write to preserve
logical C entries outside the region. Disjoint cores must own separate DMA
tiles; this does not support concurrent writers inside one DMA tile.

## Reproduce

From the repository root, after configuring `build/`:

```bash
python3 ci/test_gemm_submatrix.py --list
python3 ci/test_gemm_submatrix.py
```

The runner sources `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh`,
explicitly refreshes VCS RTL, and runs each case through
`build/ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --perf 3`.
`--cases`, `--build-dir`, `--config`, `--output`, and `--timeout` are available.
Do not run another simulation concurrently in the same build directory.

Example PV job with capacity 512 and changing active prefix:

```bash
cd build
source ../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --perf 3 \
  --args "-m 1 -n 128 -k 512 -q 128 -d 1 --target-k-list 256,288,320 --tagged"
```

The sequence packs/uploads A, W, scale, and zero point once, then changes target
registers without repacking. Inputs beyond each active prefix contain nonzero
address-dependent values. Each job checks numerical output against a CPU
reference with original strides and checks untouched logical C entries against
a sentinel. Reserved padding bytes outside logical C are not checked.

QK cases vary target N with K=128, WTRANS=1, QDIR=0, QBLK=128. PV cases vary
target K with N=128, WTRANS=0, QDIR=1, QBLK=128. Capacity 512/1024 and physical
tail 320 cover both full and partial third DMA tiles.

## Scope

- Verification targets TH16/MXU16. Original and target K/N must be MXU aligned;
  M may be arbitrary. M/N starts remain DMA-tile aligned (128 here).
- Physical operand DMA can fetch a whole final storage tile even when its
  compute prefix is shorter. Remaining capacity tiles are not computed.
- For token lengths not aligned to the execution granularity, software must
  neutralize the final active padding (and mask QK logits as appropriate).
- These are generic GEMM cases modeling future TVM packed KV use, not an
  implementation or end-to-end test of a dynamic TVM KV cache.
- PERF counters print at device close. A sequence case's cycle value describes
  its final job, not each prefix or the sum of the sequence.
- No PnR or hardware image rebuild is included.

See `RESULTS.md` for final verification results and `STATUS.yaml` for iterations.
