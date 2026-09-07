# Pure Tcl pin-graph regression; no Vivado or implementation is launched.
set ::vortex_slr_definitions_only 1
source [file join [file dirname [info script]] .. floorplan.tcl]
set checks 0
proc arg_objects {args} {
    set idx [lsearch -exact $args -of_objects]
    if {$idx < 0} {error "missing mock -of_objects: $args"}
    return [lindex $args [expr {$idx+1}]]
}
proc get_property {property objects} {
    set result {}
    foreach object $objects {
        if {$property eq "NAME"} {lappend result $object; continue}
        if {![dict exists $::props $object $property]} {error "unknown mock property $property $object"}
        lappend result [dict get $::props $object $property]
    }
    if {[llength $result] == 1} {return [lindex $result 0]}
    return $result
}
proc get_cells {args} {
    if {[lsearch -exact $args -of_objects] >= 0} {
        set result {}
        foreach pin [arg_objects {*}$args] {lappend result [dict get $::props $pin CELL]}
        return [lsort -unique $result]
    }
    set result {}
    foreach name [lindex $args end] {
        if {[dict exists $::props $name REF_NAME]} {lappend result $name}
    }
    return $result
}
proc get_pins {args} {
    set result {}
    foreach object [arg_objects {*}$args] {
        if {[dict exists $::object_pins $object]} {
            lappend result {*}[dict get $::object_pins $object]
        }
    }
    set idx [lsearch -exact $args -filter]
    if {$idx >= 0} {
        set filter [lindex $args [expr {$idx+1}]]
        if {![regexp {^REF_PIN_NAME == ([A-Za-z0-9]+)$} $filter -> wanted]} {
            error "unknown mock pin filter $filter"
        }
        set filtered {}
        foreach pin $result {
            if {[dict get $::props $pin REF_PIN_NAME] eq $wanted} {lappend filtered $pin}
        }
        set result $filtered
    }
    return [lsort -unique $result]
}
proc get_nets {args} {
    set result {}
    foreach pin [arg_objects {*}$args] {
        if {[dict exists $::pin_nets $pin]} {lappend result {*}[dict get $::pin_nets $pin]}
    }
    return [lsort -unique $result]
}
proc get_ports {args} {
    set result {}
    foreach net [arg_objects {*}$args] {
        if {[dict exists $::net_ports $net]} {lappend result {*}[dict get $::net_ports $net]}
    }
    return $result
}
proc add_cell {cell ref {marked 0}} {
    dict set ::props $cell REF_NAME $ref
    dict set ::props $cell USER_SLL_REG $marked
    dict set ::props $cell IS_SEQUENTIAL [expr {[string match FD* $ref]}]
}
proc add_pin {cell terminal direction net} {
    set pin "$cell/$terminal"
    dict set ::props $pin CELL $cell
    dict set ::props $pin REF_PIN_NAME $terminal
    dict set ::props $pin DIRECTION $direction
    dict lappend ::object_pins $cell $pin
    dict lappend ::object_pins $net $pin
    dict lappend ::pin_nets $pin $net
    return $pin
}
proc fixture {{spelling g_slr.u_link} {stream u_gemm_dma_transport/u_commands}} {
    set ::props {}; set ::object_pins {}; set ::pin_nets {}; set ::net_ports {}
    set ::root {top/node[0]}
    set ::lut "$::root/$spelling/u_rx/arbitrary_helper_rep__2"
    set ::ff "$::root/$stream/$spelling/u_rx/renamed_state_reg\[0\]"
    add_cell $::lut LUT1
    add_cell $::ff FDRE
    add_pin $::lut I0 IN input_net
    add_pin $::lut O OUT output_net
    add_pin $::ff Q OUT input_net
    add_pin $::ff D IN output_net
}
proc accepted {owner label} {
    set proof [::vortex::slr::recover_lifted_owner $::lut $::root LUT1]
    if {[dict get $proof owner] != $owner || [dict get $proof endpoint] ne $::ff
        || [dict get $proof input_pin] ne "$::ff/Q"
        || [dict get $proof output_pin] ne "$::ff/D"} {
        error "$label: incorrect original-name proof $proof"
    }
    incr ::checks
}
proc rejected {label} {
    if {![catch {::vortex::slr::recover_lifted_owner $::lut $::root [dict get $::props $::lut REF_NAME]} message]} {
        error "$label: unsafe lifted owner accepted"
    }
    # Unexpected mock failures must not count as safety rejections.
    if {![regexp {^(lifted |not an eligible )} $message]} {error "$label: $message"}
    incr ::checks
}
foreach spelling {g_slr/u_link g_slr.u_link} {
    foreach {stream owner} {
        u_gemm_dma_transport/u_commands 0
        u_gemm_dma_transport/u_completions 1
        u_tmem_subsystem/u_input_req_reservation/u_slr/u_request 0
        u_tmem_subsystem/u_input_req_reservation/u_slr/u_response 1
    } {
        fixture $spelling $stream
        accepted $owner endpoint_spelling
    }
}
fixture
add_cell top/another_local_consumer LUT2
add_pin top/another_local_consumer I0 IN input_net
accepted 0 input_Q_fanout_is_not_output_ownership
fixture
dict set ::props $::lut REF_NAME LUT2
rejected unsupported_primitive
fixture
dict set ::props $::lut USER_SLL_REG 1
rejected marked_crossing_primitive
fixture
dict set ::pin_nets "$::lut/I0" {}
rejected missing_input_net
fixture
add_cell top/other_driver FDRE
add_pin top/other_driver Q OUT input_net
rejected multiple_input_drivers
fixture
dict set ::props $::ff REF_NAME LUT1
rejected non_FF_driver
fixture
dict set ::props "$::ff/Q" REF_PIN_NAME O
rejected wrong_source_terminal
fixture
dict set ::props "$::ff/D" REF_PIN_NAME CE
rejected wrong_destination_terminal
fixture
add_cell top/other_consumer FDRE
add_pin top/other_consumer D IN output_net
rejected additional_output_sink
fixture
dict set ::object_pins output_net [list "$::lut/O"]
add_cell "$::root/u_gemm_dma_transport/u_completions/g_slr.u_link/u_rx/other_reg" FDRE
add_pin "$::root/u_gemm_dma_transport/u_completions/g_slr.u_link/u_rx/other_reg" D IN output_net
rejected different_feedback_FF_and_endpoint
fixture
add_cell top/other_driver LUT1
add_pin top/other_driver O OUT output_net
rejected additional_output_driver
fixture
dict set ::net_ports output_net exported_port
rejected output_port
fixture
dict set ::net_ports input_net imported_port
rejected input_port
fixture g_slr.u_link unrelated_wrapper
rejected missing_endpoint_identity
fixture g_slr.u_link u_gemm_dma_transport/u_commands_fake
rejected misleading_stream_identity
fixture
dict set ::props $::ff USER_SLL_REG 1
rejected marked_boundary_FF
fixture
set ::root top/other_node
rejected root_mismatch
puts "PASS: $checks connectivity-proven lifted-owner checks"
