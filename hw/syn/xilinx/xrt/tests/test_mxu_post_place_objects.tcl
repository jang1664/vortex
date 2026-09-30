# Plain Tcl regression for placed SLR lookup: no Vivado or implementation.
set script_dir [file dirname [file normalize [info script]]]
set ::vortex_slr_definitions_only 1
source [file join [file dirname $script_dir] mxu_slr_floorplan.tcl]
unset ::vortex_slr_definitions_only
set ::env(VORTEX_GEMM_MXU_SLR_FLOORPLAN) 1
set ::checks 0
proc equal {actual expected label} {
    incr ::checks
    if {$actual ne $expected} {error "$label: expected '$expected', got '$actual'"}
}
proc fails {script pattern} {
    incr ::checks
    if {![catch {uplevel 1 $script} message] || ![string match $pattern $message]} {
        error "expected '$pattern', got '$message'"
    }
}
proc fixture {} {
    set ::paths [dict create 1 {top/slr1/a top/slr1/b} 2 {top/slr2/a top/slr2/b}]
    set ::membership {}; set ::placement {}
    foreach slr {1 2} {
        foreach name [dict get $::paths $slr] {
            dict set ::membership $name pblock_mxu_slr$slr
            dict set ::placement $name SLR$slr
        }
    }
    set ::resolution_mode normal
    set ::name_mode normal
    set ::calls {}; set ::typed_slr_queries 0
    set ::bad_property 0
}
proc get_cells {args} {
    set names [lreverse [lindex $args end]]
    switch -- $::resolution_mode {
        missing {set names [lrange $names 1 end]}
        duplicate {lset names 0 [lindex $names end]}
        unexpected {lset names 0 top/unexpected}
        extra {lappend names top/extra}
        api_error {error "fixture get_cells error"}
    }
    set objects {}
    foreach name $names {lappend objects "@$name"}
    return $objects
}
proc get_property {property objects} {
    if {$property in {NAME PBLOCK}} {
        set names {}
        foreach object $objects {
            if {![string match {@*} $object]} {error "expected typed cell object"}
            lappend names [string range $object 1 end]
        }
        if {$property eq "NAME"} {
            if {$::name_mode eq "short"} {return [lrange $names 1 end]}
            return $names
        }
        set values {}
        foreach name $names {lappend values [dict get $::membership $name]}
        if {[llength $names] == 1} {return [lindex $values 0]}
        return $values
    }
    switch -- $property {
        IS_SOFT {return $::bad_property}
        CONTAIN_ROUTING - EXCLUDE_PLACEMENT {return false}
        SNAPPING_MODE {return NESTED}
        GRID_RANGES - DERIVED_RANGES {return FULL_SLR}
        default {error "unexpected property $property"}
    }
}
proc get_slrs {args} {
    set objects [lindex $args end]
    foreach object $objects {
        # Model the expensive source-run failure: canonical names return no
        # placement, while objects resolved by get_cells return physical SLRs.
        if {![string match {@*} $object]} {return {}}
    }
    incr ::typed_slr_queries
    set result {}
    foreach object $objects {
        set slr [dict get $::placement [string range $object 1 end]]
        if {$slr ne ""} {lappend result $slr}
    }
    return [lsort -unique $result]
}
proc get_pblocks {args} {
    return [lsearch -all -inline -glob \
        {pblock_mxu_slr1 pblock_mxu_slr2} [lindex $args end]]
}
proc report_utilization {args} {lappend ::calls utilization}
proc report_timing {args} {lappend ::calls timing}
proc ::vortex::mxu_slr::inventory {} {variable groups; set groups $::paths}
proc ::vortex::mxu_slr::require_marked_groups {} {lappend ::calls marked}
proc ::vortex::mxu_slr::check_links {placed report} {
    lappend ::calls [list links $placed $report]
}
proc ::vortex::mxu_slr::check_tree_ports {args} {lappend ::calls boundaries}

fixture
set names [dict get $::paths 1]
equal [get_slrs -quiet -of_objects $names] {} raw_names_reproduce_empty_slr
equal [::vortex::mxu_slr::cell_objects {}] {} empty_input
equal [::vortex::mxu_slr::cell_objects $names] {@top/slr1/b @top/slr1/a} reordered_objects_preserved
equal [::vortex::mxu_slr::cell_objects [list [lindex $names 0]]] {@top/slr1/a} singleton_object
foreach {mode pattern} {
    missing {*incomplete cell-object inventory*}
    extra {*incomplete cell-object inventory*}
    duplicate {*unexpected/duplicate resolved cell object*}
    unexpected {*unexpected/duplicate resolved cell object*}
    api_error {*SLR cell-object resolution failed*fixture get_cells error*}
} {
    set ::resolution_mode $mode
    fails {::vortex::mxu_slr::cell_objects $names} $pattern
}
set ::resolution_mode normal
set ::name_mode short
fails {::vortex::mxu_slr::cell_objects $names} {*incomplete cell-object inventory*}
set ::name_mode normal
fails {::vortex::mxu_slr::cell_objects {top/slr1/a top/slr1/a}} {*duplicate requested cell name*}

fixture
::vortex::mxu_slr::check_placed
equal $::typed_slr_queries 2 all_groups_use_typed_objects
equal $::calls [list utilization utilization \
    [list links 1 post_place_mxu_slr_links.tsv] boundaries timing] downstream_gates_preserved
foreach {target_slr pattern} {
    {} {*unexpected SLR(s): *}
    SLR0 {*unexpected SLR(s): SLR0*}
} {
    fixture
    foreach name [dict get $::paths 1] {dict set ::placement $name $target_slr}
    fails {::vortex::mxu_slr::check_placed} $pattern
    equal $::calls {} stops_before_link_checks_on_invalid_slr
}
fixture
dict set ::placement top/slr1/b SLR0
fails {::vortex::mxu_slr::check_placed} {*unexpected SLR(s): SLR0 SLR1*}
fixture
dict set ::membership top/slr1/b pblock_mxu_slr2
fails {::vortex::mxu_slr::check_placed} {*conflicting user pblock membership*}
equal $::typed_slr_queries 0 membership_gate_precedes_placement_query
fixture
set ::bad_property true
fails {::vortex::mxu_slr::check_placed} {*expected IS_SOFT=false*}
equal $::typed_slr_queries 0 hard_pblock_gate_preserved
puts "PASS: $::checks post-place typed-object checks"
