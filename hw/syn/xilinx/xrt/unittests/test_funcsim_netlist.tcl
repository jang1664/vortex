# Generate funcsim netlist for vortex_afu and check structure
#
# Usage:
#   vivado -mode batch -source test_funcsim_netlist.tcl -tclargs <xpr_path> <out_dir>

if {$argc < 2} {
    puts "Usage: vivado -mode batch -source test_funcsim_netlist.tcl -tclargs <xpr_path> <out_dir>"
    exit 1
}

set xpr_path [lindex $argv 0]
set out_dir  [lindex $argv 1]
file mkdir $out_dir

set ::fh [open [file join $out_dir "test_funcsim_results.txt"] w]
proc log {msg} {
    puts $::fh $msg
    flush $::fh
    puts $msg
}

open_project $xpr_path
open_run impl_1

set vortex_cell [get_cells -hier -quiet -filter {NAME =~ "*vortex_afu_1"}]
log "=== Funcsim netlist generation ==="
log "Cell: [get_property NAME $vortex_cell]"
log ""

# 1. Generate funcsim netlist (no timing, functional only)
set netlist_path [file join $out_dir "vortex_afu_funcsim.v"]
log "--- write_verilog -mode funcsim -cell ---"
set t0 [clock seconds]
write_verilog -mode funcsim -cell $vortex_cell -force $netlist_path
set t1 [clock seconds]
set sz [file size $netlist_path]
log "  file: $netlist_path"
log "  size: [expr {$sz / 1024 / 1024}] MB ($sz bytes)"
log "  time: [expr {$t1 - $t0}] sec"
log ""

# 2. Check the netlist top module and ports
log "--- Netlist header (first 50 lines) ---"
set nfh [open $netlist_path r]
for {set i 0} {$i < 50} {incr i} {
    if {[gets $nfh line] >= 0} {
        log "  $line"
    }
}
close $nfh
log ""

# 3. Count modules in netlist
log "--- Module count ---"
set nfh [open $netlist_path r]
set module_count 0
set module_names {}
while {[gets $nfh line] >= 0} {
    if {[regexp {^module\s+(\S+)} $line -> mname]} {
        incr module_count
        if {$module_count <= 10} {
            lappend module_names $mname
        }
    }
}
close $nfh
log "  Total modules: $module_count"
log "  First 10: [join $module_names {, }]"
log ""

# 4. Check what Xilinx primitives are used
log "--- Xilinx primitives used ---"
set prims [lsort -unique [get_property REF_NAME [get_cells -hier -quiet -filter "NAME =~ [get_property NAME $vortex_cell]/* && IS_PRIMITIVE == 1"]]]
log "  Unique primitive types: [llength $prims]"
foreach p $prims {
    log "    $p"
}
log ""

# 5. Also generate timesim netlist for comparison
set timesim_path [file join $out_dir "vortex_afu_timesim.v"]
set sdf_path [file join $out_dir "vortex_afu_timesim.sdf"]
log "--- write_verilog -mode timesim -cell ---"
set t0 [clock seconds]
write_verilog -mode timesim -cell $vortex_cell -sdf_anno true -sdf_file $sdf_path -force $timesim_path
set t1 [clock seconds]
set sz [file size $timesim_path]
log "  netlist: $timesim_path ([expr {$sz / 1024 / 1024}] MB)"

set t0 [clock seconds]
write_sdf -cell $vortex_cell -force $sdf_path
set t1 [clock seconds]
set sz2 [file size $sdf_path]
log "  sdf: $sdf_path ([expr {$sz2 / 1024 / 1024}] MB)"
log "  sdf time: [expr {$t1 - $t0}] sec"
log ""

log "=== Done ==="
close $::fh
close_design
close_project
