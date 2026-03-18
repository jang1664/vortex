set tool_dir $::env(TOOL_DIR)
source ${tool_dir}/xilinx_async_bram_patch.tcl

# Prevent opt_design from rewiring vortex_afu boundary pins (lopt optimization).
# Without this, opt_design replaces hierarchical pins (rvalid, bvalid, etc.)
# with lopt pins, breaking the original port interface and making post-impl
# simulation with cell-level SDF extremely difficult.
set vortex_cell [get_cells -hier -quiet -filter {NAME =~ "*vortex_afu_1"}]
if {[llength $vortex_cell] == 1} {
    set_property DONT_TOUCH true $vortex_cell
    puts "INFO: Set DONT_TOUCH on [get_property NAME $vortex_cell] to preserve boundary pins"
} else {
    puts "WARNING: Could not find unique vortex_afu_1 cell for DONT_TOUCH (found [llength $vortex_cell])"
}

# # Add extra setup margin to kernel clocks so Vivado optimizes harder.
set setup_margin_ns 1.0
foreach clk [get_clocks -quiet *kernel_00*] {
    set_clock_uncertainty -setup $setup_margin_ns $clk
    puts "INFO: Added ${setup_margin_ns}ns setup margin to clock [get_property NAME $clk]"
}

# add hold margin
# source $::env(VORTEX_HOME)/hw/syn/xilinx/xrt/apply_hold_margin.tcl


report_utilization -file hier_utilization.rpt -hierarchical -hierarchical_percentages
