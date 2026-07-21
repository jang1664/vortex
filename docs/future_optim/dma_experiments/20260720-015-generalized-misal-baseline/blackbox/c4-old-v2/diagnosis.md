# Corrected C4 Pre-Change Baseline

## Conclusion

The current valid C4 integration workload is `fpint_gemm_ffn_hw`, not `fpint_gemm_ffn_hw_naive`. Changing only the application name while retaining M=N=K=128 produces a bit-exact PASS on the same freshly compiled C4 `simv` and the same pre-change DMA RTL.

- Result: PASS
- Instructions: 6,975
- Cycles: 11,743
- IPC: 0.593971
- Effective QBLK/WTRANS/QDIR: 32/0/0
- RTL SHA-256: `17a425d1ddef7cf5e6a9d2ffafa45f75535631fe2af7286669782c321c890f1f`
- `simv` SHA-256: `f7ef7ee0f87c424363b966f6b4bae00e666f5ef4605b18bedfc3b4061743e17a`

Any candidate comparison must use this same application and command. With a strict 101% cycle gate, the integer cycle ceiling is 11,860 cycles.

## Why the Original Locked Workload Is Invalid Now

The C4 tensor DMA has eight 64-byte channels, so its source and destination addresses must select the same slot modulo 512 bytes. `VX_gemm_tmem_dma_ctrl.sv` enforces this by comparing address bits `[8:6]`.

The failed `_naive` run reached a weight transfer with:

```text
TMEM address: 0x1ffc12000 (slot 0 modulo 512)
DRAM address: 0x00018040 (slot 1 modulo 512)
```

This is structural, not a missing command-line option. The current `_naive` host uses ordinary `vx_mem_alloc` for its flat buffers, and its internal 64-byte weight sub-tile advance changes the channel slot. Keeping M=N=K=128 while adding explicit `-q 32 -t 0 -d 0` would generate the same addresses and fail the same assertion. Reducing N to avoid the second sub-tile could hide the problem, but would change the locked workload shape and would not establish a valid C4 baseline.

The canonical `fpint_gemm_ffn_hw` host instead uses 512-byte-aligned DRAM allocations, 512-byte-aligned TMEM regions, and tiled strides that retain matching channel slots. It also carries the current tiled GEMM argument layout and runtime DMA tile dimensions. This matches the repository's more recent C4 integration records in experiments 007 and 009.

The older July 18 record claiming `_naive` PASS at 12,137 cycles has no raw log or simulator image and is not reproducible with the pinned current source tree. It must remain characterization history, not the matched baseline denominator.

## Options and ABI

Both applications default to QBLK=32, WTRANS=0, and QDIR=0. Those options are therefore not required for this exact invocation. The corrected raw log prints the effective values, making the default ABI explicit without changing the original M/N/K argument string.

## Reproduction

The exact command is in `run_baseline.sh`. It checks the production RTL hash and the reused fresh C4 `simv` hash before running:

```bash
timeout --signal=TERM --kill-after=60s 30m \
  ./ci/run_black.sh xrt-vcs-sim \
  --app fpint_gemm_ffn_hw \
  --args '-m 128 -k 128 -n 128' \
  --cores 1
```

`raw_run.log` is the full wrapper/application log, `simv.log` is the simulator log, and `compile.log` is the compile log of the exact fresh C4 simulator inherited from the preserved failed attempt. The failed `_naive` run remains untouched in `../c4-old/`.
