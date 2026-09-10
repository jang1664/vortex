# Read-only physical SLL occupancy at the actual SLR0/SLR1 boundary.
# Tile Y240..299 is the SLR1 side of this boundary in this exact U55C DCP;
# inspect.tcl/physical-detail.tcl separately establish the endpoint mapping.
set inventory [open sll_boundary_inventory.tsv w]
puts $inventory "node\tusers\tnet_names"
set stats [dict create]
foreach tile [get_tiles -quiet LAG_LAG_*] {
    if {![regexp {LAG_LAG_X([0-9]+)Y([0-9]+)$} $tile -> x y]} {continue}
    if {$y < 240 || $y >= 300} {continue}
    foreach node [get_nodes -quiet -of_objects $tile -filter {NAME =~ */UBUMP*}] {
        set nets [get_nets -quiet -of_objects $node]
        set count [llength $nets]
        puts $inventory [join [list $node $count $nets] "\t"]
        foreach key [list total [expr {$count == 0 ? "free" : "used"}]] {
            set old 0
            if {[dict exists $stats $x $key]} {set old [dict get $stats $x $key]}
            dict set stats $x $key [expr {$old + 1}]
        }
        if {$count > 1} {dict set stats $x conflict_node $node}
    }
}
close $inventory
set summary [open sll_boundary_summary.tsv w]
puts $summary "tile_x\ttotal_sll\tused_sll\tfree_sll\tconflict_node"
foreach x [lsort -integer [dict keys $stats]] {
    set row [list $x]
    foreach key {total used free conflict_node} {
        set value 0
        if {[dict exists $stats $x $key]} {set value [dict get $stats $x $key]}
        lappend row $value
    }
    puts $summary [join $row "\t"]
}
close $summary
set evidence_out [open candidate_constraints.txt w]
foreach pb_name {pblock_gemm_slr0 pblock_gemm_slr1 pblock_dynamic_region} {
    set pb [get_pblocks $pb_name]
    emit "PBLOCK $pb [props $pb {GRID_RANGES DERIVED_RANGES IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT}]"
    foreach site_name {LAGUNA_X9Y21 LAGUNA_X9Y141 LAGUNA_X10Y21 LAGUNA_X10Y141} {
        set sites [get_sites -quiet -of_objects $pb -filter [list NAME == $site_name]]
        emit "SITE_MEMBERSHIP $pb $site_name matched=[llength $sites]"
    }
}
close $evidence_out
puts "SLL_INVENTORY_COMPLETE"
