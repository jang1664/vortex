# Pure Tcl hierarchy analysis; no Vivado or implementation is invoked.
set ::vortex_slr_definitions_only 1
source [file join [file dirname [info script]] .. floorplan.tcl]
set checks 0
proc equal {actual expected label} {
    incr ::checks
    if {$actual ne $expected} {error "$label: expected '$expected', got '$actual'"}
}
proc fails {script pattern} {
    incr ::checks
    if {![catch {uplevel 1 $script} result] || ![string match $pattern $result]} {error "expected '$pattern', got '$result'"}
}
proc hierarchy {name} {
    if {[dict exists $::hier $name]} {return}
    set parent [file dirname $name]
    if {$name ne "top/node"} {hierarchy $parent}
    dict set ::hier $name $parent
}
proc leaf {name owner {ref FDRE}} {
    set parent [file dirname $name]
    hierarchy $parent
    lappend ::leaves $name; lappend ::parents $parent; lappend ::refs $ref
    if {$owner ne "unowned"} {dict set ::owners $name $owner}
}
proc select {} {
    return [::vortex::slr::select_homogeneous_anchors \
        [dict keys $::hier] [dict values $::hier] $::leaves $::parents $::refs $::owners {top/node}]
}
set hier {}; set leaves {}; set parents {}; set refs {}; set owners {}
set rr {top/node/u_tmem_subsystem/u_switch_input/rsp_arb/g_input_select.g_arbiter.arbiter/g_round_robin.rr_arbiter/g_model1.reqs_mask_reg[0]}
leaf $rr 0
leaf top/node/u_tmem_subsystem/u_switch_input/other_local/data_reg 0
set core top/node/u_VX_gemm_unit_v2/u_compute_core
set fp_cells {}
foreach {family ip} {gen_accumulator 32add gen_in_scaler 16mul gen_out_scaler 32mul} {
    set name [format {%s/%s[0].u_local/g_latency1.xil_f%s_inst/U0/i_synth/HAS_ARESETN.sclr_i_reg} $core $family $ip]
    leaf $name 1
    lappend fp_cells $name
}
leaf $core/u_mxu/pe/data_reg 2
set stream top/node/u_tmem_subsystem/u_weight_req_reservation/u_slr/u_request/g_slr/u_link
leaf $stream/u_tx/valid_tx_q_reg 1
leaf $stream/u_rx/valid_rx_q_reg 0
leaf top/node/u_tmem_subsystem/direct_control_reg 0
leaf top/node/direct_control_reg 1
leaf top/node/local/known/data_reg 1
leaf top/node/local/unowned_clock unowned BUFGCE
leaf top/node/local/known/constant unowned GND
leaf top/node/constant_only/value unowned VCC
leaf top/node/mixed/zero_reg 0
leaf top/node/mixed/two_reg 2
set result [select]
set groups [dict get $result groups]
set coverage [dict get $result covered]
equal [dict get $coverage $rr] top/node/u_tmem_subsystem/u_switch_input maximal_arbiter_island
equal [dict get $coverage $core/u_mxu/pe/data_reg] $core/u_mxu maximal_compute_island
foreach fp $fp_cells {
    set expected [lindex [split [string range $fp [expr {[string length $core]+1}] end] /] 0]
    equal [dict get $coverage $fp] $core/$expected fp_special_cases_subsumed
}
equal [dict get $coverage $stream/u_tx/valid_tx_q_reg] $stream/u_tx source_half_owner_preserved
equal [dict get $coverage $stream/u_rx/valid_rx_q_reg] $stream/u_rx destination_half_owner_preserved
equal [dict get $coverage top/node/local/known/data_reg] top/node/local/known unowned_parent_descends_to_safe_child
equal [llength [dict get $result uncovered]] 4 mixed_parent_direct_leaves_reported
foreach owner {0 1 2} {
    foreach anchor [dict get $groups $owner] {
        equal [expr {$anchor in {top/node top/node/u_tmem_subsystem top/node/u_VX_gemm_unit_v2 top/node/u_VX_gemm_unit_v2/u_compute_core top/node/local top/node/mixed}}] 0 mixed_or_barrier_parent_not_anchored
    }
}
equal [expr {[lsearch -exact [concat {*}[dict values $groups]] top/node/constant_only] < 0}] 1 constant_only_not_anchored
# Model a helper created after anchor selection using nearest selected parent.
set rr_helper "${rr}_xlnx_opt"
equal [string first "[dict get $coverage $rr]/" $rr_helper] 0 late_arbiter_helper_inside_uniform_owner
set bad_parents $parents
lset bad_parents 0 top/node/nonexistent
fails {::vortex::slr::select_homogeneous_anchors [dict keys $hier] [dict values $hier] $leaves $bad_parents $refs $owners {top/node}} {*owned leaf is outside retained GEMM hierarchy*}
set absent_owner $owners
dict set absent_owner top/node/absent_leaf 0
fails {::vortex::slr::select_homogeneous_anchors [dict keys $hier] [dict values $hier] $leaves $parents $refs $absent_owner {top/node}} {*owned-leaf coverage cardinality mismatch*}
set bad_hier $hier
dict set bad_hier top/node/local top/node/nonexistent
fails {::vortex::slr::select_homogeneous_anchors [dict keys $bad_hier] [dict values $bad_hier] $leaves $parents $refs $owners {top/node}} {*broken retained PARENT chain*}
fails {::vortex::slr::select_homogeneous_anchors [dict keys $hier] [dict values $hier] $leaves $parents [lrange $refs 1 end] $owners {top/node}} {*incomplete hierarchy-analysis input*}
set missing_root [dict remove $hier top/node]
fails {::vortex::slr::select_homogeneous_anchors [dict keys $missing_root] [dict values $missing_root] $leaves $parents $refs $owners {top/node}} {*missing retained GEMM root*}
fails {::vortex::slr::select_homogeneous_anchors [concat [dict keys $hier] top/node] [concat [dict values $hier] top] $leaves $parents $refs $owners {top/node}} {*duplicate retained hierarchy*}

# Even a currently homogeneous architectural container is a permanent barrier.
set barrier_result [::vortex::slr::select_homogeneous_anchors \
    {top/node top/node/u_tmem_subsystem top/node/u_tmem_subsystem/u_switch_input} \
    {top top/node top/node/u_tmem_subsystem} \
    {top/node/u_tmem_subsystem/u_switch_input/reg} \
    {top/node/u_tmem_subsystem/u_switch_input} {FDRE} \
    {top/node/u_tmem_subsystem/u_switch_input/reg 0} {top/node}]
equal [dict get $barrier_result groups 0] top/node/u_tmem_subsystem/u_switch_input permanent_mixed_container_barrier

# Actual Vivado DSP hierarchy: the DSP48E2 parent and its DSP_* children all
# appear in the primitive snapshot. Only the surrounding FSM is an anchor.
set dsp_root top/node/u_VX_gemm_ctrl
set dsp_fsm $dsp_root/u_VX_gemm_fsm
set dsp $dsp_fsm/I_KT_STRIDE_FULL_q1
set dsp_names [list $dsp $dsp/DSP_ALU_INST $dsp/DSP_PREADD_INST $dsp/DSP_PREADD_INST/INTERNAL_REG]
set dsp_parents [list $dsp_fsm $dsp $dsp $dsp/DSP_PREADD_INST]
set dsp_refs {DSP48E2 DSP_ALU DSP_PREADD FDRE}
set dsp_owners {}
foreach name $dsp_names {dict set dsp_owners $name 1}
set dsp_hier [list top/node $dsp_root $dsp_fsm]
set dsp_hier_parents [list top top/node $dsp_root]
set dsp_result [::vortex::slr::select_homogeneous_anchors $dsp_hier $dsp_hier_parents $dsp_names $dsp_parents $dsp_refs $dsp_owners {top/node}]
equal [dict get $dsp_result groups 1] $dsp_root composite_primitive_inherits_nearest_uniform_hierarchy
equal [dict get $dsp_result uncovered] {} nested_primitive_children_are_covered
foreach name $dsp_names {equal [dict get $dsp_result covered $name] $dsp_root dsp_container_and_all_children_accounted}
foreach child_owner {0 2 unowned} {
    set changed $dsp_owners
    if {$child_owner eq "unowned"} {dict unset changed $dsp/DSP_ALU_INST} else {dict set changed $dsp/DSP_ALU_INST $child_owner}
    set mixed_result [::vortex::slr::select_homogeneous_anchors $dsp_hier $dsp_hier_parents $dsp_names $dsp_parents $dsp_refs $changed {top/node}]
    equal [concat {*}[dict values [dict get $mixed_result groups]]] {} mixed_or_unowned_dsp_child_blocks_ancestor
    equal [llength [dict get $mixed_result uncovered]] [dict size $changed] primitive_composite_cannot_be_anchor
}
set broken $dsp_parents
lset broken 0 $dsp
fails {::vortex::slr::select_homogeneous_anchors $dsp_hier $dsp_hier_parents $dsp_names $broken $dsp_refs $dsp_owners {top/node}} {*broken retained PARENT chain*}
lset broken 0 $dsp/DSP_PREADD_INST
fails {::vortex::slr::select_homogeneous_anchors $dsp_hier $dsp_hier_parents $dsp_names $broken $dsp_refs $dsp_owners {top/node}} {*broken retained PARENT chain*}
lset broken 0 $dsp_fsm/missing_container
fails {::vortex::slr::select_homogeneous_anchors $dsp_hier $dsp_hier_parents $dsp_names $broken $dsp_refs $dsp_owners {top/node}} {*broken retained PARENT chain*}

# Run the real runtime attachment/report wrapper with typed object mocks.
# API queries may reorder objects; no property API accepts raw name strings.
set ::vortex::slr::primitive_names $leaves
set ::vortex::slr::primitive_parents $parents
set ::vortex::slr::primitive_refs $refs
set ::vortex::slr::owners $owners
set ::vortex::slr::roots {top/node}
set initial_pb {}
foreach name [dict keys $hier] {dict set initial_pb $name pblock_dynamic_region}
foreach name $leaves {
    dict set initial_pb $name [expr {[dict exists $owners $name] ? "pblock_gemm_slr[dict get $owners $name]" : "ROOT"}]
}
set mock_pb $initial_pb; set adds {}; set query_calls 0
proc get_cells {args} {
    incr ::query_calls
    if {[lsearch -exact $args -filter] >= 0} {
        equal [expr {[lsearch -exact $args -include_replicated_objects] >= 0}] 1 runtime_includes_replicated_hierarchies
        set names [dict keys $::hier]
    } else {set names [lindex $args end]}
    set objects {}
    foreach name [lreverse $names] {lappend objects "@$name"}
    return $objects
}
proc get_property {property objects} {
    set values {}
    foreach object $objects {
        if {![string match {@*} $object]} {error "raw name passed to property API"}
        set name [string range $object 1 end]
        switch -- $property {
            NAME {set value $name}
            PARENT {set value [dict get $::hier $name]}
            IS_PRIMITIVE {set value [expr {![dict exists $::hier $name]}]}
            PBLOCK {set value [dict get $::mock_pb $name]}
            default {error "unexpected property $property"}
        }
        lappend values $value
    }
    if {[llength $objects] == 1 && $property ne "NAME"} {return [lindex $values 0]}
    return $values
}
proc get_pblocks {name} {return $name}
proc add_cells_to_pblock {block objects} {
    foreach object $objects {
        if {![string match {@*} $object]} {error "runtime attachment did not resolve cell objects"}
        set name [string range $object 1 end]
        lappend ::adds [list $name $block]
        foreach cell [dict keys $::mock_pb] {
            if {$cell eq $name || [string first "$name/" $cell] == 0} {dict set ::mock_pb $cell $block}
        }
    }
}
rename ::vortex::slr::validate_fp_anchor_coverage ::vortex::slr::saved_validate_fp_anchor_coverage
proc ::vortex::slr::validate_fp_anchor_coverage {coverage} {
    foreach fp $::fp_cells {equal [dict exists $coverage $fp] 1 runtime_preserves_fp_coverage_gate}
}
set temp_channel [file tempfile token vortex-hierarchy-fixture-]
close $temp_channel
file mkdir "$token.dir"
set old_pwd [pwd]
cd "$token.dir"
::vortex::slr::anchor_homogeneous_hierarchy
equal [dict get $mock_pb [dict get $coverage $rr]] pblock_gemm_slr0 runtime_arbiter_anchor_owned
equal [dict get $mock_pb top/node] pblock_dynamic_region runtime_never_anchors_gemm_parent
set file [open post_opt_slr_uncovered_leaves.tsv r]
set text [read $file]
close $file
equal [string match {*top/node/direct_control_reg*FDRE*} $text] 1 uncovered_ff_is_reported
set first_adds $adds
set adds {}
::vortex::slr::anchor_homogeneous_hierarchy
equal $adds $first_adds runtime_idempotent_hierarchy_assignment
set adds {}; set mock_pb $initial_pb
dict set mock_pb top/node/u_tmem_subsystem/u_switch_input pblock_gemm_slr2
fails {::vortex::slr::anchor_homogeneous_hierarchy} {*conflicting user pblock membership*}
equal $adds {} conflicting_anchor_fails_before_any_mutation
cd $old_pwd
rename ::vortex::slr::validate_fp_anchor_coverage {}
rename ::vortex::slr::saved_validate_fp_anchor_coverage ::vortex::slr::validate_fp_anchor_coverage

# Optional large, repeatable CPU-only runtime check of the production algorithm.
set count 10000
if {$argc == 2 && [lindex $argv 0] eq "--benchmark"} {set count [lindex $argv 1]}
set hier {}; set leaves {}; set parents {}; set refs {}; set owners {}
for {set index 0} {$index < $count} {incr index} {
    set owner [expr {$index % 3}]
    leaf "top/node/island$owner/data_$index" $owner
}
set begin [clock milliseconds]
set result [select]
set elapsed [expr {[clock milliseconds]-$begin}]
equal [dict get $result uncovered] {} benchmark_all_leaves_covered
foreach owner {0 1 2} {equal [dict get $result groups $owner] top/node/island$owner benchmark_maximal_islands}
puts "PASS: $checks homogeneous-anchor checks; leaves=$count analysis_ms=$elapsed"
