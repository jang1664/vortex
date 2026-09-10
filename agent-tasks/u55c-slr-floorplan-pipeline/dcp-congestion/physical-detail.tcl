# Source after inspect.tcl in the same read-only Vivado Tcl session.
set evidence_out [open physical_detail.txt w]
foreach net [list $hmss $gemm] {
    emit "NET_DETAIL $net"
    foreach pin [get_pins -quiet -leaf -of_objects $net] {
        set cell [get_cells -quiet -of_objects $pin]
        foreach cp [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == C || REF_PIN_NAME == CE || REF_PIN_NAME == R}] {
            emit "CONTROL $cp NET=[get_nets -quiet -of_objects $cp] CLOCK=[get_clocks -quiet -of_objects $cp]"
        }
    }
    foreach node [get_nodes -quiet -of_objects $net] {
        emit "NODE $node [props $node {INTENT_CODE IS_USED}]"
    }
    foreach pip [get_pips -quiet -of_objects $net] {
        emit "PIP $pip [props $pip {IS_DIRECTIONAL IS_REVERSED IS_FIXED}]"
    }
}
foreach site_name {LAGUNA_X9Y21 LAGUNA_X9Y141 LAGUNA_X8Y21 LAGUNA_X8Y141 LAGUNA_X10Y21 LAGUNA_X10Y141} {
    set site [get_sites -quiet $site_name]
    emit "SITE $site [props $site {SITE_TYPE IS_USED PROHIBIT}] SLR=[get_slrs -quiet -of_objects $site] CR=[get_clock_regions -quiet -of_objects $site] TILE=[get_tiles -quiet -of_objects $site]"
    foreach bel [get_bels -quiet -of_objects $site] {
        set occupants [get_cells -quiet -of_objects $bel]
        emit "BEL $bel CELLS=$occupants"
        foreach cell $occupants {emit "  [props $cell {REF_NAME LOC BEL IS_LOC_FIXED IS_BEL_FIXED USER_SLL_REG DONT_TOUCH}]"}
    }
}
foreach tile_name {LAG_LAG_X40Y190 LAG_LAG_X40Y250} {
    set tile [get_tiles -quiet $tile_name]
    emit "TILE $tile SLR=[get_slrs -quiet -of_objects $tile] CR=[get_clock_regions -quiet -of_objects $tile]"
    foreach node [get_nodes -quiet -of_objects $tile -filter {NAME =~ */UBUMP*}] {
        set users [get_nets -quiet -of_objects $node]
        emit "SLL $node USERS=[llength $users] $users"
    }
}
close $evidence_out
puts "PHYSICAL_DETAIL_COMPLETE"
report_timing -through $gemm -delay_type min_max -max_paths 3 -file gemm_conflict_timing.rpt
report_timing -through $hmss -delay_type min_max -max_paths 3 -file hmss_conflict_timing.rpt
report_timing_summary -max_paths 3 -file failed_route_timing_summary.rpt
puts "DIAGNOSTIC_TIMING_COMPLETE"
