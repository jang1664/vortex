source [file join [file dirname [info script]] test_fusion_floorplan.tcl]
proc busy_fixture {} {
    reset_fixture
    set ::busy "$::root/u_fusion_busy_export/busy_tx_q_reg"
    dict set ::refs $::busy FDRE
    lappend ::marked $::busy
    lappend ::cone $::busy
    lappend ::endpoints $::busy/D
}
busy_fixture
check {[dict get [recover] owner] == 1} controller_plus_marked_busy_tx
check {[llength [dict get [recover] endpoint]] == 2} both_endpoint_witnesses
foreach setup {
    {set ::endpoints [list $::busy/D]}
    {set ::marked {}}
    {dict set ::refs $::busy LUT1}
    {set ::endpoints [list $::control/D $::busy/CE]}
    {set ::endpoints [list $::control/D $::busy/R]}
    {set rx "$::root/u_fusion_busy_export/busy_rx_q_reg"; dict set ::refs $rx FDRE; lappend ::marked $rx; lappend ::endpoints $rx/D}
    {set wrong "$::root/u_other/busy_tx_q_reg"; dict set ::refs $wrong FDRE; lappend ::marked $wrong; lappend ::endpoints $wrong/D}
    {set wrong "other/gemm_node/u_fusion_busy_export/busy_tx_q_reg"; dict set ::refs $wrong FDRE; lappend ::marked $wrong; lappend ::endpoints $wrong/D}
    {set replica "$::root/u_fusion_busy_export/busy_tx_q_reg_rep"; dict set ::refs $replica FDRE; lappend ::marked $replica; lappend ::endpoints $replica/D}
    {lappend ::cone "$::root/u_fusion_busy_export/busy_rx_q_reg"}
    {set ::drivers [list "$::root/u_tmem_subsystem/fusion_tmem_pending_q_reg/Q"]}
} {
    busy_fixture
    eval $setup
    check {[catch {recover}]} "busy drain rejects $setup"
}
puts "PASS: $checks fusion drain including exact TX endpoint checks"
