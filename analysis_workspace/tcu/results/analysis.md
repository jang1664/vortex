# TCU Synthesis Analysis

Generated: 2026-07-15T11:57:31+09:00

Build root: `/home/jaeyong.jang/project.local/research/vortex/build/hw/syn/synopsys/tcu`

## Run summary

| Run | Area (um^2) | Area (mm^2) | Cells | Seq. cells | Total power (mW) | WNS (ns) | Worst listed slack (ns) |
|---|---:|---:|---:|---:|---:|---:|---:|
| synthesis/tcu_unit/syn_topo.lpp | 145,309.4354 | 0.145309 | 148,669 | 25,407 | 14.7940 | 0.0000 | 4.2100 |
| synthesis/tcu_unit_dw/syn_topo.lpp | 170,667.7806 | 0.170668 | 148,355 | 42,955 | 18.9410 | 0.0000 | 1.1300 |
| synthesis_th16/tcu_unit_bhf/syn_topo.lpp | 524,719.6055 | 0.524720 | 549,149 | 82,723 | 53.8260 | 0.0000 | 4.2100 |
| synthesis_th32/tcu_unit_bhf/syn_topo.lpp | 1,042,243.1261 | 1.042243 | 1,094,267 | 161,919 | 111.9790 | 0.0000 | 3.9400 |
| synthesis_th32/tcu_unit_dw/syn_topo.lpp | 1,166,558.6636 | 1.166559 | 1,051,046 | 267,013 | 139.7400 | 0.0000 | 1.1600 |

## Functional hierarchy breakdown

### `synthesis/tcu_unit/syn_topo.lpp`

| Category | Instances | Global area sum (um^2) | Mean area (um^2) | Top area share | Total power sum (mW) | Top power share |
|---|---:|---:|---:|---:|---:|---:|
| tcu_fp | 1 | 94,250.0512 | 94,250.0512 | 64.8616% | 9.1970 | 62.1671% |
| tcu_int | 1 | 39,021.2544 | 39,021.2544 | 26.8539% | 4.4020 | 29.7553% |
| fp_fedp | 8 | 88,007.1652 | 11,000.8957 | 60.5653% | 8.5830 | 58.0168% |
| int_fedp | 8 | 34,117.5502 | 4,264.6938 | 23.4792% | 3.8190 | 25.8145% |
| bhf_fp16_multiplier | 32 | 21,244.8600 | 663.9019 | 14.6204% | 2.3462 | 15.8591% |
| bhf_bf16_multiplier | 32 | 21,030.8670 | 657.2146 | 14.4732% | 2.0159 | 13.6265% |
| product_pipeline | 32 | 2,280.0960 | 71.2530 | 1.5691% | 0.4229 | 2.8586% |
| bhf_reduction_adder | 24 | 25,861.4460 | 1,077.5602 | 17.7975% | 1.9539 | 13.2074% |
| final_adder | 8 | 9,672.2730 | 1,209.0341 | 6.6563% | 0.7284 | 4.9236% |
| c_input_conversion | 8 | 1,162.5120 | 145.3140 | 0.8000% | 0.0257 | 0.1740% |
| c_pipeline | 8 | 5,573.8800 | 696.7350 | 3.8359% | 1.0150 | 6.8609% |
| format_pipeline | 8 | 165.6720 | 20.7090 | 0.1140% | 0.0303 | 0.2051% |

### `synthesis/tcu_unit_dw/syn_topo.lpp`

| Category | Instances | Global area sum (um^2) | Mean area (um^2) | Top area share | Total power sum (mW) | Top power share |
|---|---:|---:|---:|---:|---:|---:|
| tcu_fp | 1 | 122,007.3644 | 122,007.3644 | 71.4882% | 13.5010 | 71.2792% |
| tcu_int | 1 | 38,831.8314 | 38,831.8314 | 22.7529% | 4.4430 | 23.4571% |
| fp_fedp | 8 | 106,692.2984 | 13,336.5373 | 62.5146% | 12.7850 | 67.4991% |
| int_fedp | 8 | 33,930.5842 | 4,241.3230 | 19.8811% | 3.8540 | 20.3474% |
| dw_fp16_input_converter | 64 | 3,744.0000 | 58.5000 | 2.1937% | 0.0921 | 0.4860% |
| dw_bf16_input_converter | 64 | 479.2320 | 7.4880 | 0.2808% | 0.0194 | 0.1027% |
| product_pipeline | 32 | 17,308.5120 | 540.8910 | 10.1416% | 3.0744 | 16.2315% |
| dw_reduction_pipeline | 24 | 17,833.6080 | 743.0670 | 10.4493% | 3.2980 | 17.4120% |
| c_pipeline | 8 | 16,727.2552 | 2,090.9069 | 9.8011% | 3.0140 | 15.9126% |

### `synthesis_th16/tcu_unit_bhf/syn_topo.lpp`

| Category | Instances | Global area sum (um^2) | Mean area (um^2) | Top area share | Total power sum (mW) | Top power share |
|---|---:|---:|---:|---:|---:|---:|
| tcu_fp | 1 | 355,870.0050 | 355,870.0050 | 67.8210% | 34.9050 | 64.8478% |
| tcu_int | 1 | 146,060.5749 | 146,060.5749 | 27.8359% | 16.1450 | 29.9948% |
| fp_fedp | 16 | 339,603.6118 | 21,225.2257 | 64.7210% | 32.9360 | 61.1898% |
| int_fedp | 16 | 133,476.0554 | 8,342.2535 | 25.4376% | 14.2360 | 26.4482% |
| bhf_fp16_multiplier | 128 | 85,007.6370 | 664.1222 | 16.2006% | 9.0906 | 16.8889% |
| bhf_bf16_multiplier | 128 | 84,152.0160 | 657.4376 | 16.0375% | 7.7568 | 14.4109% |
| product_pipeline | 128 | 9,126.0000 | 71.2969 | 1.7392% | 1.7202 | 3.1959% |
| bhf_reduction_adder | 112 | 120,775.9410 | 1,078.3566 | 23.0172% | 9.6150 | 17.8631% |
| final_adder | 16 | 19,346.7690 | 1,209.1731 | 3.6871% | 1.4814 | 2.7522% |
| c_input_conversion | 16 | 2,325.1410 | 145.3213 | 0.4431% | 0.0587 | 0.1091% |
| c_pipeline | 16 | 14,483.6640 | 905.2290 | 2.7603% | 2.6350 | 4.8954% |
| format_pipeline | 16 | 331.3440 | 20.7090 | 0.0631% | 0.0607 | 0.1127% |

### `synthesis_th32/tcu_unit_bhf/syn_topo.lpp`

| Category | Instances | Global area sum (um^2) | Mean area (um^2) | Top area share | Total power sum (mW) | Top power share |
|---|---:|---:|---:|---:|---:|---:|
| tcu_fp | 1 | 706,797.1110 | 706,797.1110 | 67.8150% | 72.1800 | 64.4585% |
| tcu_int | 1 | 291,289.8649 | 291,289.8649 | 27.9484% | 34.5270 | 30.8335% |
| fp_fedp | 32 | 679,582.6766 | 21,236.9586 | 65.2039% | 67.7060 | 60.4631% |
| int_fedp | 32 | 266,973.7558 | 8,342.9299 | 25.6153% | 30.1880 | 26.9586% |
| bhf_fp16_multiplier | 256 | 170,007.2010 | 664.0906 | 16.3117% | 18.8833 | 16.8633% |
| bhf_bf16_multiplier | 256 | 168,291.5130 | 657.3887 | 16.1470% | 16.2120 | 14.4777% |
| product_pipeline | 256 | 18,271.1880 | 71.3718 | 1.7531% | 3.5126 | 3.1368% |
| bhf_reduction_adder | 224 | 241,867.7820 | 1,079.7669 | 23.2065% | 19.4833 | 17.3991% |
| final_adder | 32 | 38,695.7610 | 1,209.2425 | 3.7127% | 2.9480 | 2.6326% |
| c_input_conversion | 32 | 4,650.0480 | 145.3140 | 0.4462% | 0.1102 | 0.0984% |
| c_pipeline | 32 | 28,967.3280 | 905.2290 | 2.7793% | 5.2990 | 4.7321% |
| format_pipeline | 32 | 662.6880 | 20.7090 | 0.0636% | 0.1215 | 0.1085% |

### `synthesis_th32/tcu_unit_dw/syn_topo.lpp`

| Category | Instances | Global area sum (um^2) | Mean area (um^2) | Top area share | Total power sum (mW) | Top power share |
|---|---:|---:|---:|---:|---:|---:|
| tcu_fp | 1 | 840,397.6514 | 840,397.6514 | 72.0408% | 100.3400 | 71.8048% |
| tcu_int | 1 | 291,101.6119 | 291,101.6119 | 24.9539% | 35.1210 | 25.1331% |
| fp_fedp | 32 | 807,438.8694 | 25,232.4647 | 69.2155% | 96.0540 | 68.7377% |
| int_fedp | 32 | 266,768.1868 | 8,336.5058 | 22.8680% | 30.7550 | 22.0087% |
| dw_fp16_input_converter | 512 | 29,952.4680 | 58.5009 | 2.5676% | 0.7403 | 0.5298% |
| dw_bf16_input_converter | 512 | 3,833.8560 | 7.4880 | 0.3286% | 0.1569 | 0.1123% |
| product_pipeline | 256 | 138,469.0320 | 540.8947 | 11.8699% | 24.6866 | 17.6661% |
| dw_reduction_pipeline | 224 | 166,447.0080 | 743.0670 | 14.2682% | 31.9030 | 22.8303% |
| c_pipeline | 32 | 90,702.8428 | 2,834.4638 | 7.7752% | 16.4170 | 11.7482% |

## Interpretation notes

- Area and power hierarchy values are cumulative subtree values. Summing parent and child categories together double-counts their descendants.
- `local_area_sum_um2` in the CSV counts only area directly owned by the matched hierarchy rows and is safe for module-family accounting.
- Synopsys power columns use mW for switching/internal/total power and uW for leakage power in these reports.
- The current power reports warn that primary inputs and sequential outputs are not fully annotated; treat power as vectorless synthesis estimates.
- `module_instances.csv` groups hierarchy rows after removing synthesis uniquification suffixes. It reports both cumulative global area and non-overlapping local area.
