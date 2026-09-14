# Pure Tcl Vivado API fixture for strict naive output-cone recovery.
source [file join [file dirname [info script]] .. naive_lut_ownership.tcl]
proc ::vortex::slr::backend {} {return naive}
proc ::vortex::slr::cell_objects {names} {return $names}
set root core
set prefix core/u_naive_dma_slr
proc reset_fixture {} {
    set ::cells {}; set ::edges {}; set ::extra_drivers {}; set ::ports {}
    set ::known {}; set ::errors {}; set ::bad_parent {}; set ::bad_direction {}
    set ::sink_queries 0
}
proc add_cell {name ref {owner {}} {marked 0}} {
    dict set ::cells $name [dict create REF_NAME $ref USER_SLL_REG $marked]
    if {$owner ne {}} {dict set ::known $name $owner}
}
proc candidate {short {ref LUT5} {marked 0}} {
    set name "$::prefix/$short"
    add_cell $name $ref {} $marked
    lappend ::errors [list $name $ref "original error for $short"]
    return $name
}
proc edge {source args} {dict set ::edges $source $args}
proc arg_objects {args} {
    set idx [lsearch -exact $args -of_objects]
    return [lindex $args [expr {$idx+1}]]
}
proc get_property {property objects} {
    set result {}
    foreach object $objects {
        if {$property eq "NAME"} {lappend result $object; continue}
        if {$property eq "DIRECTION"} {
            if {$object eq $::bad_direction} {lappend result INOUT; continue}
            lappend result [expr {[string match */O $object] ? "OUT" : "IN"}]
            continue
        }
        lappend result [dict get $::cells $object $property]
    }
    if {[llength $result] == 1} {return [lindex $result 0]}
    return $result
}
proc get_pins {args} {
    set objects [arg_objects {*}$args]
    set object [lindex $objects 0]
    if {[dict exists $::cells $object]} {return [list "$object/O"]}
    set source [string range $object 4 end]
    set result [list "$source/O"]
    if {[dict exists $::edges $source]} {
        foreach sink [dict get $::edges $source] {lappend result "$sink/I0"}
    }
    if {[dict exists $::extra_drivers $source]} {
        foreach driver [dict get $::extra_drivers $source] {lappend result "$driver/O"}
    }
    return $result
}
proc get_nets {args} {
    set output [lindex [arg_objects {*}$args] 0]
    return [list "net:[string range $output 0 end-2]"]
}
proc get_ports {args} {
    set source [string range [lindex [arg_objects {*}$args] 0] 4 end]
    if {[dict exists $::ports $source]} {return top_port}
    return {}
}
proc get_cells {args} {
    incr ::sink_queries
    set result {}
    foreach pin [arg_objects {*}$args] {
        if {$pin eq $::bad_parent} {lappend result core/wrong_parent; continue}
        lappend result [string range $pin 0 [expr {[string last / $pin]-1}]]
    }
    return [lsort -unique $result]
}
proc recover {} {
    return [::vortex::slr::naive_recover_lut_owners $::errors $::known [list $::root]]
}
proc check {expression label} {
    if {![uplevel 1 [list expr $expression]]} {error "FAIL: $label"}
    incr ::checks
}
set checks 0

reset_fixture
set a [candidate a]; set b [candidate b]
add_cell core/endpoint FDRE 1
edge $a $b; edge $b core/endpoint
set r [recover]
check {[dict get $r owners $a] == 1 && [dict get $r owners $b] == 1} {positive chain}
check {[llength [dict get $r proofs]] == 2 && [dict get $r errors] eq {}} {proofs cover chain}
check {[lindex [lindex [dict get $r proofs] 0] 3] eq [list $b]} {immediate sink witness}

reset_fixture
set a [candidate a]; set b [candidate b]
add_cell core/left FDRE 0; add_cell core/right FDRE 1
edge $a $b core/right; edge $b core/left
set r [recover]
check {![dict exists $r owners $a] && [dict get $r owners $b] == 0} {mixed parent preserves valid child}
check {[dict get $r errors] eq [list [lindex $::errors 0]]} {original failed triplet preserved}

reset_fixture
set a [candidate a]
add_cell core/unassigned FDRE
edge $a core/unassigned
check {[dict get [recover] owners] eq {}} {unassigned sink rejected}
dict set ::known core/unassigned {}
check {[dict get [recover] owners] eq {}} {empty known owner rejected}

reset_fixture
set a [candidate a]; set b [candidate b]
edge $a $b; edge $b $a
check {[llength [dict get [recover] errors]] == 2} {cycle rejected}

reset_fixture
set a [candidate marked LUT2 1]; set b [candidate state FDRE]
add_cell core/end FDRE 0
edge $a core/end; edge $b core/end
check {[dict get [recover] owners] eq {}} {marked LUT and non-LUT rejected}

reset_fixture
set a [candidate a]
add_cell core/end FDRE 0
edge $a core/end
dict set ::ports $a top_port
check {[dict get [recover] owners] eq {}} {top-level port rejected}

reset_fixture
set a [candidate a]
add_cell core/end FDRE 0; add_cell core/other LUT1 0
edge $a core/end
dict set ::extra_drivers $a core/other
check {[dict get [recover] owners] eq {}} {multiple drivers rejected}

reset_fixture
set a [candidate a]
check {[dict get [recover] owners] eq {}} {no sink rejected}

reset_fixture
add_cell core/outside LUT5
add_cell core/end FDRE 1
edge core/outside core/end
lappend ::errors [list core/outside LUT5 original]
check {[dict get [recover] owners] eq {}} {outside bridge rejected}

reset_fixture
set a [candidate a]
add_cell core/known_lut LUT2 2
edge $a core/known_lut
# Known-owned logic is a terminating proof anchor: do not cross it to state
# beyond the ownership map (or walk through register cycles).
edge core/known_lut $a
check {[dict get [recover] owners $a] == 2} {known owner terminates traversal}
reset_fixture
set a [candidate a]
set endpoints {}
for {set i 0} {$i < 64} {incr i} {
    set endpoint core/end$i
    add_cell $endpoint FDRE 1
    lappend endpoints $endpoint
}
edge $a {*}$endpoints
set r [recover]
check {[dict get $r owners $a] == 1 && $::sink_queries == 1} {fanout sink cells resolved in one batch}

reset_fixture
set a [candidate a]
add_cell core/end FDRE 0
edge $a core/end
set ::bad_parent core/end/I0
check {[dict get [recover] owners] eq {}} {sink parent mismatch rejected}

reset_fixture
set a [candidate a]
add_cell core/end FDRE 0
edge $a core/end
set ::bad_direction core/end/I0
check {[dict get [recover] owners] eq {}} {bidirectional leaf pin rejected}

puts "PASSED: naive LUT ownership ($checks checks)"
