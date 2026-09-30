set task [file dirname [file normalize [info script]]]
set repo [file dirname [file dirname $task]]
source [file join $repo hw/syn/xilinx/xrt/mxu_slr_floorplan.tcl]
namespace eval ::vortex::slr {}
source [file join $task feat-gemv-slr_floorplan_report.tcl]
proc ::vortex::slr::backend {} {return "improve"}
proc ::vortex::slr::logical_path {path} {return $path}
proc ::vortex::slr::need {cells label} {if {![llength $cells]} {error "missing $label"}}
set root top/u_VX_gemm_unit
set tree $root/u_mxu
set source_cell $tree/reset_driver
set sink_cell top/mem_unit/valid_out_r_reg
set alias_port $tree/g_relay.reset_r_repN_12_alias
set source_pin $source_cell/Q
set ::vortex::mxu_slr::roots [list $root]
set ::vortex::slr::roots [list $root]
proc get_cells {args} {
    if {[lsearch -exact $args -hierarchical] >= 0} {return [list $::tree]}
    if {[lsearch -exact $args -of_objects] >= 0} {
        set result {}
        foreach pin [lindex $args end] {lappend result [file dirname $pin]}
        return [lsort -unique $result]
    }
    return [lindex $args end]
}
proc get_pins {args} {
    set object [lindex $args end]
    if {$object eq $::tree} {return [list $::alias_port]}
    return [list $::source_pin $::sink_cell/$::terminal]
}
proc get_nets {args} {return reset_net}
proc get_property {property object} {
    if {[llength $object] > 1} {
        set result {}
        foreach obj $object {lappend result [get_property $property $obj]}
        return $result
    }
    set object [lindex $object 0]
    switch $property {
        NAME {return $object}
        DIRECTION {return [expr {[file tail $object] eq "Q" ? "OUT" : "IN"}]}
        REF_PIN_NAME {return [file tail $object]}
        REF_NAME {return FDRE}
        USER_SLL_REG {return 0}
        default {error "unexpected property $property"}
    }
}
cd $task
foreach {label terminal owned expected_original} {
    dedicated_reset R 1 0
    reset_named_data D 1 1
    external_reset R 0 0
} {
    set owners [dict create $source_cell 2]
    if {$owned} {dict set owners $sink_cell 1}
    set ::vortex::mxu_slr::owners $owners
    set ::vortex::slr::owners $owners
    set current [catch {::vortex::mxu_slr::check_tree_ports} current_message]
    set original [catch {::vortex::slr::validate_boundary_nets ${label}.tsv} original_message]
    puts "CASE $label terminal=$terminal current_rejects=$current original_rejects=$original"
    puts "CURRENT $current_message"
    puts "ORIGINAL $original_message"
    if {!$current || $original != $expected_original} {error "unexpected comparison result"}
}
puts "PASS: current boundary checker rejects reset aliases; original distinguishes destination control/data pins"
