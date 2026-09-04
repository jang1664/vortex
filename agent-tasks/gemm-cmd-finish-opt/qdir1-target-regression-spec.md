# QDIR=1 target-shape regression spec

Status: **confirmed**

## Goal

Find the first commit that causes the existing
`M=4, N=256, K=256, QBLK=32, WTRANS=0, QDIR=1`
`gemm_node_improve` failure, determine the root cause, and fix it before
resuming the command-finish optimization verification.

## Reproducer

- simulator: configured-build VCS unittest
- config: `improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8`
- test: `hw/unittest/gemm_node_improve`
- current/baseline symptom: 1013 mismatches out of 1024 outputs
- first mismatch: `got=-0.046875`, `expected=-0.054688`

Every tested commit must use a newly generated build directory:

1. enter the new build directory;
2. run `../configure --xlen=64 --tooldir=/opt/vortex --prefix=/home/jaeyongjang/tools/vortex`;
3. run `make -C hw config`;
4. source the target config;
5. run the VCS unittest through `tools/verify_rtl.py`.

## Method

1. Inspect the relevant commit history and establish a known-bad endpoint.
2. Test older ancestors until a known-good endpoint is found.
3. Binary-search the good/bad range using the exact reproducer.
4. Inspect the first-bad diff and prove the causal RTL/test interaction.
5. Implement the smallest root-cause fix in the active worktree.
6. Re-run the target reproducer and command-finish regression suite.

## Constraints

- Do not reuse generated build output across commits.
- Do not modify the active command-finish RTL until the first-bad commit and
  root cause are established.
- Preserve the active worktree and all user changes.
- Under the hard rule, stop and report immediately if the investigation
  reveals a problem with the agreed command-finish architecture.
