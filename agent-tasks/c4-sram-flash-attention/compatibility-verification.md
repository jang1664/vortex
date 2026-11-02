# Feature-off C4 compatibility verification

Verified on 2026-10-23 with VCS W-2024.09-SP1, then refreshed after the FP32 ACC-export extension at 19:01. No RTL or main SRAM-fusion build artifacts were changed by this verification task.

## Inputs and isolation

The reference revision is `251fa5d5b0178c80ff5ca7d8e9bb3990a8e88bbb`. Both runs use the base rev8 C4 config, `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh`, without `GEMM_SRAM_FUSION`. Debug trace definitions are supplied by `ci/run_black.sh --debug 3` for blackbox runs.

`logs/compatibility_vcs/head` contains archived HEAD RTL and the HEAD GEMM node testbench. `logs/compatibility_vcs/current` starts from that archive with only the ten changed RTL files replaced by worktree copies, including the final changes to `VX_gemm_acc_internal.sv` and `VX_gemm_unit_v2.sv`. The same frozen HEAD node testbench is used for both. All ten current snapshot hashes matched the live worktree at the end of verification; `logs/compatibility_vcs/snapshot_fp32.json` records the hashes. The prior eight-file snapshot and evidence are retained as `current_pre_fp32`, `snapshot_pre_fp32.json`, and the original logs. The ten-file selected-source comparison is recorded separately in `logs/feature_off_identity_fp32/manifest.json`.

The isolated build directories are `build_c4_compat_head` and `build_c4_compat_current`. Both were configured using `../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`, with `/usr/bin/gcc` and `/usr/bin/g++` for host compilation. Separate socket ports and `VORTEX_SHM_PATH` values avoid cross-run runtime status interference.

## Numerical and cycle results

| Test | HEAD | Current | Difference |
|---|---|---|---|
| Legacy node M8/N128/K128, QBLK32, WTRANS0/QDIR0 | Numerical pass; completion 21,575 ns | Same | 0 node cycles |
| Back-to-back node first job M32/N64/K128 | Numerical pass; completion 26,905 ns | Same | 0 node cycles |
| Back-to-back node second job M32/N16/K256 | Numerical pass; completion 45,425 ns | Same | 0 node cycles |
| Full-core legacy GEMM M8/N128/K128 | Numerical pass; 6,334 instructions, 8,406 core cycles | Same | 0 core cycles |

The node test uses the unchanged unittest FPU implementation and random seed 1234. The full-core test uses the C4 Xilinx FPU path. Full-core numerical/cycle results were reproduced while extending simulator-only structural observation, with the same counts in all three initial runs. After the FP32 extension, the current full-core and both node workloads were rebuilt and rerun against the unchanged frozen HEAD evidence; all results remained identical. The HEAD, initial-current, and final-current `kernel.vxbin` hashes also match.

Node tests ran through `tools/verify_rtl.py`. The full-core workload ran through:

```sh
source ../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw \
  --args "-m 8 -n 128 -k 128 -q 32 -t 0 -d 0" --debug 3
```

Exact final wrapper setup is retained in `logs/compatibility_vcs/run_fullcore_fp32.sh`; node reports and the full-core app/simulator logs are in the same directory. The frozen HEAD logs have the `_v3` suffix; the final current logs have the `_fp32` suffix. `summary_fp32.json` joins the final source, structural, and numerical results. The isolated current simulator configuration stamp was explicitly invalidated before the refresh because its Makefile does not list RTL sources as target dependencies; the compile log confirms both newly changed modules were parsed.

## Elaborated structure

A simulator-only VPI callback loaded with `-debug_access+all` enumerates the elaborated hierarchy, port directions/connections, net/register widths, parameter values, SV variables, array dimensions, and first array-element widths. The final observer is `logs/compatibility_vcs/structure_vpi_v3.c`. It does not modify RTL or signal values.

The final whole-chip dumps contain **167,440 identical normalized records**, including:

- 6,011 modules and 616 interfaces;
- 41,778 ports and 56,361 nets;
- 42,392 parameters;
- 16,883 registers, 1,596 structs, 34 enums, and 475 register arrays.

The dump explicitly includes the GEMM FSM's eight-bit `state_q`, SRAM/queue array extents, and element widths. No fusion control, fusion DMA, or fusion metadata record is reachable in either feature-off elaboration. Normalization sorts and deduplicates records; it does not remove widths, parameter values, instance names, or connection expressions.

Both normalized dumps have SHA-256:

```text
d859c4efd1601f20b0aa77882a78e9139de4ef4309812a102de52216249e3fb2
```

`logs/compatibility_vcs/core_identity_fp32.json` records the final comparison against the unchanged HEAD dump. The earlier node-only dump also matched, but the final whole-chip dump supplies the broader evidence. VPI's generic `vpiVariables` iterator was necessary to observe SV enums/structs; the initial Verilog-only and type-specific iterations were insufficient. The earlier failed Verilator XML attempt remains recorded in `ordering-compatibility-audit.md`; it is not used as structural evidence.

## Scope of the conclusion

These results establish feature-off selected-source/declaration/connectivity identity and zero measured GEMM-node/core-cycle delta for the tested legacy workloads. Together with the existing preprocessed-source comparison, they show the feature adds no reachable fusion declarations to this C4 elaboration.

This is not a synthesized-netlist comparison or a formal sequential-equivalence proof. Raw simulator traces from independent runs were not byte-identical; no full waveform-identity claim is made. Legacy decoder regression, feature-on legacy behavior, upstream publication stress, and FPGA timing/performance remain separate requirements owned by the main task.
