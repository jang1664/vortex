# Pure source-backed retired fusion wrapper rejection and anchor regression.
# Active shared receiver feedback remains covered by test_lifted_owner.tcl;
# repaired feature transports have complete explicitly classified endpoints.
source [file join [file dirname [info script]] test_lifted_owner.tcl]

proc fusion_fixture {{spelling g_slr.u_link} {memory tmem} {direction u_request}} {
    set ::props {}; set ::object_pins {}; set ::pin_nets {}; set ::net_ports {}
    set ::root {top/node[0]}
    set ::lut "$::root/u_request/$spelling/u_rx/arbitrary_helper_rep__2"
    set ::ff "$::root/u_fusion_${memory}_cut/$direction/$spelling/u_rx/renamed_state_reg\[0\]"
    add_cell $::lut LUT1
    add_cell $::ff FDRE
    add_pin $::lut I0 IN input_net
    add_pin $::lut O OUT output_net
    add_pin $::ff Q OUT input_net
    add_pin $::ff D IN output_net
}

foreach spelling {g_slr/u_link g_slr.u_link} {
    foreach memory {tmem lmem} {
        fusion_fixture $spelling $memory
        set relative [string range $::lut [expr {[string length $::root]+1}] end]
        if {![catch {::vortex::slr::owner_for $relative}]} {error "lifted prefix still falls through to default owner"}
        incr checks
        if {$memory eq "tmem"} {
            if {![catch {::vortex::slr::recover_lifted_owner $::lut $::root LUT1} message]
                || ![string match {unclassified fusion SRAM transport leaf: u_fusion_tmem_cut/*} $message]} {
                error "retired TMEM wrapper was not rejected by endpoint classification: $message"
            }
            incr checks
        } else {
            rejected retired_fusion_wrapper_must_not_recover_crossing_receiver
        }
    }
}
fusion_fixture
dict set ::props $::lut REF_NAME LUT2
rejected fusion_non_LUT1
fusion_fixture
dict set ::props $::lut USER_SLL_REG 1
rejected fusion_marked_helper
fusion_fixture
dict set ::props $::ff USER_SLL_REG 1
rejected fusion_marked_endpoint
fusion_fixture
add_cell top/other_driver FDRE
add_pin top/other_driver Q OUT input_net
rejected fusion_multiple_input_drivers
fusion_fixture
add_cell top/other_sink FDRE
add_pin top/other_sink D IN output_net
rejected fusion_additional_output_sink
fusion_fixture
dict set ::props "$::ff/D" REF_PIN_NAME CE
rejected fusion_wrong_endpoint_terminal
fusion_fixture
dict set ::net_ports output_net external
rejected fusion_output_port
fusion_fixture
dict set ::net_ports input_net external
rejected fusion_input_port
fusion_fixture g_slr.u_link tmem u_response
rejected request_helper_with_response_endpoint
fusion_fixture g_slr.u_link unknown
rejected non_architectural_fusion_cut
fusion_fixture
set ::root top/other_node
rejected fusion_other_root

# The recovered primitive's owner must propagate into anchor analysis, never
# be overridden by the anonymous retained u_request hierarchy's old default.
set root top/node
set parent $root/u_request/g_slr.u_link/u_rx
set helper $parent/helper
set hier [list $root $root/u_request $root/u_request/g_slr.u_link $parent]
set parents [list top $root $root/u_request $root/u_request/g_slr.u_link]
set result [::vortex::slr::select_homogeneous_anchors $hier $parents \
    [list $helper] [list $parent] {LUT1} [dict create $helper 0] [list $root]]
if {[dict get $result groups 0] ne [list $parent] || [llength [dict get $result groups 1]]
    || [dict get $result covered $helper] ne $parent} {error "recovered owner lost in homogeneous anchor"}
incr checks
set other $parent/other_owner
set result [::vortex::slr::select_homogeneous_anchors $hier $parents \
    [list $helper $other] [list $parent $parent] {LUT1 FDRE} \
    [dict create $helper 0 $other 1] [list $root]]
if {[llength [dict get $result covered]] || [dict get $result uncovered] ne \
    [list [list $helper LUT1 0 $parent] [list $other FDRE 1 $parent]]} {
    error "mixed retained receiver hierarchy overrides primitive ownership"
}
incr checks
puts "PASS: $checks source-backed fusion feedback and anchor checks"
