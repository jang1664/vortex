set tool_dir $::env(TOOL_DIR)
source ${tool_dir}/xilinx_async_bram_patch.tcl

# # Add extra setup margin to kernel clocks so Vivado optimizes harder.
# # Without this, Vivado stops optimizing at WNS ~0 and the design runs
# # with essentially zero margin on silicon.
# # Adjust the value (in ns) as needed: 0.5ns = 500ps extra guard band.
# set setup_margin_ns 0.3

# foreach clk [get_clocks -quiet *kernel_00*] {
#     set_clock_uncertainty -setup $setup_margin_ns $clk
#     puts "INFO: Added ${setup_margin_ns}ns setup margin to clock [get_property NAME $clk]"
# }

# 2) 특정 RTL 블록에만 hold margin
set hold_margin_ns 0.1
set cache_regs [get_cells -hier -filter {
  IS_SEQUENTIAL &&
  REF_NAME =~ "FD*" &&
  NAME =~ "level0_i/ulp/vortex_afu_1/inst/afu_wrap/vortex_axi/*"
}]
set cache_src  [get_pins -of_objects $cache_regs -filter {REF_PIN_NAME == "C"}]
set cache_dst  [get_pins -of_objects $cache_regs -filter {REF_PIN_NAME == "D"}]

set_min_delay $hold_margin_ns -from $cache_src -to $cache_dst

report_utilization -file hier_utilization.rpt -hierarchical -hierarchical_percentages