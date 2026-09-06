# Read-only validation for floorplan.tcl against an existing XCU55C checkpoint.
# This diagnoses a checkpoint already built from the SLR-pipelined RTL. It
# does not add/rewrite constraints, optimize, place, route, or write a DCP.

if {$argc != 4} {
    puts stderr "usage: vivado -mode batch -source check_floorplan_dcp.tcl -tclargs CHECKPOINT FLOORPLAN_TCL TMEM_ARRAYS MXU_COL"
    exit 2
}

set checkpoint [lindex $argv 0]
set floorplan_tcl [lindex $argv 1]

open_checkpoint $checkpoint
set ::env(VORTEX_DMA_CHANNEL_FLOORPLAN) 0
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 1
set ::env(VORTEX_GEMM_TMEM_BANKS) [lindex $argv 2]
set ::env(VORTEX_GEMM_MXU_COL) [lindex $argv 3]
set ::vortex_slr_definitions_only 1
source $floorplan_tcl
unset ::vortex_slr_definitions_only
source [file join [file dirname $floorplan_tcl] slr_floorplan_report.tcl]
::vortex::slr::post_place
puts "CHECK: existing full-SLR ownership and FF crossings validated without modifying implementation"
close_design
