# Read-only validation for floorplan.tcl against an existing XCU55C checkpoint.
# This diagnoses a checkpoint already built from the SLR-pipelined RTL. It
# does not add/rewrite constraints, optimize, place, route, or write a DCP.

if {$argc != 6} {
    puts stderr "usage: vivado -mode batch -source check_floorplan_dcp.tcl -tclargs CHECKPOINT FLOORPLAN_TCL TMEM_ARRAYS MXU_COL DMA_CHANNELS HBM_PORTS"
    exit 2
}

set checkpoint [lindex $argv 0]
set floorplan_tcl [lindex $argv 1]

open_checkpoint $checkpoint
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 1
set ::env(VORTEX_GEMM_TMEM_BANKS) [lindex $argv 2]
set ::env(VORTEX_GEMM_MXU_COL) [lindex $argv 3]
set ::env(VORTEX_GEMM_DMA_CHANNELS) [lindex $argv 4]
set ::env(VORTEX_GEMM_HBM_PORTS) [lindex $argv 5]
# This driver's positional interface describes square, FP16 MXUs with a
# 64-byte HBM bus. Set both dimensions explicitly, as the source flow does.
set ::env(VORTEX_GEMM_MXU_ROW) [lindex $argv 3]
set ::env(VORTEX_GEMM_HBM_DATA_BYTES) 64
set ::vortex_slr_definitions_only 1
source $floorplan_tcl
unset ::vortex_slr_definitions_only
source [file join [file dirname $floorplan_tcl] slr_floorplan_report.tcl]
::vortex::slr::post_place
puts "CHECK: existing full-SLR ownership and FF crossings validated without modifying implementation"
close_design
