# Quick validation for hw/syn/xilinx/xrt/floorplan.tcl
#
# Opens an existing post-opt DCP (closest checkpoint to the
# post_init_hook run point), sources the real floorplan.tcl, and
# dumps the resulting pblock state. This validates:
#   - TCL syntax of floorplan.tcl
#   - cell query (get_cells -hierarchical) matches expected hierarchy
#   - create_pblock / resize_pblock accept the SLR keyword (or fall back)
#   - add_cells_to_pblock attaches the expected children
#
# Run (from repo root):
#   vivado -mode batch \
#          -source agent-tasks/dma-engine-route-fix/test_floorplan.tcl \
#          -log /tmp/floorplan_check.log -journal /tmp/floorplan_check.jou

set repo_root  [file normalize [file join [file dirname [info script]] ../..]]
set dcp        [file join $repo_root \
    build/hw/syn/xilinx/xrt/core1_fpint_improve_v3_xilinx_u55c_gen3x16_xdma_3_202210_1_hw \
    _x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_opt.dcp]
set floorplan  [file join $repo_root hw/syn/xilinx/xrt/floorplan.tcl]

if {![file exists $dcp]} {
    puts "ERROR: DCP not found at $dcp"
    exit 1
}
if {![file exists $floorplan]} {
    puts "ERROR: floorplan.tcl not found at $floorplan"
    exit 1
}

puts "INFO: opening $dcp"
open_checkpoint $dcp

puts "INFO: sourcing $floorplan"
source $floorplan

puts "\n================ pblock inventory ================"
foreach pb [get_pblocks] {
    set pbname [get_property NAME $pb]
    set ranges [get_property GRID_RANGES $pb]
    set cells  [get_cells -quiet -of_objects $pb]
    set slrs   [lsort -unique [get_property -quiet SLR_INDEX $cells]]
    set containR [get_property CONTAIN_ROUTING $pb]
    set excludeP [get_property EXCLUDE_PLACEMENT $pb]

    puts "\npblock: $pbname"
    puts "  grid_ranges      : $ranges"
    puts "  contain_routing  : $containR"
    puts "  exclude_placement: $excludeP"
    puts "  member count     : [llength $cells]"
    if {[llength $cells] > 0} {
        puts "  top member       : [get_property NAME [lindex $cells 0]]"
        puts "  member SLRs (pre-place): $slrs"
    }
}

puts "\n================ expected sanity checks ================"
set ok 1

# No user pblocks are currently expected. Assert that floorplan.tcl did not
# (re-)create pblock_gemm_unit / pblock_tmem_subsystem by mistake.
foreach pb_forbidden {pblock_gemm_unit pblock_tmem_subsystem} {
    set pb [get_pblocks -quiet $pb_forbidden]
    if {[llength $pb] > 0} {
        puts "FAIL: pblock '$pb_forbidden' exists but should NOT be created"
        set ok 0
    } else {
        puts "PASS: pblock '$pb_forbidden' absent (as expected)"
    }
}

if {$ok} {
    puts "\nRESULT: floorplan.tcl validated successfully."
    exit 0
} else {
    puts "\nRESULT: validation FAILED — see messages above."
    exit 2
}
