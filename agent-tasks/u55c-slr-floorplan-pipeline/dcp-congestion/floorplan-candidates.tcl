# Read-only placement freedom and local connectivity evidence.
set evidence_out [open floorplan_candidates.txt w]
foreach tile_name {LAG_LAG_X23Y190 LAG_LAG_X23Y250 LAG_LAG_X31Y190 LAG_LAG_X31Y250 LAG_LAG_X40Y190 LAG_LAG_X40Y250 LAG_LAG_X52Y190 LAG_LAG_X52Y250 LAG_LAG_X69Y190 LAG_LAG_X69Y250} {
    set tile [get_tiles $tile_name]
    emit "TILE $tile CR=[get_clock_regions -of_objects $tile] SLR=[get_slrs -of_objects $tile]"
}
foreach cr_name {X1Y3 X1Y4 X2Y3 X2Y4 X3Y3 X3Y4} {
    set cr [get_clock_regions $cr_name]
    set sites [get_sites -quiet -of_objects $cr -filter {SITE_TYPE == LAGUNA}]
    set tx_used 0; set rx_used 0; set prohibited 0
    foreach site $sites {
        if {[get_property PROHIBIT $site]} {incr prohibited}
        foreach cell [get_cells -quiet -of_objects $site] {
            set bel [get_property BEL $cell]
            if {[string match *TX_REG* $bel]} {incr tx_used}
            if {[string match *RX_REG* $bel]} {incr rx_used}
        }
    }
    emit "LAGUNA_CAPACITY cr=$cr sites=[llength $sites] tx_bels=[expr {6*[llength $sites]}] tx_used=$tx_used rx_used=$rx_used prohibited_sites=$prohibited"
}
set rx [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $gemm -filter {DIRECTION == IN}]]
set tx [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $gemm -filter {DIRECTION == OUT}]]
set txd [get_pins -quiet -of_objects $tx -filter {REF_PIN_NAME == D}]
set rxq [get_pins -quiet -of_objects $rx -filter {REF_PIN_NAME == Q}]
foreach pin [list $txd $rxq] {
    set segments [get_nets -quiet -segments -of_objects $pin]
    emit "NEIGHBORHOOD pin=$pin"
    foreach np [get_pins -quiet -leaf -of_objects $segments] {
        set c [get_cells -quiet -of_objects $np]
        emit "  $np [props $c {REF_NAME LOC BEL}] SLR=[get_slrs -quiet -of_objects $c] CR=[get_clock_regions -quiet -of_objects $c]"
    }
}
close $evidence_out
puts "FLOORPLAN_CANDIDATES_COMPLETE"
