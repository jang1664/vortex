# Pure Tcl fixture for the retained fusion counter and lifted reduction cone.
set ::vortex_slr_definitions_only 1
source [file join [file dirname [info script]] .. floorplan.tcl]
proc ::vortex::slr::cell_objects {names} {return $names}
proc reset_fixture {} {
    set ::env(VORTEX_GEMM_BACKEND) improve
    set ::root core/gemm_node
    set ::helper {core/gemm_node/u_tmem_subsystem/arbitrary_synthesis_name}
    set ::counter {core/gemm_node/u_tmem_subsystem/fusion_input_pending_q_reg[7]}
    set ::control core/gemm_node/u_fusion_ctrl/launch_q_reg
    set ::inputs [list $::helper/I0 $::helper/I1]
    set ::outputs [list $::helper/O]
    set ::drivers [list $::counter/Q]
    set ::cone [list core/gemm_node/u_fusion_ctrl/launch_q_i_1 $::control]
    set ::endpoints [list $::control/D]
    set ::ports {}
    set ::marked {}
    set ::refs [dict create $::helper LUT2 $::counter FDRE $::control FDRE]
}
proc get_property {property objects} {
    set object [lindex $objects 0]
    if {$property eq "NAME"} {return $object}
    if {$property eq "REF_PIN_NAME"} {return [file tail $object]}
    if {$property eq "USER_SLL_REG"} {return [expr {$object in $::marked}]}
    if {$property eq "REF_NAME"} {return [dict get $::refs $object]}
    error "unexpected property $property"
}
proc get_pins {args} {
    if {[lsearch -exact $args -leaf] >= 0} {return $::drivers}
    if {[lindex $args end] eq "DIRECTION == IN"} {return $::inputs}
    return $::outputs
}
proc get_nets {args} {return net}
proc get_ports {args} {return $::ports}
proc get_cells {args} {
    set pin [lindex [lindex $args end] 0]
    if {[string first / $pin] < 0} {return {}}
    return [list [file dirname $pin]]
}
proc all_fanout {args} {
    if {[lsearch -exact $args -endpoints_only] >= 0} {return $::endpoints}
    return $::cone
}
proc recover {} {::vortex::slr::recover_fusion_drain_owner $::helper $::root LUT2}
proc check {expression label} {
    if {![uplevel 1 [list expr $expression]]} {error "FAIL: $label"}
    incr ::checks
}
proc rejects {setup} {
    reset_fixture
    uplevel 1 $setup
    check {[catch {recover}]} "must reject: $setup"
}
set checks 0
reset_fixture
check {[dict get [recover] owner] == 1} renamed_lut_proven_from_topology
set extra core/mem_unit/lifted_control_lut
lappend ::cone $extra
dict set ::refs $extra LUT6
check {[dict get [recover] extra_cells] eq [list $extra]} lifted_sibling_is_explicitly_owned
reset_fixture
foreach name {{fusion_input_pending_q_reg[7]} {fusion_input_pending_q[15]_i_2}} {
    check {[::vortex::slr::owner_for "u_tmem_subsystem/$name"] == 1} source_counter_owner
}
check {[catch {::vortex::slr::owner_for u_tmem_subsystem/fusion_input_pending_unknown}]} unknown_counter_rejected
check {[::vortex::slr::owner_for u_tmem_subsystem/fusion_tmem_pending_q_reg] == 0} local_mux_owner
check {[catch {::vortex::slr::owner_for u_tmem_subsystem/fusion_tmem_pending_unknown}]} unknown_mux_state_rejected
check {[catch {::vortex::slr::owner_for u_tmem_subsystem/arbitrary_synthesis_name}]} names_alone_insufficient
foreach {stream half owner} {request tx 1 request rx 0 response tx 0 response rx 1} {
    check {[::vortex::slr::owner_for "u_fusion_tmem_cut/u_${stream}_${half}/payload_reg"] == $owner} fusion_transport_endpoint
}
check {[::vortex::slr::owner_for u_fusion_tmem_cut/u_launch/storage_reg] == 1} fusion_launch_owner
check {[catch {::vortex::slr::owner_for u_fusion_tmem_cut/unknown/state_reg}]} fusion_unknown_rejected
foreach spelling {g_slr/u_link g_slr.u_link} {
    foreach {stream half} {request tx request rx response tx response rx} {
        check {[catch {::vortex::slr::owner_for "u_fusion_tmem_cut/u_$stream/$spelling/u_$half/payload_reg"}]} retired_tmem_wrapper_rejected
    }
}
foreach local_path {u_request/u_launch/storage_reg u_request/g_local/local_logic u_response/g_local/local_logic} {
    check {[::vortex::slr::owner_for "u_fusion_lmem_cut/$local_path"] == 1} local_lmem_complete_endpoint_owner
}
foreach spelling {g_slr/u_link g_slr.u_link} {
    foreach stream {request response} {
        foreach half {tx rx} {
            check {[catch {::vortex::slr::owner_for "u_fusion_lmem_cut/u_$stream/$spelling/u_$half/payload_reg"}]} stale_lmem_crossing_rejected
        }
    }
}
rejects {set ::env(VORTEX_GEMM_BACKEND) naive}
rejects {set ::marked [list $::helper]}
rejects {dict set ::refs $::helper LUT3}
rejects {set ::inputs {}}
rejects {set ::outputs {}}
rejects {set ::ports top_port}
rejects {set ::drivers {}}
rejects {lappend ::drivers another/Q}
rejects {set ::drivers [list $::counter/D]}
rejects {set ::marked [list $::counter]}
rejects {dict set ::refs $::counter LUT6}
rejects {set ::counter {other/u_tmem_subsystem/fusion_input_pending_q_reg[7]}; set ::drivers [list $::counter/Q]}
rejects {set ::drivers [list core/u_tmem_subsystem/unrelated_reg/Q]}
rejects {set ::cone {}}
rejects {lappend ::cone {core/gemm_node/u_tmem_subsystem/g_bank[0].u_bank/data_reg}}
rejects {lappend ::cone core/gemm_node/u_tmem_subsystem/unclassified}
rejects {lappend ::cone other/u_fusion_ctrl/reg}
rejects {set extra core/mem_unit/lifted_control_reg; lappend ::cone $extra; dict set ::refs $extra FDRE}
rejects {set extra core/mem_unit/lifted_control_lut; lappend ::cone $extra; dict set ::refs $extra LUT6; set ::marked [list $extra]}
rejects {set ::endpoints {}}
rejects {lappend ::endpoints top_port}
rejects {set ::endpoints [list core/u_other_ctrl/state_reg/D]}
rejects {dict set ::refs $::control LUT6}
rejects {set ::marked [list $::control]}
puts "PASS: $checks fusion floorplan topology checks"
