# Apply current MXU floorplan checks to an existing kernel synthesis DCP.
# Run Vivado from a configured build tree. No checkpoint is overwritten.
# Usage: vivado -mode batch -source check_mxu_slr_dcp.tcl -tclargs INPUT.dcp NEW_REPORT_DIR
set xrt_dir [file dirname [file dirname [file normalize [info script]]]]
if {[catch {
    if {[llength $argv] != 2} {error "Expected INPUT.dcp and NEW_REPORT_DIR"}
    set checkpoint [file normalize [lindex $argv 0]]
    set reports [file normalize [lindex $argv 1]]
    if {[file exists $reports]} {error "Report directory already exists: $reports"}
    file mkdir $reports
    cd $reports
    open_checkpoint $checkpoint
    source [file join $xrt_dir mxu_slr_floorplan.tcl]
    puts "DCP_CHECK: checkpoint opened; starting current floorplan checks"
    set ::env(VORTEX_GEMM_MXU_SLR_FLOORPLAN) 1
    ::vortex::mxu_slr::apply post_init
    puts "DCP_CHECK: post-init placement ownership, direct links and MXU ports passed"
    # Exercise the inventory refresh on this same synthesized netlist.
    # This does not claim validation after an actual opt_design/place_design run.
    ::vortex::mxu_slr::apply post_opt
    puts "DCP_CHECK: inventory refresh passed; endpoints=[dict size $::vortex::mxu_slr::endpoints] owned_cells=[dict size $::vortex::mxu_slr::cells]"
    puts "DCP_CHECK: PASS (synthesized netlist only; placement and timing not tested)"
    close_design
} message options]} {
    puts stderr "DCP_CHECK: FAIL $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
