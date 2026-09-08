# Available hardware evidence

Inspected 2026-09-08. These artifacts belong to an older eight-port MXU16 build,
not the current MXU32 hbm4_tmem8/hbm8_tmem8 verification configurations. They are
evidence about that linked design only; compatibility has not been established.

Artifact root (relative to repository):

`build/hw/syn/xilinx/xrt/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem_v2_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/`

## Clocks

`bin/vortex_afu.xclbin.info`, lines 37–66, reports:

- Scalable `hbm_aclk`: 450 MHz.
- Scalable `KERNEL_CLK`: 500 MHz.
- Scalable `DATA_CLK`: 86 MHz.
- `ulp_ucs_aclk_kernel_00`: default 300 MHz, requested 100 MHz, achieved 86.4 MHz.

The HWH below declares HBM IP parameters `AXI_CLK_FREQ=450`,
`AXI_CLK1_FREQ=450`, `HBM_CLK_FREQ_0=900`, `HBM_CLK_FREQ_1=900`, and two stacks.
These are linked artifact configuration values, not new hardware measurements.

This evidence distinguishes the kernel's default 300 MHz clock from HBM AXI
450 MHz and physical HBM 900 MHz in this older platform/design. The current
simulation's user-selected 300 MHz HBM AXI and 1000 ps DRAM preset are **not
calibrated to those artifact clocks**. Preserve that discrepancy explicitly.

## HMSS internal paths

Inspected XML by streaming module and bus-interface records from:

`_x/link/vivado/vpl/prj/prj.gen/my_rm/bd/ulp/ip/ulp_hmss_0_0/bd_0/hw_handoff/ulp_hmss_0_0.hwh`

The HBM IP exposes 256-bit slave interfaces with these connected buses:

| HMSS external interface | SmartConnect path | HBM ingress |
| --- | --- | --- |
| S00_AXI | path_13_interconnect0_13 | SAXI_13_8HI |
| S01_AXI | path_0_interconnect1_0 | SAXI_00_8HI |
| S02_AXI | path_4_interconnect2_4 | SAXI_04_8HI |
| S03_AXI | path_8_interconnect3_8 | SAXI_08_8HI |
| S04_AXI | path_12_interconnect4_12 | SAXI_12_8HI |
| S05_AXI | path_16_interconnect5_16 | SAXI_16_8HI |
| S06_AXI | path_20_interconnect6_20 | SAXI_20_8HI |
| S07_AXI | path_24_interconnect7_24 | SAXI_24_8HI |
| S08_AXI | path_28_interconnect8_28 | SAXI_28_8HI |

Each external path enters a 512-bit SmartConnect slave and exits a 256-bit
master, then crosses a register slice and AXI VIP before the HBM ingress.
Bus names connect each listed path through its matching slice/VIP instance.

The outer `_x/link/vivado/vpl/prj/prj.gen/my_rm/bd/ulp/hw_handoff/ulp.hwh`
was subsequently inspected. Its shared BUSNAME records connect kernel
`m_axi_mem_0..7` to HMSS `S01_AXI..S08_AXI`, respectively. S00 instead connects
to `axi_vip_data_M_AXI`, the shell-side path. Combining the two handoffs proves
kernel port N reaches HBM ingress 4*N through the listed converter/slice/VIP
chain **for this older linked design**.

The same build's `xrt_backup/vitis.gen.ini` specifies port N reachability
`HBM[4*N:4*N+3]` for all eight ports, matching the current eight-port manifest's
address ranges. Its requested kernel frequency is 100 MHz. Port widths and
address reachability match, but this does not prove all current implementation
settings, timing or physical placement are equivalent. Four-port physical
ingress assignments remain unverified, and the model does not yet consume this
artifact-derived path profile.

## Remaining evidence gaps

- No matching hbm4_tmem8/hbm8_tmem8 HWH or xclbin.info was found in the targeted
  `build/hw/syn/xilinx/xrt` filename search. This is not a claim that none exists
  anywhere else in the workspace.
- No measured directed latency/bandwidth dataset has yet been associated with
  these exact paths and clocks.
- Current model remains explicitly abstract; this discovery is not sufficient
  to claim verified wiring or U55C performance fidelity for its default profile.
