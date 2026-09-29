# Synthesis launcher path fix

`configure` symlinks `build/ci/run_syn_hw.sh` to the source launcher. The
original launcher interpreted the link's parent as the repository root,
leading to config lookup failures or an erroneous `build/build` search.
The latter failure was reproduced with the original committed script.

The launcher now resolves the actual source path with `readlink -f` and
retains the invoked tree separately. Build selection precedence is:

1. `--build-dir`
2. `BUILD_DIR`
3. The build tree containing the invoked script link
4. The configured current directory when using the source entry point
5. The source repository's `build/` directory

Synthesis still runs in the selected build's `hw/syn/xilinx/xrt` directory.
Config files are resolved against the caller or source repository and
sourced from the source root to support nested relative config references.

Validation: shell syntax, `git diff --check`, and 12 regression tests passed:

```sh
python3 -m unittest discover -s ci/tests -p test_run_syn_hw.py -v
```

All four requested configs were also invoked through the actual configured
`build/ci/run_syn_hw.sh` link. A recording make stub confirmed the source
config path, synthesis working directory and environment. The TCU-only
profile had no SLR flag; the other three passed both GEMM_SLR_PIPELINE and
GEMM_MXU_SLR_FLOORPLAN=1. Isolated pathcheck log prefixes preserved any
existing synthesis logs. Raw invocation evidence is in verification.json.

No Vivado/v++ synthesis or placement/routing was launched. Existing worktree
changes outside this launcher task were preserved during implementation.
