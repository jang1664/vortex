# LMEM reduction and request-order diagnostics

This app isolates local-memory dependencies from the LLM workload. It stores
results only after the loop; no device printf or per-iteration comparison is
inserted into the tested path. Inputs and expected sums are exactly representable
in FP32. The host rejects invalid launches and compares every output exactly.

| `--mode` | Operation |
|---|---|
| `int` | Own-lane `sw → lw → integer accumulation` |
| `fp32` (default) | Own-lane `fsw → flw → FP32 accumulation` |
| `fp16` | Partial-mask hardware H2S conversion followed by own-lane FP32 RAW |
| `warp` | The softmax helper's register-only XOR reduction |
| `lmem-warp` | Own-lane LMEM store/reload followed by that XOR reduction |
| `peer` | Store, workgroup barrier, read another lane's value, accumulate |
| `tree` | In-place cross-lane LMEM butterfly with barriers between stages |
| `exchange` | Adjacent `fsw` to own slot and `flw` from the opposite half-warp's slot |

`exchange` with `--fence 0` deliberately probes whether warp instruction order
alone preserves cross-lane visibility. It is a diagnostic, not a portable
inter-thread synchronization pattern, and fails on the current C4 image when
all lanes target one bank. The default `fp32` mode is a correctness regression.
A barrier or fence passing one workload does not establish a universal LMEM
drain guarantee.

Arguments: `--iterations` (1–4096, default 128), `--groups` (1–4096, default 12),
`--active` (0 varies causal-tail/full-warp masks), `--stride` (float elements,
default 1), `--gap` (0 or 8 NOPs), `--fence` (0 or 1), `--warps` (1 or 2).
Only `peer` and `tree` support two-warp workgroups; cross-lane modes always use
all lanes. `fp16` exercises the hardware converter when Zfh is enabled.

On the tested XLEN64/TH16 C4, there are 16 LMEM banks and an 8-byte bank word.
`--stride 2` gives each lane a distinct bank; `--stride 32` puts every lane in
bank zero at a distinct word. Threads use disjoint per-workgroup scratch ranges.

Run from a configured build directory after reconfiguring to create this app's
generated Makefile:

```bash
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
source ../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh

# Small RTL repro: current C4 fails this diagnostic.
bash ci/run_black.sh xrt-vcs-sim --app lmem_reduction_raw \
  --args '--mode exchange --iterations 2 --groups 4 --stride 32 --fence 0'

# Same shape with distributed banks: PASS.
bash ci/run_black.sh xrt-vcs-sim --app lmem_reduction_raw \
  --args '--mode exchange --iterations 2 --groups 4 --stride 2 --fence 0'

# Hardware repro; wrapper sources the alias config and allocates one FPGA.
bash ci/run_black.sh hw \
  --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_fp16_fix \
  --app lmem_reduction_raw \
  --args '--mode exchange --iterations 128 --groups 64 --stride 32 --fence 0'
```

Change `--fence 0` to `--fence 1` for the measured fence differential. Use
`--mode tree --warps 1` versus `--mode tree --warps 2` to compare workgroup
barriers. Full results and a direct RTL admission/commit trace are in
`analysis_workspace/latency_on_hw/docs/softmax_rev3_debug_20261003/LMEM_RAW_DIAGNOSIS.md`.
