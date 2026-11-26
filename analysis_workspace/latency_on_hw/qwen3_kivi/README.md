# Qwen3-8B on U55C

Run from the repository root on the Slurm login host with a filesystem shared with the FPGA node. Choose a fresh tag for a new measurement. Reusing a tag allows the existing pipeline to resume using its receipts and original board identity.

```bash
analysis_workspace/latency_on_hw/qwen3_kivi/reproduce.sh paper_run
```

The default runs the RTL golden checks, a short U55C correctness and standalone QK session, the Llama3 and Qwen generator checks, the six-stage model pipeline, and the paper renderer. The coordinator reserves one U55C for the model sweep and uses that physical board for C1, C3 and C4. C2 uses the original C1/C3 composition. The separate kernel session can use another U55C. Each mode is also callable as the second argument.

| Mode | Work |
| --- | --- |
| `rtl-check` | VCS golden comparison with signed integer zero points, per-channel and group-varying parameters, and partial tiles. Checks Q-ROW transposed QK and standard PV at group size 32. |
| `board-check` | Ten U55C golden cases for Q/K head RMSNorm, dense and fused cache quantization and partial K-group updates. Measures standalone QK at exactly 1K, 8K and 32K. |
| `generate` | Generate workload suites using the Rev7 map. |
| `sweep` | Check 96 baseline SpinQuant and 96 Qwen generator payloads. Build the host/device software, run `generate → run → refine → compose → prepare → plot`, and export the model tables and paper figures. |
| `report` | Recreate the tables and paper figures from an existing tag's composed CSV, prepared tables and board identity records. |

## Prerequisites

- Set up the repository's RV64 Vortex toolchain, GCC/G++, GNU Make, XRT and Slurm with the `fpga` partition and `fpga:u55c:1` resource. Provision the Rev7 images and matching manifests, clock info and config files named in [the candidate map](../candidate_fpga_bins.rev7.yaml). To relocate them, set `VORTEX_FPGA_BIN_ALIAS_MAP` to the corresponding alias map.
- Initialize the pinned third-party dependencies (`git submodule update --init --recursive -- third_party/axi third_party/cvfpu third_party/softfloat`), install the AXI Bender dependencies, and build SoftFloat (`make -C third_party softfloat`). Alternatively set `THIRD_PARTY_DIR` to a prepared tree at the same pins. `TOOLDIR` defaults to `/opt/vortex`, `XILINX_XRT` to `/opt/xilinx/xrt`.
- For the RTL check load VCS, Vivado and their licenses. The project makefiles build the Xilinx FPGA **simulation** libraries locally. Set `SIMLIB_DIR` to reuse an installed VCS simulation library and `XILINX_IP_DIR` for a prepared set of matching floating-point simulation IP.
- Set `PYTHON` to the experiment interpreter. The reference environment used Python 3.13.9, NumPy 2.3.5, pandas 2.3.3, PyYAML 6.0.3 and Matplotlib 3.10.6. Paper export uses `pdflatex` (standalone, TeX Gyre Termes and Heros) and Poppler's `pdftoppm`.

## Measurement and figures

The generator uses the Qwen3-8B model dimensions and benchmark inputs. The 36-layer workload includes headwise Q/K RMSNorm before RoPE. Weights use asymmetric W4 g128, Q-COL and standard load. The KV format uses FP16 scales, signed integer INT4 zero points, g32 and R=0. K groups span tokens within a channel. V groups span channels within a token. Each decode step stages the new K and requantizes the 1–32 valid tokens in its current group. KV GEMMs round the cache dimension up to 32, or to 128 for C3 above 8192. RoPE and softmax use the logical length. The benchmark uses FP16 activations and requires no model download. [Model config](https://huggingface.co/Qwen/Qwen3-8B/blob/main/config.json)

The Rev7 bitstreams use Rev5 v2 accounting in prefill and decode, including head reorders and the TCU V transpose. TTFT uses B1. Mean TPOT averages 128 steps for B1/4/64, with interval-32 sampling and refinement. Both stages sweep 1K–32K by powers of two. The latency filter, power sampler and dequant energy corrections come from the common flow. The paper energy metric is `power_fpga_dequant_dynamic_W`. This experiment measures performance with integer ZP, W4/KV4 and no FP16 residual window. [Cost conventions](../docs/rev5_v2/README.md)

All generated files go under `analysis_workspace/latency_on_hw/outputs_qwen3_kivi_<tag>/`. The paper panels are `paper_format/qwen3_latency.pdf` and `paper_format/qwen3_energy.pdf`, normalized to C4. Absolute values are in `model_numbers.csv`, `TTFT_TPOT_breakdown_ms.csv` and `energy_breakdown_J_per_token.csv`. The two kernel comparisons are `kernel_latency/decode_qk_first_step.csv` (first model step, initial context plus one token, then padded) and `kernel_latency/decode_qk.csv` (standalone exact lengths).
