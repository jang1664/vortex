# Anonymous LUT ownership must not hide an input crossing inside a wrapper.
set ::vortex_slr_definitions_only 1
source [file join [file dirname [info script]] .. floorplan.tcl]
source [file join [file dirname [info script]] .. slr_floorplan_report.tcl]
set ::env(VORTEX_GEMM_BACKEND) naive
set ::lut core/u_naive_dma_slr/anonymous_lut
set ::source core/u_VX_dma_node/source_reg
set ::sink core/mem_unit/sink_reg
set ::anchor core/mem_unit/anchor_reg
set ::vortex::slr::roots {core}
set ::vortex::slr::recovered_lut_names [list $::lut]
set ::nets [dict create \
    input_net [list $::source/Q $::lut/I0] \
    output_net [list $::lut/O $::sink/D] \
    boundary_net [list $::anchor/Q $::sink/CE]]
set ::pin_nets [dict create]
dict for {net pins} $::nets {
    foreach pin $pins {dict set ::pin_nets $pin $net}
}
dict set ::pin_nets core/mem_unit/anchor_port boundary_net
proc objects {args} {
    set index [lsearch -exact $args -of_objects]
    if {$index < 0} {return [lindex $args end]}
    return [lindex $args [expr {$index + 1}]]
}
proc get_cells {args} {
    if {[lsearch -exact $args -hierarchical] >= 0} {return core/mem_unit}
    if {[lsearch -exact $args -of_objects] >= 0} {
        set result {}
        foreach pin [objects {*}$args] {lappend result [file dirname $pin]}
        return [lsort -unique $result]
    }
    return [lindex $args end]
}
proc get_property {property collection} {
    set result {}
    foreach object $collection {
        switch -- $property {
            NAME {lappend result $object}
            REF_NAME {lappend result [expr {$object eq $::lut ? "LUT2" : "FDRE"}]}
            USER_SLL_REG {lappend result 0}
            REF_PIN_NAME {lappend result [file tail $object]}
            DIRECTION {lappend result [expr {[file tail $object] in {Q O} ? "OUT" : "IN"}]}
            default {error "unexpected property: $property"}
        }
    }
    return $result
}
proc get_pins {args} {
    set result {}
    foreach object [objects {*}$args] {
        if {$object eq "core/mem_unit"} {
            lappend result core/mem_unit/anchor_port
        } elseif {$object eq $::lut} {
            if {[lsearch -exact $args -filter] >= 0} {
                lappend result $::lut/O
            } else {lappend result $::lut/I0 $::lut/O}
        } elseif {[dict exists $::nets $object]} {
            lappend result {*}[dict get $::nets $object]
        } else {error "unexpected pin query: $args"}
    }
    return $result
}
proc get_nets {args} {
    if {[lsearch -exact $args -of_objects] < 0} {return [lindex $args end]}
    set result {}
    foreach pin [objects {*}$args] {lappend result [dict get $::pin_nets $pin]}
    return [lsort -unique $result]
}
proc get_ports {args} {return {}}
proc check {condition label} {
    if {![uplevel 1 [list expr $condition]]} {error "FAIL: $label"}
    incr ::checks
}
set ::checks 0
set known [dict create $::source 0 $::sink 1 $::anchor 1]
set recovery [::vortex::slr::naive_recover_lut_owners \
    [list [list $::lut LUT2 {unclassified anonymous LUT}]] $known {core}]
check {[dict get $recovery owners $::lut] == 1} {output cone recovers SLR1}
check {[dict get $recovery errors] eq {}} {recovery succeeds despite foreign input}
set ::vortex::slr::owners [dict merge $known [dict get $recovery owners]]
check {[get_nets -of_objects [get_pins -of_objects core/mem_unit]] eq {boundary_net}} \
    {hierarchy boundary does not touch recovered LUT input or output}
set report [file join [pwd] naive_recovered_boundary_nets.tsv]
set rejected [catch {::vortex::slr::validate_boundary_nets $report} message]
check {$rejected && [string match {*1 unregistered partition-boundary connections*} $message]} \
    {foreign recovered LUT input is rejected}
set channel [open $report r]
set text [read $channel]
close $channel
check {[string first "input_net\t$::source/Q\t$::lut/I0\t0\t1\t0" $text] >= 0} \
    {rejected incident input is identified in the report}
dict set ::vortex::slr::owners $::source 1
::vortex::slr::validate_boundary_nets $report
set channel [open $report r]
set text [read $channel]
close $channel
check {[llength [split [string trim $text] \n]] == 1} {local recovered cone has no crossings}
puts "PASS: $::checks recovered-LUT incident-boundary checks"
