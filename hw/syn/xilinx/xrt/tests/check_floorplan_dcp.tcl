# Read-only validation for floorplan.tcl against an existing XCU55C checkpoint.
# This script opens a checkpoint and applies constraints in memory; it does not
# run optimization, placement, routing, or write a checkpoint.

if {$argc != 2} {
    puts stderr "usage: vivado -mode batch -source check_floorplan_dcp.tcl -tclargs CHECKPOINT FLOORPLAN_TCL"
    exit 2
}

set checkpoint [lindex $argv 0]
set floorplan_tcl [lindex $argv 1]

open_checkpoint $checkpoint
set ::env(VORTEX_DMA_CHANNEL_FLOORPLAN) 1
source $floorplan_tcl

foreach pblock_name {pblock_dma_ch2_hbm8_11 pblock_dma_ch3_hbm12_15} {
    set pblocks [get_pblocks -quiet $pblock_name]
    if {[llength $pblocks] != 1} {
        error "expected exactly one $pblock_name, found [llength $pblocks]"
    }

    set cells [get_cells -quiet -of_objects $pblocks]
    if {[llength $cells] == 0} {
        error "$pblock_name contains no cells"
    }
    if {[get_property CONTAIN_ROUTING $pblocks]} {
        error "$pblock_name unexpectedly contains routing"
    }
    if {[get_property EXCLUDE_PLACEMENT $pblocks]} {
        error "$pblock_name unexpectedly excludes unrelated placement"
    }

    puts "CHECK: $pblock_name cells=[llength $cells] ranges=[get_property GRID_RANGES $pblocks]"
}

puts "CHECK: DMA channel soft floorplan validated without running implementation"
close_design
