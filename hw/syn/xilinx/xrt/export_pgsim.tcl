# Export post-impl funcsim netlist for gate-level simulation
#
# Usage:
#   vivado -mode batch -source export_pgsim.tcl -tclargs <xpr_path> [out_dir]
#
# Example:
#   vivado -mode batch -source hw/syn/xilinx/xrt/export_pgsim.tcl \
#     -tclargs build/hw/syn/xilinx/xrt/.../prj.xpr /tmp/gate_sim

if {$argc < 1} {
    puts "Usage: vivado -mode batch -source export_pgsim.tcl -tclargs <xpr_path> \[out_dir\]"
    exit 1
}

set xpr_path [lindex $argv 0]
if {$argc >= 2} {
    set out_dir [file normalize [lindex $argv 1]]
} else {
    set out_dir [file join [pwd] "gate_sim"]
}
file mkdir $out_dir

open_project $xpr_path
open_run impl_1

set vortex_cell [get_cells -hier -quiet -filter {NAME =~ "*vortex_afu_1"}]
if {[llength $vortex_cell] != 1} {
    error "ERROR: Could not find unique vortex_afu_1 cell"
}

set funcsim_path [file join $out_dir "vortex_afu_funcsim.v"]
puts "INFO: Writing funcsim netlist: $funcsim_path"
write_verilog -mode funcsim -cell $vortex_cell -force $funcsim_path

puts "INFO: Export complete -> $funcsim_path"
close_design
close_project
