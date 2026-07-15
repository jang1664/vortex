# TCU Synthesis Analysis

Generated: 2026-07-15T17:21:07+09:00

Build root: `/home/jaeyong.jang/project.local/research/vortex/build/hw/syn/synopsys/tcu`

## Run summary

| Run | Area (um^2) | Area (mm^2) | Cells | Seq. cells | Total power (mW) | WNS (ns) | Worst listed slack (ns) |
|---|---:|---:|---:|---:|---:|---:|---:|
| synthesis_th16/tcu_unit_bhf/syn_topo.lpp | 276,593.0284 | 0.276593 | 302,083 | 50,551 | 34.8300 | 0.0000 | 4.2400 |

## Functional hierarchy breakdown

### `synthesis_th16/tcu_unit_bhf/syn_topo.lpp`

| Category | Instances | Global area sum (um^2) | Mean area (um^2) | Top area share | Total power sum (mW) | Top power share |
|---|---:|---:|---:|---:|---:|---:|
| tcu_fp | 1 | 263,905.4317 | 263,905.4317 | 95.4129% | 33.3280 | 95.6876% |
| fp_fedp | 16 | 247,832.0894 | 15,489.5056 | 89.6017% | 31.4370 | 90.2584% |
| bhf_fp16_multiplier | 128 | 84,832.8390 | 662.7566 | 30.6706% | 9.7247 | 27.9205% |
| product_pipeline | 128 | 8,581.2480 | 67.0410 | 3.1025% | 1.9288 | 5.5378% |
| bhf_reduction_adder | 112 | 118,235.8710 | 1,055.6774 | 42.7472% | 15.1740 | 43.5659% |
| final_adder | 16 | 19,345.9500 | 1,209.1219 | 6.9944% | 1.9080 | 5.4780% |
| c_input_conversion | 16 | 2,324.6730 | 145.2921 | 0.8405% | 0.0649 | 0.1862% |
| c_pipeline | 16 | 14,483.6640 | 905.2290 | 5.2365% | 2.6340 | 7.5624% |

## Interpretation notes

- Area and power hierarchy values are cumulative subtree values. Summing parent and child categories together double-counts their descendants.
- `local_area_sum_um2` in the CSV counts only area directly owned by the matched hierarchy rows and is safe for module-family accounting.
- Synopsys power columns use mW for switching/internal/total power and uW for leakage power in these reports.
- The current power reports warn that primary inputs and sequential outputs are not fully annotated; treat power as vectorless synthesis estimates.
- `module_instances.csv` groups hierarchy rows after removing synthesis uniquification suffixes. It reports both cumulative global area and non-overlapping local area.
