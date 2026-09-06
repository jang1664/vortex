# Read-only synthesized-netlist preflight. Never applies pblocks or invokes
# optimization, synthesis, placement, routing, or checkpoint writes.
if {$argc ni {5 6}} {
    puts stderr "usage: check_slr_synth_dcp.tcl CHECKPOINT FLOORPLAN_TCL TMEM_ARRAYS MXU_COL REPORT ?pairs|boundaries?"
    exit 2
}
set check_mode pairs
if {$argc == 6} {set check_mode [lindex $argv 5]}
if {$check_mode ni {pairs boundaries}} {error "unknown read-only check mode $check_mode"}
open_checkpoint [lindex $argv 0]
set ::env(VORTEX_DMA_CHANNEL_FLOORPLAN) 0
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 1
set ::env(VORTEX_GEMM_TMEM_BANKS) [lindex $argv 2]
set ::env(VORTEX_GEMM_MXU_COL) [lindex $argv 3]
set ::vortex_slr_definitions_only 1
source [lindex $argv 1]
source [file join [file dirname [lindex $argv 1]] slr_floorplan_report.tcl]
set idle [get_cells -hierarchical -quiet -filter {NAME =~ *u_gemm_dma_slr_bridge*g_slr*idle*} *]
puts "CHECK: surviving DMA idle cells=[llength $idle] names=$idle"
::vortex::slr::inventory
foreach owner {0 1 2} {
    puts "CHECK: SLR$owner logical owner leaves=[llength [dict get $::vortex::slr::groups $owner]]"
}
::vortex::slr::require_marked_groups
if {$check_mode eq "boundaries"} {
    ::vortex::slr::validate_boundary_nets [lindex $argv 4]
} else {
    ::vortex::slr::validate_links 0 [lindex $argv 4]
}
puts "CHECK: synthesized ownership and $check_mode passed without implementation"
close_design
