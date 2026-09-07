# Read-only inspection of the newly synthesized or placed source checkpoint.
# Never runs implementation, changes design properties, or saves a checkpoint.
# Usage: checkpoint.dcp hook_directory output_directory 4|8 placed(0|1)
if {$argc != 5} {puts stderr "ERROR: expected checkpoint hooks output count placed"; exit 2}
lassign $argv checkpoint hook_dir output_dir count placed
if {$count ni {4 8} || $placed ni {0 1}} {puts stderr "ERROR: invalid count/placed"; exit 2}
set checkpoint [file normalize $checkpoint]
set hook_dir [file normalize $hook_dir]
set output_dir [file normalize $output_dir]
file mkdir $output_dir
cd $output_dir
set ::vortex_slr_definitions_only 1
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 1
foreach field {TMEM_BANKS DMA_CHANNELS HBM_PORTS} {set ::env(VORTEX_GEMM_$field) $count}
set ::env(VORTEX_GEMM_MXU_COL) 32
set ::env(VORTEX_GEMM_MXU_ROW) 32
set ::env(VORTEX_GEMM_HBM_DATA_BYTES) 64

proc demand {condition message} {if {![uplevel 1 [list expr $condition]]} {error $message}}
proc logical_owner {cell} {
    demand {[regexp {/(u_VX_gemm_unit_v2/u_compute_core/.*)$} $cell -> relative]} "MXU cell lost owner identity: $cell"
    return [::vortex::slr::owner_for $relative]
}
proc outputs_on {pin} {
    set result {}
    foreach endpoint [::vortex::slr::leaf_pins_on $pin] {
        if {[get_property DIRECTION $endpoint] eq "OUT"} {lappend result $endpoint}
    }
    return [lsort -unique $result]
}
proc inputs_on {pin} {
    set result {}
    foreach endpoint [::vortex::slr::leaf_pins_on $pin] {
        if {[get_property DIRECTION $endpoint] eq "IN"} {lappend result $endpoint}
    }
    return [lsort -unique $result]
}
if {[catch {
    open_checkpoint $checkpoint
    source -notrace [file join $hook_dir floorplan.tcl]
    source -notrace [file join $hook_dir slr_floorplan_report.tcl]
    set locals [get_cells -hierarchical -quiet -include_replicated_objects -filter {IS_PRIMITIVE == 1 && NAME =~ *g_local_prealign_blk_idx*data_q_reg*}]
    set txs [get_cells -hierarchical -quiet -include_replicated_objects -filter {IS_PRIMITIVE == 1 && NAME =~ *g_slr_mxu_input_tx*control_q_reg*block_idx*}]
    set rxs [get_cells -hierarchical -quiet -include_replicated_objects -filter {IS_PRIMITIVE == 1 && NAME =~ *g_slr_mxu_input_rx*control_q_reg*block_idx*}]
    foreach label {locals txs rxs} {
        set cells [set $label]
        demand {[llength $cells] == 160} "$label: expected exactly 160 FFs, got [llength $cells]"
        foreach cell $cells {demand {[string match FD* [get_property REF_NAME $cell]]} "not a standalone FF: $cell"}
    }
    set out [open preserved_mxu_local.tsv w]
    puts $out "local_ff\tref\tdont_touch\tuser_sll_reg\towner\tactual_slr\tloads"
    foreach local $locals {
        demand {[::vortex::slr::property_true DONT_TOUCH $local]} "local FF not preserved: $local"
        demand {![::vortex::slr::property_true USER_SLL_REG $local]} "local FF incorrectly marked: $local"
        demand {[logical_owner $local] == 1} "local FF owner is not SLR1: $local"
        set q [get_pins -quiet -of_objects $local -filter {REF_PIN_NAME == Q}]
        set loads [inputs_on $q]
        demand {[llength $loads] > 0} "local FF has no local consumer: $local"
        foreach load $loads {
            set consumer [get_cells -quiet -of_objects $load]
            demand {[logical_owner $consumer] == 1} "local FF has a non-SLR1 load: $local -> $load"
            demand {![string match *g_slr_mxu_input_rx* $consumer]} "local FF still drives MXU RX: $local -> $load"
        }
        set actual {}
        if {$placed} {
            set actual [get_slrs -quiet -of_objects $local]
            demand {$actual eq "SLR1"} "local FF physically outside SLR1: $local ($actual)"
        }
        puts $out [join [list $local [get_property REF_NAME $local] [get_property DONT_TOUCH $local] [get_property USER_SLL_REG $local] 1 $actual $loads] "\t"]
    }
    close $out
    array set expected_tx {}; foreach tx $txs {set expected_tx($tx) 1}
    array set seen_tx {}
    set laguna_pairs 0
    set out [open preserved_mxu_links.tsv w]
    puts $out "tx\trx\ttx_owner\trx_owner\tloads\ttx_actual_slr\trx_actual_slr\ttx_loc\trx_loc\ttx_bel\trx_bel\tlaguna_pair"
    foreach rx $rxs {
        demand {[::vortex::slr::property_true USER_SLL_REG $rx]} "RX not marked: $rx"
        demand {[logical_owner $rx] == 2} "RX owner is not SLR2: $rx"
        set d [get_pins -quiet -of_objects $rx -filter {REF_PIN_NAME == D}]
        set drivers [outputs_on $d]
        demand {[llength $drivers] == 1} "RX has no single direct driver: $rx ($drivers)"
        set q [lindex $drivers 0]
        set tx [get_cells -quiet -of_objects $q]
        demand {[info exists expected_tx($tx)] && [get_property REF_PIN_NAME $q] eq "Q"} "RX is not driven by dedicated block-index TX Q: $rx <- $q"
        demand {![info exists seen_tx($tx)]} "TX drives multiple block-index RX FFs: $tx"
        set seen_tx($tx) 1
        demand {[::vortex::slr::property_true USER_SLL_REG $tx] && [::vortex::slr::property_true DONT_TOUCH $tx]} "TX not marked/preserved: $tx"
        demand {[logical_owner $tx] == 1} "TX owner is not SLR1: $tx"
        set loads [inputs_on $q]
        demand {[llength $loads] == 1 && [lindex $loads 0] eq $d} "TX has additional/local fanout: $tx -> $loads"
        set source {}; set destination {}; set tx_loc {}; set rx_loc {}; set tx_bel {}; set rx_bel {}; set laguna 0
        if {$placed} {
            set source [get_slrs -quiet -of_objects $tx]; set destination [get_slrs -quiet -of_objects $rx]
            demand {$source eq "SLR1" && $destination eq "SLR2"} "actual TX/RX SLR mismatch: $tx -> $rx ($source/$destination)"
            set tx_loc [get_property LOC $tx]; set rx_loc [get_property LOC $rx]
            set tx_bel [get_property BEL $tx]; set rx_bel [get_property BEL $rx]
            set laguna [expr {[string match LAGUNA* $tx_loc] && [string match LAGUNA* $rx_loc] && [string match *TX_REG* $tx_bel] && [string match *RX_REG* $rx_bel]}]
            incr laguna_pairs $laguna
        }
        puts $out [join [list $tx $rx 1 2 $loads $source $destination $tx_loc $rx_loc $tx_bel $rx_bel $laguna] "\t"]
    }
    close $out
    demand {[array size seen_tx] == 160} "not all dedicated TX bits reached their RX"
    puts "PASS: TH32/t$count: 160 distinct unmarked preserved local FFs; 160 preserved marked TX FFs; 160 marked RX FFs; single-load direct TX Q-to-RX D; owners SLR1/SLR2; placed=$placed laguna_pairs=$laguna_pairs"
    close_design
} message options]} {
    puts stderr "FAIL: $message"
    if {[dict exists $options -errorinfo]} {puts stderr [dict get $options -errorinfo]}
    exit 1
}
puts "PASS: read-only preserved MXU inspection; no checkpoint saved or implementation run"
exit 0
