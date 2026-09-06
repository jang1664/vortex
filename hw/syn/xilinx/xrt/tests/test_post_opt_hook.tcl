# Plain Tcl lifecycle fixtures: no Vivado, DCP, synthesis or implementation.
set script_dir [file dirname [file normalize [info script]]]
set hook [file join [file dirname $script_dir] post_opt_hook.tcl]
set ::vortex_slr_definitions_only 1
source [file join [file dirname $script_dir] floorplan.tcl]
unset ::vortex_slr_definitions_only
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 1
set ::env(VORTEX_DMA_CHANNEL_FLOORPLAN) 0
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
set ::paths [dict create \
    0 {top/node/u_tmem_subsystem/u_dma_engine/control_reg} \
    1 {top/node/u_VX_gemm_unit_v2/u_compute_core/gen_accumulator[0].u_accumulator/g_latency1.xil_f32add_inst/U0/i_synth/HAS_ARESETN.sclr_i_reg} \
    2 {top/node/u_VX_gemm_unit_v2/u_compute_core/u_mxu/control_reg}]
set ::helper "[dict get $::paths 1]_xlnx_opt"
equal [::vortex::slr::owner_for [string range $::helper 9 end]] 1 actual_acc_helper_owner
proc fixture {} {
    set ::blocks {pblock_gemm_slr0 pblock_gemm_slr1 pblock_gemm_slr2}
    set ::membership [dict create platform/unrelated ROOT]
    foreach owner {0 1 2} {
        dict set ::membership [dict get $::paths $owner] pblock_gemm_slr$owner
    }
    # The FF existed at post-init; opt_design added its associated LUT later.
    dict set ::membership $::helper {}
    set ::properties [dict create]
    foreach block $::blocks {
        dict set ::properties $block [dict create IS_SOFT false CONTAIN_ROUTING false \
            EXCLUDE_PLACEMENT false SNAPPING_MODE NESTED GRID_RANGES FULL_SLR DERIVED_RANGES CLIPPED]
    }
    set ::calls {}; set ::adds {}; set ::ignored_add 0
    set ::property_refused 0; set ::boundary_error 0; set ::short_property_result 0
    set ::resolution_mode normal
}
proc get_pblocks {args} {
    set pattern [lindex $args end]
    return [lsearch -all -inline -glob $::blocks $pattern]
}
proc get_property {property objects} {
    if {$property in {NAME PBLOCK PARENT IS_PRIMITIVE}} {
        set names {}
        foreach object $objects {
            if {![string match {@*} $object]} {error __DUMMY_KEY__}
            lappend names [string range $object 1 end]
        }
        set objects $names
    }
    if {$property eq "NAME"} {return $objects}
    if {$property eq "PARENT"} {
        set result {}
        foreach cell $objects {lappend result [file dirname $cell]}
        if {[llength $objects] == 1} {return [lindex $result 0]}
        return $result
    }
    if {$property eq "IS_PRIMITIVE"} {
        set result {}
        foreach cell $objects {lappend result $::anchor_primitive}
        if {[llength $objects] == 1} {return [lindex $result 0]}
        return $result
    }
    if {$property eq "PBLOCK"} {
        set result {}
        foreach cell $objects {lappend result [dict get $::membership $cell]}
        if {$::short_property_result} {return [lrange $result 1 end]}
        if {[llength $objects] == 1} {return [lindex $result 0]}
        return $result
    }
    return [dict get $::properties $objects $property]
}
proc get_cells {args} {
    # Distinguish object handles from canonical names, and deliberately reorder
    # them so positional property/name assumptions cannot pass the fixture.
    set names [lreverse [lindex $args end]]
    switch -- $::resolution_mode {
        api_error {error __DUMMY_KEY__}
        missing {set names [lrange $names 1 end]}
        duplicate {lset names 0 [lindex $names end]}
        unexpected {lset names 0 platform/unexpected}
    }
    set objects {}
    foreach name $names {lappend objects "@$name"}
    return $objects
}
proc set_property {property value block} {
    if {$::property_refused && $property eq "IS_SOFT"} {return}
    dict set ::properties $block $property $value
}
proc add_cells_to_pblock {block cells} {
    lappend ::adds [list $block $cells]
    if {!$::ignored_add} {
        foreach cell $cells {dict set ::membership $cell $block}
    }
    # Model nested-RP property rewriting, as in the post-init fixture.
    dict set ::properties $block IS_SOFT true
}
proc ::vortex::slr::inventory {} {
    variable groups
    set groups $::paths
    dict lappend groups 1 $::helper
    lappend ::calls inventory
}
rename ::vortex::slr::anchor_homogeneous_hierarchy ::vortex::slr::fixture_anchor_homogeneous_hierarchy
proc ::vortex::slr::anchor_homogeneous_hierarchy {} {lappend ::calls anchor}
proc ::vortex::slr::require_marked_groups {} {lappend ::calls marked}
proc ::vortex::slr::validate_links {placed report} {lappend ::calls [list links $placed $report]}
proc ::vortex::slr::validate_boundary_nets {report} {
    lappend ::calls [list boundaries $report]
    if {$::boundary_error} {error "fixture illegal boundary"}
}
rename ::source ::fixture_source
proc source {path} {
    switch -- [file tail $path] {
        floorplan.tcl {
            equal $::vortex_slr_definitions_only 1 hook_does_not_reapply_post_init
        }
        slr_floorplan_report.tcl {lappend ::calls source_report}
        default {uplevel 1 [list ::fixture_source $path]}
    }
}
fixture
source $hook
equal $::calls [list inventory anchor source_report marked \
    [list links 0 post_opt_slr_links.tsv] \
    [list boundaries post_opt_slr_boundary_nets.tsv]] refresh_then_boundary_checks
equal [dict get $::membership $::helper] pblock_gemm_slr1 generated_helper_attached
equal [dict get $::membership platform/unrelated] ROOT platform_not_attached
equal [llength $::adds] 1 only_missing_owner_group_reattached
equal [dict get $::properties pblock_gemm_slr1 IS_SOFT] false hard_property_reasserted
set ::adds {}
source $hook
equal $::adds {} refresh_is_idempotent

# Missing membership must be detected per leaf, even when another member of
# the same group has the right pblock (a union-only check would falsely pass).
fixture
set cells [list [dict get $::paths 1] $::helper]
fails {get_property PBLOCK $cells} {*__DUMMY_KEY__*}
equal [::vortex::slr::cell_properties $cells PBLOCK] {pblock_gemm_slr1 {}} object_resolution_remaps_properties_to_input_order
equal [::vortex::slr::cell_properties [list $::helper] PBLOCK] [list {}] singleton_unassigned_pblock_retains_empty_value
equal [::vortex::slr::check_membership [list $::helper] pblock_gemm_slr1 1] 1 singleton_unassigned_is_counted_missing
equal [::vortex::slr::cell_properties [list [dict get $::paths 1]] PBLOCK] [list pblock_gemm_slr1] singleton_assigned_pblock
equal [::vortex::slr::cell_properties [list $::helper] PARENT] [list [file dirname $::helper]] singleton_parent_scalar
set ::anchor_primitive 0
equal [::vortex::slr::cell_properties [list $::helper] IS_PRIMITIVE] [list 0] singleton_boolean_scalar
set ::resolution_mode missing
fails {::vortex::slr::cell_properties [list $::helper] PBLOCK} {*incomplete PBLOCK inventory*}
set ::resolution_mode normal
set ::short_property_result 1
fails {::vortex::slr::cell_properties $cells PBLOCK} {*incomplete PBLOCK inventory*}
set ::short_property_result 0
fails {::vortex::slr::check_membership $cells pblock_gemm_slr1 0} {*missing user pblock membership*}
foreach mode {missing duplicate unexpected} {
    fixture
    set ::resolution_mode $mode
    if {$mode eq "unexpected"} {dict set ::membership platform/unexpected ROOT}
    set pattern [expr {$mode eq "missing" ? "*incomplete PBLOCK inventory*" : "*unexpected/duplicate resolved cell*"}]
    fails {::vortex::slr::cell_properties $cells PBLOCK} $pattern
}
fixture
set ::resolution_mode api_error
fails {::vortex::slr::cell_properties $cells PBLOCK} {*SLR cell property PBLOCK query failed*__DUMMY_KEY__*}
foreach current {ROOT {} pblock_platform_rp} {
    fixture
    dict set ::membership $::helper $current
    source $hook
    equal [dict get $::membership $::helper] pblock_gemm_slr1 root_or_ancestor_replaced_by_local_owner
}
fixture
dict set ::membership $::helper pblock_gemm_slr2
fails {source $hook} {*conflicting user pblock membership*}
equal $::adds {} conflict_fails_before_any_attachment
fixture
set ::ignored_add 1
fails {source $hook} {*missing user pblock membership*}
equal $::calls {inventory anchor} failed_attachment_stops_before_reports
fixture
set ::property_refused 1
fails {source $hook} {*post_opt: expected IS_SOFT=false*}
fixture
set ::short_property_result 1
# Corrupt a multi-object batch: a singleton empty PBLOCK is valid Vivado data.
fails {::vortex::slr::cell_properties $cells PBLOCK} {*incomplete PBLOCK inventory*}
fixture
set ::blocks {pblock_gemm_slr0 pblock_gemm_slr1}
fails {source $hook} {*exactly the three existing*}
fixture
lappend ::blocks pblock_dma_old
fails {source $hook} {*forbidden DMA*}
fixture
set ::boundary_error 1
fails {source $hook} {*fixture illegal boundary*}
fixture
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 0
source $hook
equal $::calls {} disabled_no_inventory_or_checks
equal $::adds {} disabled_no_mutation

# Exercise the real homogeneous-parent validator separately from hook mocks.
rename ::vortex::slr::anchor_homogeneous_hierarchy {}
rename ::vortex::slr::fixture_anchor_homogeneous_hierarchy ::vortex::slr::anchor_homogeneous_hierarchy
proc anchor_fixture {} {
    fixture
    set ::env(VORTEX_GEMM_MXU_COL) 1
    set ::anchor_primitive 0
    set ::vortex::slr::primitive_names {}; set ::vortex::slr::primitive_refs {}
    set ::vortex::slr::owners [dict create]
    set ::vortex::slr::roots {top/node}
    set ::anchor_parents {}
    set ::anchor_coverage [dict create]
    foreach {family ip} {gen_accumulator 32add gen_in_scaler 16mul gen_out_scaler 32mul} {
        set parent [format {top/node/u_VX_gemm_unit_v2/u_compute_core/%s[0].u_local/g_latency1.xil_f%s_inst/U0/i_synth} $family $ip]
        lappend ::anchor_parents $parent
        set cell "$parent/HAS_ARESETN.sclr_i_reg"
        lappend ::vortex::slr::primitive_names $cell
        lappend ::vortex::slr::primitive_refs FDRE
        dict set ::vortex::slr::owners $cell 1
        dict set ::membership $cell pblock_gemm_slr1
        dict set ::membership $parent pblock_dynamic_region
        dict set ::anchor_coverage $cell $parent
    }
}
anchor_fixture
::vortex::slr::validate_fp_anchor_coverage $::anchor_coverage
equal $::adds {} fp_profile_validator_does_not_add_redundant_anchors
set missing_coverage [dict remove $::anchor_coverage [lindex $::vortex::slr::primitive_names 0]]
fails {::vortex::slr::validate_fp_anchor_coverage $missing_coverage} {*lacks hierarchy inheritance*}
foreach owner {0 2 unowned} {
    anchor_fixture
    set child "[lindex $::anchor_parents 0]/unexpected_child"
    lappend ::vortex::slr::primitive_names $child
    lappend ::vortex::slr::primitive_refs LUT2
    if {$owner ne "unowned"} {dict set ::vortex::slr::owners $child $owner}
    fails {::vortex::slr::validate_fp_anchor_coverage $::anchor_coverage} {*mixed/unowned descendant*}
    equal $::adds {} mixed_parent_rejected_before_attachment
}
anchor_fixture
set ::anchor_primitive 1
fails {::vortex::slr::validate_fp_anchor_coverage $::anchor_coverage} {*not a retained hierarchy*}
anchor_fixture
set ::vortex::slr::primitive_names [lrange $::vortex::slr::primitive_names 0 end-1]
set ::vortex::slr::primitive_refs [lrange $::vortex::slr::primitive_refs 0 end-1]
fails {::vortex::slr::validate_fp_anchor_coverage $::anchor_coverage} {*profile mismatch for gen_out_scaler*}
anchor_fixture
dict set ::membership [lindex $::anchor_parents 0] pblock_gemm_slr2
fails {::vortex::slr::validate_fp_anchor_coverage $::anchor_coverage} {*conflicting user pblock membership*}
equal $::adds {} conflicting_anchor_rejected_before_attachment
rename ::source {}
rename ::fixture_source ::source
puts "PASS: $::checks post-opt ownership lifecycle and hook checks"
