# Naive SLR implementation

## Placement

The backend comes from CONFIGS (`GEMM_NAIVE`) and is exported as VORTEX_GEMM_BACKEND. The naive root is the core containing gemm_node_naive/u_VX_gemm_compute_core/u_mxu. CPU siblings are explicitly unassigned rather than assigned by a default SLR1 rule.

| Region | Owned implementation |
| --- | --- |
| SLR0 | u_VX_dma_node, DMA-side MMIO/memory endpoints, request drain reduction |
| SLR1 | mem_unit (including LMEM), naive node except MXU-side endpoints, commit decode |
| SLR2 | u_mxu and MXU input RX, weight RX, output TX |

Mixed transport wrappers never become homogeneous hierarchy anchors. Requests and responses reverse ownership. Boundary Q-to-D checks cover credit return as well as payload. Commit uses continuous bank event bits; PERF uses a continuous same-clock snapshot. Clock/reset infrastructure exceptions remain narrow. External CPU/cache connections are reported separately and are not claimed as fully partitioned paths.

## Functional contract

The new VX_naive_dma_slr wrapper uses four-credit same-clock transports without extra launch storage. Memory packets retain all fields, and MMIO retains all lane masks and tags. LMEM crossing occurs after the existing aggregate-beat splitter.

DMA completion requires both existing write-fence drain and transport request drain. Returned credits prove the old downstream request-acceptance boundary has been reached; global request acceptance is not claimed to be HBM persistence. Offers not yet accepted also prevent drain. LMEM physical bank commits retain their own fence accounting.

The common MXU SLR pipeline behavior is unchanged. A GEMM_NAIVE-only DONT_TOUCH attribute preserves its weight TX register against BRAM output-register absorption; improve and SLR-off selection remain unchanged. New source is fully preprocessor-guarded, including its header, so improve does not receive extra DPI declarations. Improve preprocessing matches the before snapshot in 1148 checks (SLR on/off and assertion-build variants).

## Validation evidence

Raw runs and source manifests live under runs/; unit results under verify/unit_results.json. These are local artifacts. Tcl logs are in build_naive_slr_tcl. Twelve Tcl suites passed, including naive geometry/ownership/required-group/direct-pair negative cases and all original improve suites. Fifteen Vitis INI/build tests passed; one stable-mtime case was rerun after an intentional concurrent Tcl source edit.

The legacy naive_node_integration test checks reset/quiescence only. Naive SLR-off preprocessing matches the snapshot in 574 checks. Active functionality is instead checked by packet transport tests, the actual DMA-node bridge scenario, and the full blackbox matrix.

## Physical run

Use the configured main build and the user-selected wrapper, with fresh output prefix:

```sh
PLATFORM=/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm \
  build/hw/syn/xilinx/xrt/run_hw.sh --config naive_th16_tcol16_m16_L16_bigmem_all_bram --postfix naive_slr_100m_v4 --slr-floorplan 1 --no-early-fail FAST_MODE=0
```

The wrapper sources the config, runs from build/hw/syn/xilinx/xrt, and selects the U55C 202210 platform and 100 MHz target. PERF and DEBUG are omitted. Launch only after functional gates and improve cycle comparison pass. Capture first source-driven physical result; do not relax boundary checks or retry physical optimization automatically.

The installed Vitis platform lookup reports duplicate matches for the bare platform name, even with a single PLATFORM_REPO_PATHS entry. The absolute .xpfm resolves successfully. run_hw.sh now honors PLATFORM from the environment and derives its output directory from the platform basename, matching the Makefile. Stub-make checks passed for both name and absolute-path inputs (verify/run_hw_platform.json).

## Physical-hook corrections

The first full synthesis exposed 4,262 anonymous DMA-wrapper LUTs. A naive-only output-cone proof now recovers all 4,270 anonymous LUTs (including eight previously recovered feedback helpers), rejecting mixed ownership, ports, unknown sinks, cycles, marked logic and multiple drivers. All recovered incident nets enter the crossing audit, including edges invisible at hierarchy ports. Large known-owner maps use arrays; required-group presence tests normalize once and stop at a witness. On representative real names, one former full scan took 36.23 seconds while all 92 replacement checks took 66.47 seconds.

The source-DCP direct-pair audit next found 256 weight RX bits driven by BRAM DOUT because synthesis absorbed weight TX into BRAM output registers. A naive-only DONT_TOUCH register attribute fixes this without changing RTL behavior. A 32-bit BRAM synthesis fixture proves separate marked TX/RX FFs and direct Q-to-D connections. The separate attribute-preserve-v1 gate passes 15 checks, including 1148 improve exact comparisons, 1148 naive comparisons allowing only this exact synthesis attribute, two fresh VCS runs with unchanged cycles and drained retirement, and live/source hash identity. Original matrix evidence is retained.

V1 stopped on the ownership assertion. V2 was intentionally stopped to correct measured validation runtime. V3 was stopped after the source-DCP FF absorption finding. V4 is a fresh synthesis through run_hw.sh using --postfix naive_slr_100m_v4; earlier Tcl-only attempts used the wrapper with VPP_FLAGS=--from_step vpl.impl. These corrections do not change placement directives or perform physical timing optimization.

Fresh V4 full-kernel preflight passes with 4,285 recovered anonymous LUTs, 15,664 marked FFs and 7,922 direct pair rows. The actual stitched design also passes post-init ownership, required groups, direct FF pairs and the owned-boundary audit. Its boundary report contains only the header; CPU/platform connections are retained in the separate external-net report. Initial QoR predicts a timing challenge, which is not a placed/routed timing result. V4 later completed placement with WNS -17.970 ns, then was interrupted during post-place reporting before routing. The fresh two-strategy comparison completed on 2026-09-14: both base and SLR failed routing. See [the final comparison](strategy-comparison/results.md); no further experiments are planned.
