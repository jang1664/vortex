# Llama3 inference through TVM

`run.py` is the Vortex entry point for the TVM `vortex_llama3` application.
The model, compiler passes, and inference loop stay in TVM; this launcher owns
Vortex paths, FPGA aliases, token-count arguments, and Slurm allocation.
It runs a **random-weight Llama3-8B, all 32 decoder layers**, using the C4
packed-KV path. It is an execution/numerics workload, not a language-quality
benchmark or a pretrained-checkpoint loader.

## Dependencies

The Vortex-enabled TVM fork is pinned at `third_party/tvm`:

```bash
git submodule update --init third_party/tvm
git -C third_party/tvm submodule update --init --recursive
```

Use `--tvm-home /path/to/tvm` (or `TVM_HOME`) to reuse a development checkout
and its existing build. The launcher does not download or rebuild dependencies.
Build TVM with LLVM and `USE_VORTEX` pointing at this Vortex build's
`runtime/libvortex.so`; follow TVM's `AGENTS.md` and
`apps/vortex_llama3/README.md` for compiler/Python prerequisites. Set
`--python` (or `TVM_PYTHON`) to the environment containing PyTorch, NumPy,
TVM-FFI, and the other TVM dependencies. The launcher sets `PYTHONPATH` and
`TVM_LIBRARY_PATH` to the selected checkout.

`--runtime-dir` must contain the **hardware** `libvortex.so` and
`libvortex-xrt.so`. A runtime built for XRT/VCS simulation is not interchangeable
with the hardware driver. `--profile-root` selects the LP64F toolchain/runtime
profile (default `/opt/vortex_profiles/rv64imaf_zfh_lp64f`).

The default FPGA alias is
`improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update`.
The existing alias resolver supplies its config, manifest, and xclbin. TVM
checks the manifest/profile and layout/submission ABI. This application requires
C4 fused packed KV with layout ABI 3 and GEMM submission ABI 3; other C1–C3
aliases are not supported by this entry point.

## Package, then run

From the Vortex root, **outside a Slurm allocation**:

```bash
python3 tests/apps/llama3/run.py \
  --tvm-home /path/to/built/tvm \
  --python /path/to/python \
  --runtime-dir /path/to/hardware/runtime \
  --prefill-tokens 32 --decode-steps 32 --cache-capacity 512 \
  --artifact-dir build/llama3_p32_c512
```

The default `--mode package-and-run` compiles outside Slurm, then requests one
U55C with `srun` for the entire inference. `--mode package` only compiles;
`--mode run` reuses an existing package. A run inside an existing allocation
uses that allocation and selects its sole accessible FPGA. Packaging inside an
allocation is rejected. Use `--partition` and `--time` to adjust Slurm options.

Packaging without `--archive-manifest` creates a synthetic parameter archive
under the artifact directory (about 5.35 GiB). Pass an existing compatible
archive's `manifest.json` to reuse it. Preserve external archives: the package
records their absolute paths.

`--prefill-tokens N` generates IDs `1..N`. For specific inputs, pass
`--prompt-token-ids '1,42,100,7'`; this overrides `--prefill-tokens`.
Semicolon-separated rows provide equally sized batches. IDs must be in
`[0, 128256)`. No tokenizer is involved.

`--decode-steps` is a fixed token count, not EOS-based maximum generation.
Prefill plus decode must fit the capacity. Prefill length, batch size, or
capacity changes require a new package; decode count can change without
recompilation. Use separate artifact directories for different compiled shapes.

Output defaults to `<artifact-dir>/inference.json`; override `--trace-output`
to retain multiple runs. It contains `generated_token_ids`, phase results,
timings, and model/runtime metadata. `--dry-run` checks paths and input shapes
and prints the commands without compiling, allocating an FPGA, or running it.
It does not prove TVM importability or hardware-driver compatibility.

## Reuse the validated local package

On the current development machine, from the Vortex root:

```bash
python3 tests/apps/llama3/run.py --mode run \
  --tvm-home /home/jaeyongjang/project.local/tvm \
  --python /home/jaeyongjang/.conda/envs/vortex/bin/python \
  --runtime-dir /home/jaeyongjang/project.local/tvm/build/c4_nodsp_fsm_update_20261007_220215/runtime \
  --prefill-tokens 32 --decode-steps 32 --cache-capacity 512 \
  --artifact-dir /home/jaeyongjang/project.local/tvm/build/packed_kv_validation_20261008/full32 \
  --trace-output build/llama3_p32_d32.json
```

The previous full-model run completed with matching generated IDs and passing
final-logit CPU comparisons. Some independent CPU-chain intermediate-state
checks failed; same-input replays passed. See TVM's
`docs/vortex_packed_kv_validation.md` for the precise numerical limits and
long-context coverage. The launcher does not enable expensive CPU reference or
per-layer snapshot diagnostics by default. Those remain available in TVM's
underlying application.
