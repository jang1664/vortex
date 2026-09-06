# Pure Tcl fixture: no Vivado, synthesis, implementation, or DCP is launched.
set ::vortex_slr_definitions_only 1
source [file join [file dirname [info script]] floorplan.tcl]
source [file join [file dirname [info script]] slr_floorplan_report.tcl]
set ::mock_cells {}
set ::mock_marked {}
set ::mock_part xcu55c-fsvh2892-2L-e
set ::mock_pins [dict create]
set ::mock_locations [dict create]
set ::mock_bels [dict create]
set ::mock_slrs [dict create]
set ::mock_refs [dict create]
set ::mock_pblock_properties [dict create]
proc get_cells {args} {
    set idx [lsearch -exact $args -of_objects]
    if {$idx >= 0} {return [file dirname [lindex $args [expr {$idx+1}]]]}
    if {[string first USER_SLL_REG $args] >= 0} {return $::mock_marked}
    return $::mock_cells
}
proc get_property {property object} {
    switch -- $property {
        PART {return $::mock_part}
        NAME {return $object}
        PARENT {
            set result {}
            foreach cell $object {lappend result [file dirname $cell]}
            return $result
        }
        REF_NAME {
            set result {}
            foreach cell $object {
                if {[dict exists $::mock_refs $cell]} {
                    lappend result [dict get $::mock_refs $cell]
                } else {lappend result FDRE}
            }
            return $result
        }
        USER_SLL_REG {return [expr {$object in $::mock_marked}]}
        REF_PIN_NAME {return [file tail $object]}
        DIRECTION {return [expr {[file tail $object] in {Q G P DOUTADOUT[0]} ? "OUT" : "IN"}]}
        LOC {return [dict get $::mock_locations $object]}
        BEL {return [dict get $::mock_bels $object]}
        IS_SOFT - CONTAIN_ROUTING - EXCLUDE_PLACEMENT - SNAPPING_MODE - GRID_RANGES - DERIVED_RANGES {
            return [dict get $::mock_pblock_properties $object $property]
        }
        default {error "unexpected mock property $property"}
    }
}
proc get_pins {args} {
    set idx [lsearch -exact $args -of_objects]
    set object [lindex $args [expr {$idx+1}]]
    if {[dict exists $::mock_pins $object]} {return [dict get $::mock_pins $object]}
    return "$object/D"
}
proc get_nets {args} {return mock_net}
proc get_slrs {args} {return [dict get $::mock_slrs [lindex $args end]]}
proc current_design {} {return mock_design}
proc get_pblocks {args} {
    if {[llength $args] == 1 && [string match pblock_gemm_slr* [lindex $args 0]]} {return [lindex $args 0]}
    return {}
}
proc equal {actual expected label} {
    if {$actual ne $expected} {error "$label: expected '$expected', got '$actual'"}
}
proc fails {script expression} {
    if {![catch {uplevel 1 $script} message] || ![string match $expression $message]} {
        error "expected failure '$expression', got '$message'"
    }
}
proc fixture {arrays} {
    set names {}
    foreach hierarchy {u_job_frontend u_VX_gemm_ctrl u_tmem_dma_ctrl u_VX_gemm_unit_v2/u_compute_core/u_mxu} {
        lappend names "$hierarchy/state_reg"
    }
    foreach resource {input weight scale zero_point output} {
        foreach prefix {u_ldma_ u_switch_} {lappend names "u_tmem_subsystem/$prefix$resource/state_reg"}
    }
    for {set idx 0} {$idx < $arrays} {incr idx} {
        lappend names [format {u_tmem_subsystem/g_bank[%d].u_bank/state_reg} $idx]
    }
    for {set idx 0} {$idx < 8} {incr idx} {
        lappend names [format {u_tmem_subsystem/u_dma_engine/g_channel[%d].u_dma_unit/state_reg} $idx]
        if {$arrays == 16} {
            lappend names [format {u_tmem_subsystem/g_dma_tmem_route[%d].g_pair.u_dma_pair_adapter/state_reg} $idx]
        }
    }
    foreach resource {input weight scale zero_point} {
        foreach direction {request response} {
            foreach half {tx rx} {
                lappend names [format {u_tmem_subsystem/u_%s_req_reservation/u_slr/u_%s/u_%s/state_reg} $resource $direction $half]
            }
        }
    }
    foreach half {tx rx} {
        lappend names "u_tmem_subsystem/u_output_slr/u_request/u_$half/state_reg"
        foreach stream {commands completions} {lappend names "u_gemm_dma_slr_bridge/u_$stream/u_$half/state_reg"}
    }
    foreach group {input_tx input_rx weight_tx weight_rx output_tx output_rx local_ownership} {
        lappend names "u_VX_gemm_unit_v2/u_compute_core/g_slr_mxu_$group.payload_q_reg"
    }
    foreach half {tx rx} {
        lappend names "u_VX_gemm_unit_v2/u_compute_core/g_slr_mxu_input_$half.data_q_reg"
    }
    foreach {slr half} {0 tx 1 rx} {lappend names "u_gemm_dma_slr_bridge/g_slr$slr.idle_${half}_q_reg"}
    set ::mock_cells {}
    foreach name $names {lappend ::mock_cells "top/node/$name"}
    set ::env(VORTEX_GEMM_TMEM_BANKS) $arrays
    set ::env(VORTEX_GEMM_MXU_COL) [expr {$arrays == 8 ? 32 : 16}]
}

set ::env(VORTEX_DMA_CHANNEL_FLOORPLAN) 0
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 1
foreach arrays {8 16} {
    fixture $arrays
    ::vortex::slr::inventory
    equal [dict size $::vortex::slr::owners] [llength $::mock_cells] "leaf coverage ($arrays arrays)"
}
# Unconsumed status may disappear completely, but never accept half a pair
# or a surviving pair that lost USER_SLL_REG on either endpoint.
fixture 8
set complete_fixture $::mock_cells
set ::mock_cells [lrange $complete_fixture 0 end-2]
set ::mock_marked $::mock_cells
::vortex::slr::inventory
::vortex::slr::require_marked_groups
set ::mock_cells [lrange $complete_fixture 0 end-1]
fails {::vortex::slr::inventory} {*DMA idle SLR1*}
set ::mock_cells $complete_fixture
::vortex::slr::inventory
set ::mock_marked [lrange $complete_fixture 0 end-1]
fails {::vortex::slr::require_marked_groups} {*marked DMA idle SLR1*}
set ::mock_marked $complete_fixture
::vortex::slr::require_marked_groups
set ::mock_cells [lsearch -all -inline -not -glob $complete_fixture *g_slr_mxu_input_rx.data_q_reg]
fails {::vortex::slr::inventory} {*MXU input data rx*}
equal [::vortex::slr::owner_for u_tmem_subsystem/u_output_slr/u_request/u_tx/payload_tx_q_reg] 1 request_tx
equal [::vortex::slr::owner_for u_tmem_subsystem/u_output_slr/u_request/u_rx/payload_rx_q_reg] 0 request_rx
equal [::vortex::slr::owner_for u_tmem_subsystem/u_input_req_reservation/u_slr/u_response/u_tx/payload_tx_q_reg] 0 response_tx
equal [::vortex::slr::owner_for u_VX_gemm_unit_v2/u_compute_core/g_slr_mxu_input_rx.payload_q_reg] 2 mxu_rx
equal [::vortex::slr::owner_for u_commands/u_rx/read_q0] 0 lifted_command_read_pointer
equal [::vortex::slr::owner_for u_commands/u_rx/write_q0_rep__1] 0 lifted_command_write_pointer_replica
equal [::vortex::slr::owner_for u_commands/u_rx/unrelated_control] 1 unrelated_lifted_name_not_assumed_slr0
equal [::vortex::slr::register_role {top/node/u_VX_gemm_unit_v2/u_compute_core/g_slr_mxu_input_tx.data_q_reg[0]}] tx mxu_preserved_data_role
equal [::vortex::slr::register_role {top/node/u_tmem_subsystem/u_weight_req_reservation/u_slr/u_response/u_tx/g_payload[7].payload_tx_q_reg}] tx per_bit_tx_role
equal [::vortex::slr::link_group {top/node/u_tmem_subsystem/u_weight_req_reservation/u_slr/u_response/u_tx/g_payload[7].payload_tx_q_reg}] top/node/u_tmem_subsystem/u_weight_req_reservation/u_slr/u_response/payload per_bit_tx_group
fails {::vortex::slr::owner_for u_tmem_subsystem/new_unknown/state_reg} {*unclassified TMEM*}
fixture 8
set ::mock_cells [lrange $::mock_cells 1 end]
fails {::vortex::slr::inventory} {*missing required group*}
set ::env(VORTEX_DMA_CHANNEL_FLOORPLAN) 1
fails {::vortex::slr::enabled} {*retired*}
set ::env(VORTEX_DMA_CHANNEL_FLOORPLAN) 0
set ::mock_part xcvu9p-flga2104-2L-e
fails {::vortex::slr::apply} {*XCU55C only*}
set ::mock_part xcu55c-fsvh2892-2L-e

# Exact direct FF pairing and actual Laguna evidence, including negative cases.
set tx top/node/u_VX_gemm_unit_v2/u_compute_core/g_slr_mxu_input_tx.payload_q_reg
set rx top/node/u_VX_gemm_unit_v2/u_compute_core/g_slr_mxu_input_rx.payload_q_reg
set ::mock_marked [list $tx $rx]
set ::vortex::slr::owners [dict create $tx 1 $rx 2]
dict set ::mock_pins mock_net [list "$tx/Q" "$rx/D"]
dict set ::mock_locations $tx LAGUNA_X0Y0
dict set ::mock_locations $rx LAGUNA_X0Y1
dict set ::mock_bels $tx TX_REG0
dict set ::mock_bels $rx RX_REG0
dict set ::mock_slrs $tx SLR1
dict set ::mock_slrs $rx SLR2
set channel [file tempfile report_file vortex-slr-fixture-]
close $channel
::vortex::slr::validate_links 0 $report_file
::vortex::slr::validate_links 1 $report_file
dict set ::mock_locations $rx SLICE_X0Y0
fails {::vortex::slr::validate_links 1 $report_file} {*no actual Laguna*}
dict set ::mock_pins mock_net [list top/unmarked_lut/O "$rx/D"]
fails {::vortex::slr::validate_links 0 $report_file} {*not exactly one direct driver*}
# Constant metadata FFs may survive after the TX is folded away. Only actual
# constant primitives are exempt; a BRAM output is a real unregistered link.
set ::mock_marked [list $rx]
set ::vortex::slr::owners [dict create $rx 2]
foreach {ref pin} {GND G VCC P} {
    set constant "top/node/$ref"
    dict set ::mock_refs $constant $ref
    dict set ::mock_pins mock_net [list "$constant/$pin" "$rx/D"]
    ::vortex::slr::validate_links 0 $report_file
    set report [open $report_file r]
    set contents [read $report]
    close $report
    equal [string match {*# tieoff group=*} $contents] 1 "constant tieoff is reported"
}
set ram top/node/response_ram
dict set ::mock_refs $ram RAMB36E2
set ::vortex::slr::owners [dict create $rx 2 $ram 1]
dict set ::mock_pins mock_net [list "$ram/DOUTADOUT\[0\]" "$rx/D"]
fails {::vortex::slr::validate_links 0 $report_file} {*not directly driven by a marked TX FF Q*}

# Exercise the actual apply procedure with leaf/placement APIs isolated.
# Its report source must load before both link and full-boundary checks, and
# an unregistered boundary must stop post-init rather than reaching place.
set ::apply_calls {}
set ::boundary_error ""
foreach command {inventory require_marked_groups validate_links validate_boundary_nets} {
    rename ::vortex::slr::$command ::vortex::slr::fixture_saved_$command
}
rename ::source ::fixture_saved_source
proc source {path} {
    if {[file tail $path] eq "slr_floorplan_report.tcl"} {
        lappend ::apply_calls source_report
        return
    }
    uplevel 1 [list ::fixture_saved_source $path]
}
proc ::vortex::slr::inventory {} {
    variable groups
    set groups [dict create 0 source_leaf 1 middle_leaf 2 compute_leaf]
    lappend ::apply_calls inventory
}
proc ::vortex::slr::require_marked_groups {} {lappend ::apply_calls marked}
proc ::vortex::slr::validate_links {placed report} {lappend ::apply_calls [list links $placed $report]}
proc ::vortex::slr::validate_boundary_nets {report} {
    lappend ::apply_calls [list boundaries $report]
    if {$::boundary_error ne ""} {error $::boundary_error}
}
set ::reject_post_add_property 0
proc create_pblock {block} {
    dict set ::mock_pblock_properties $block [dict create \
        IS_SOFT true CONTAIN_ROUTING false EXCLUDE_PLACEMENT false \
        SNAPPING_MODE NESTED GRID_RANGES FULL_SLR DERIVED_RANGES PLATFORM_CLIPPED_SLR \
        ADDED 0]
}
proc resize_pblock {args} {}
proc set_property {property value block} {
    if {$::reject_post_add_property && $property eq "EXCLUDE_PLACEMENT"
        && [dict get $::mock_pblock_properties $block ADDED]} {return}
    dict set ::mock_pblock_properties $block $property $value
}
proc add_cells_to_pblock {block cells} {
    # Model Vivado changing properties when RP ownership becomes established.
    foreach property {IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT} {
        dict set ::mock_pblock_properties $block $property true
    }
    dict set ::mock_pblock_properties $block ADDED 1
}
set expected_calls [list inventory source_report marked \
    [list links 0 post_init_slr_links.tsv] \
    [list boundaries post_init_slr_boundary_nets.tsv]]
::vortex::slr::apply
equal $::apply_calls $expected_calls post_init_complete_check_order
foreach block {pblock_gemm_slr0 pblock_gemm_slr1 pblock_gemm_slr2} {
    foreach property {IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT} {
        equal [dict get $::mock_pblock_properties $block $property] false post_add_properties_reapplied
    }
}
set ::apply_calls {}
set ::reject_post_add_property 1
fails {::vortex::slr::apply} {*post_add: expected EXCLUDE_PLACEMENT=false*}
equal $::apply_calls {inventory} post_add_property_failure_stops_before_link_checks
set ::reject_post_add_property 0
set ::apply_calls {}
set ::boundary_error "fixture unregistered partition boundary"
fails {::vortex::slr::apply} {*fixture unregistered partition boundary*}
equal $::apply_calls $expected_calls post_init_boundary_failure_propagates
set ::apply_calls {}
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 0
::vortex::slr::apply
equal $::apply_calls {} disabled_floorplan_does_not_source_or_validate
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 1
rename ::source {}
rename ::fixture_saved_source ::source
foreach command {inventory require_marked_groups validate_links validate_boundary_nets} {
    rename ::vortex::slr::$command {}
    rename ::vortex::slr::fixture_saved_$command ::vortex::slr::$command
}
puts "PASS: SLR ownership, profile inventory, retired options, direct FF pairs and Laguna checks"
puts "Fixture report (temporary): $report_file"
