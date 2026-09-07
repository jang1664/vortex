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
proc fixture {arrays {spelling slash} {channels {}} {mxu {}}} {
    if {$channels eq {}} {set channels [expr {$arrays == 4 ? 4 : 8}]}
    if {$mxu eq {}} {set mxu [expr {$arrays == 16 ? 16 : 32}]}
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
    for {set idx 0} {$idx < $channels} {incr idx} {
        lappend names [format {u_tmem_subsystem/u_dma_engine/g_channel[%d].u_dma_unit/state_reg} $idx]
        if {$mxu == 16 && $arrays == 2 * $channels} {
            lappend names [format {u_tmem_subsystem/g_dma_tmem_route[%d].g_pair.u_dma_pair_adapter/state_reg} $idx]
        } elseif {$mxu == 32 && $arrays == 2 * $channels} {
            lappend names [format {u_tmem_subsystem/g_dma_tmem_route[%d].g_bank_select/rsp_locked_r_reg} $idx]
        }
    }
    foreach resource {input weight scale zero_point} {
        foreach direction {request response} {
            foreach half {tx rx} {
                lappend names [format {u_tmem_subsystem/u_%s_req_reservation/u_slr/u_%s/g_slr/u_link/u_%s/state_reg} $resource $direction $half]
            }
        }
    }
    foreach half {tx rx} {
        lappend names "u_tmem_subsystem/u_output_slr/u_request/g_slr/u_link/u_$half/state_reg"
        foreach stream {commands completions} {lappend names "u_gemm_dma_transport/u_$stream/g_slr/u_link/u_$half/state_reg"}
    }
    foreach group {input_tx input_rx weight_tx weight_rx output_tx output_rx local_ownership} {
        lappend names "u_VX_gemm_unit_v2/u_compute_core/g_slr_mxu_$group.payload_q_reg"
    }
    foreach half {tx rx} {
        lappend names "u_VX_gemm_unit_v2/u_compute_core/g_slr_mxu_input_$half.data_q_reg"
    }
    foreach {slr half} {0 tx 1 rx} {lappend names "u_gemm_dma_transport/g_slr_status/g_slr$slr.idle_${half}_q_reg"}
    set ::mock_cells {}
    set index 0
    foreach name $names {
        if {$spelling eq "dot" || ($spelling eq "mixed" && $index % 2)} {
            set name [string map {/g_slr/u_link/ /g_slr.u_link/} $name]
        }
        lappend ::mock_cells "top/node/$name"
        incr index
    }
    set ::env(VORTEX_GEMM_TMEM_BANKS) $arrays
    set ::env(VORTEX_GEMM_MXU_COL) $mxu
    set ::env(VORTEX_GEMM_MXU_ROW) $mxu
    set ::env(VORTEX_GEMM_HBM_DATA_BYTES) 64
    set ::env(VORTEX_GEMM_DMA_CHANNELS) $channels
    set ::env(VORTEX_GEMM_HBM_PORTS) $channels
}

set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 1
foreach arrays {4 8 16} {
    foreach spelling {slash dot mixed} {
        fixture $arrays $spelling
        ::vortex::slr::inventory
        equal [dict size $::vortex::slr::owners] [llength $::mock_cells] "leaf coverage ($arrays arrays, $spelling)"
        foreach cell $::mock_cells {
            equal [dict exists $::vortex::slr::owners $cell] 1 original_cell_key_retained
        }
        set ::mock_marked $::mock_cells
        ::vortex::slr::require_marked_groups
    }
}
# The source organization, not membership in a profile list, determines the
# topology. Cover both port counts for direct, bank-select and paired routes.
foreach {arrays channels mxu expected} {
    4 4 32 direct 8 8 32 direct
    8 4 32 bank_select 16 8 32 bank_select
    8 4 16 pair 16 8 16 pair
} {
    foreach spelling {slash dot mixed} {
        fixture $arrays $spelling $channels $mxu
        if {$spelling eq "slash"} {
            set renamed {}
            foreach cell $::mock_cells {
                lappend renamed [string map {].g_pair. ]/g_pair/ ].g_bank_select/ ]/g_bank_select/} $cell]
            }
            set ::mock_cells $renamed
        }
        equal [dict get [::vortex::slr::geometry] ROUTE] $expected source_route
        ::vortex::slr::inventory
        equal [dict size $::vortex::slr::owners] [llength $::mock_cells] structural_coverage
    }
}
foreach {arrays channels mxu} {8 4 32 16 8 32 8 4 16 16 8 16} {
    fixture $arrays slash $channels $mxu
    set branch [expr {$mxu == 16 ? "g_pair.u_dma_pair_adapter" : "g_bank_select"}]
    set idx [lsearch -glob $::mock_cells "*.$branch/*"]
    # Brackets in generated channel names are literal; remove by index.
    if {$idx < 0} {error "fixture missing $branch"}
    set ::mock_cells [lreplace $::mock_cells $idx $idx]
    fails {::vortex::slr::inventory} {*route indices*}
    fixture $arrays slash $channels $mxu
    set idx [lsearch -glob $::mock_cells "*.$branch/*"]
    lset ::mock_cells $idx [format {top/node/u_tmem_subsystem/g_dma_tmem_route[99].%s/state_reg} $branch]
    fails {::vortex::slr::inventory} {*route indices*}
    fixture $arrays slash $channels $mxu
    set wrong [expr {$mxu == 16 ? "g_bank_select" : "g_pair.u_dma_pair_adapter"}]
    lappend ::mock_cells [format {top/node/u_tmem_subsystem/g_dma_tmem_route[0].%s/state_reg} $wrong]
    fails {::vortex::slr::inventory} {*route indices*}
    fixture $arrays slash $channels $mxu
    lappend ::mock_cells {top/node/u_tmem_subsystem/g_dma_tmem_route[0].g_direct/state_reg}
    fails {::vortex::slr::inventory} {*unexpected direct*}
}
fixture 4
lappend ::mock_cells {top/node/u_tmem_subsystem/g_dma_tmem_route[0].g_bank_select/state_reg}
fails {::vortex::slr::inventory} {*bank_select route indices*}
# Vortex_axi also supports multiple HBM ports per DMA channel.
fixture 4
set ::env(VORTEX_GEMM_HBM_PORTS) 8
::vortex::slr::inventory
# Only known generate-boundary spelling is normalized; actual cell names,
# escaped indices, replica suffixes and arbitrary dots remain unchanged.
set actual {u_gemm_dma_transport/u_commands/g_slr.u_link/u_rx/FSM_onehot_state_q[5]_i_7}
set logical {u_gemm_dma_transport/u_commands/g_slr/u_link/u_rx/FSM_onehot_state_q[5]_i_7}
equal [::vortex::slr::logical_path $actual] $logical actual_dcp_boundary
equal [::vortex::slr::logical_path $logical] $logical canonical_idempotent
equal [::vortex::slr::owner_for $actual] 0 actual_dcp_receiver_owner
equal [::vortex::slr::matching [list $actual] {^u_gemm_dma_transport/u_commands/g_slr/u_link/u_rx/}] [list $actual] query_names_not_rewritten
equal [::vortex::slr::logical_path {x/g_slrXu_link/u_rx/a.b_reg[3]_rep__2}] {x/g_slrXu_link/u_rx/a.b_reg[3]_rep__2} unrelated_dots_preserved
foreach leaf {output_done_pending_q_reg output_write_pending_q_reg renamed_leaf_reg_rep__2} {
    set original "u_tmem_subsystem/g_output_slr_completion.$leaf"
    set expected "u_tmem_subsystem/g_output_slr_completion/$leaf"
    equal [::vortex::slr::logical_path $original] $expected output_completion_generate_boundary
    equal [::vortex::slr::logical_path $expected] $expected output_completion_idempotent
    equal [::vortex::slr::owner_for $original] 1 output_completion_source_owner
    equal [::vortex::slr::matching [list $original] {/g_output_slr_completion/}] [list $original] output_completion_original_name
}
fails {::vortex::slr::owner_for u_tmem_subsystem/g_output_slr_completion_extra.output_done_pending_q_reg} {*unclassified*}
foreach bad {
    u_gemm_dma_transport/u_commands/g_slrXu_link/u_rx/state_reg
    u_gemm_dma_transport/u_commands/g_slr.u_link/u_rx_extra/state_reg
    u_gemm_dma_transport/u_commands/g_slr.u_link/u_rx_extra/op_ready_reg
    u_gemm_dma_transport/u_commands_fake/g_slr.u_link/u_rx/state_reg
    u_gemm_dma_transport/u_link/u_rx/state_reg
} {
    fails {::vortex::slr::owner_for $bad} {*unclassified*}
}
# A report must contain every unknown original cell, and apply must stop
# before pblock creation (create_pblock is not provided in this fixture yet).
fixture 4 dot
set unknown_a {top/node/u_gemm_dma_transport/new_wrapper/unknown_reg[3]}
set unknown_b {top/node/u_tmem_subsystem/new_wrapper/unknown_reg_rep__2}
lappend ::mock_cells $unknown_a $unknown_b
fails {::vortex::slr::apply} {*classification failed (2 leaves)*}
set report [open slr_unclassified_leaves.tsv r]
set report_text [read $report]
close $report
equal [expr {[string first $unknown_a $report_text] >= 0}] 1 first_unknown_reported
equal [expr {[string first $unknown_b $report_text] >= 0}] 1 second_unknown_reported
equal [llength [split [string trim $report_text] "\n"]] 3 unknown_report_cardinality
equal [dict size $::vortex::slr::owners] 0 no_partial_inventory_accepted
foreach spelling {g_slr/u_link g_slr.u_link} {
    foreach {stream tx_owner rx_owner} {u_commands 1 0 u_completions 0 1 u_sync 0 1} {
        foreach {half expected} [list tx $tx_owner rx $rx_owner] {
            set endpoint "u_gemm_dma_transport/$stream/$spelling/u_$half"
            equal [::vortex::slr::owner_for "$endpoint/renamed_fifo/fsm_reg_rep__4"] $expected descendant_owned_by_endpoint
            set marked "top/node/$endpoint/valid_${half}_q_reg"
            equal [::vortex::slr::register_role $marked] $half transport_role
            equal [::vortex::slr::link_group $marked] "top/node/u_gemm_dma_transport/$stream/payload" transport_group
        }
        equal [::vortex::slr::anchor_barrier "u_gemm_dma_transport/$stream/$spelling"] 1 mixed_stream_barrier
        equal [::vortex::slr::anchor_barrier "u_gemm_dma_transport/$stream/$spelling/u_rx"] 0 receiver_anchor_allowed
    }
    foreach direction {request response} {
        set prefix "u_tmem_subsystem/u_weight_req_reservation/u_slr/u_$direction/$spelling"
        equal [::vortex::slr::owner_for "$prefix/u_tx/new_leaf_reg"] [expr {$direction eq "request" ? 1 : 0}] memory_source_owner
        equal [::vortex::slr::owner_for "$prefix/u_rx/new_leaf_reg"] [expr {$direction eq "request" ? 0 : 1}] memory_destination_owner
        set credit "top/node/$prefix/u_rx/credit_tx_q_reg_rep__2"
        equal [::vortex::slr::register_role $credit] tx reverse_credit_role
        equal [::vortex::slr::link_group $credit] "top/node/u_tmem_subsystem/u_weight_req_reservation/u_slr/u_$direction/credit" reverse_credit_group
    }
}
# Fail closed on missing, duplicated or inconsistent source geometry.
foreach key {TMEM_BANKS MXU_COL MXU_ROW DMA_CHANNELS HBM_PORTS HBM_DATA_BYTES} {
    fixture 4
    unset ::env(VORTEX_GEMM_$key)
    fails {::vortex::slr::inventory} {*VORTEX_GEMM_*}
    foreach invalid {{4 4} {} 0 -1 01 1+1 invalid-duplicate} {
        fixture 4
        set ::env(VORTEX_GEMM_$key) $invalid
        fails {::vortex::slr::inventory} {*VORTEX_GEMM_*}
    }
}
foreach {key value pattern} {
    DMA_CHANNELS 8 {*HBM_PORTS=4 or 8 divisible*}
    HBM_PORTS 16 {*HBM_PORTS=4 or 8*}
    MXU_COL 16 {*matching input*}
    TMEM_BANKS 6 {*power-of-two*}
    TMEM_BANKS 2 {*divisible*}
    TMEM_BANKS 16 {*unsupported SLR DMA*}
    HBM_DATA_BYTES 32 {*64-byte HBM*}
} {
    fixture 4
    set ::env(VORTEX_GEMM_$key) $value
    fails {::vortex::slr::inventory} $pattern
}
foreach {arrays channels mxu} {4 4 16 8 4 8 8 4 24 8 4 64} {
    fixture $arrays slash $channels $mxu
    fails {::vortex::slr::geometry} {*SLR*}
}
# All geometries require exact indices, not merely matching cardinality.
foreach arrays {4 8 16} {
    fixture $arrays
    set idx [lsearch -exact $::mock_cells {top/node/u_tmem_subsystem/g_bank[0].u_bank/state_reg}]
    lset ::mock_cells $idx [format {top/node/u_tmem_subsystem/g_bank[%d].u_bank/state_reg} $arrays]
    fails {::vortex::slr::inventory} {*indices*}
    fixture $arrays
    set idx [lsearch -exact $::mock_cells {top/node/u_tmem_subsystem/u_dma_engine/g_channel[0].u_dma_unit/state_reg}]
    lset ::mock_cells $idx {top/node/u_tmem_subsystem/u_dma_engine/g_channel[99].u_dma_unit/state_reg}
    fails {::vortex::slr::inventory} {*indices*}
    fixture $arrays
    lappend ::mock_cells {top/node/u_tmem_subsystem/g_dma_tmem_route[99].g_pair.u_dma_pair_adapter/state_reg}
    fails {::vortex::slr::inventory} {*pair*}
}
fixture 16
set idx [lsearch -exact $::mock_cells {top/node/u_tmem_subsystem/g_dma_tmem_route[0].g_pair.u_dma_pair_adapter/state_reg}]
lset ::mock_cells $idx {top/node/u_tmem_subsystem/g_dma_tmem_route[8].g_pair.u_dma_pair_adapter/state_reg}
fails {::vortex::slr::inventory} {*pair*}
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
equal [::vortex::slr::owner_for u_tmem_subsystem/u_output_slr/u_request/g_slr/u_link/u_tx/payload_tx_q_reg] 1 request_tx
equal [::vortex::slr::owner_for u_tmem_subsystem/u_output_slr/u_request/g_slr/u_link/u_rx/payload_rx_q_reg] 0 request_rx
equal [::vortex::slr::owner_for u_tmem_subsystem/u_input_req_reservation/u_slr/u_response/g_slr/u_link/u_tx/payload_tx_q_reg] 0 response_tx
equal [::vortex::slr::owner_for u_gemm_dma_transport/u_commands/u_launch/data_reg] 1 command_launch
equal [::vortex::slr::owner_for u_gemm_dma_transport/g_source/owned_tags_q_reg] 1 command_owner
equal [::vortex::slr::owner_for u_gemm_dma_transport/u_commands/g_slr/u_link/u_rx/pending_q_reg] 0 command_receiver
equal [::vortex::slr::owner_for u_tmem_subsystem/u_weight_req_reservation/u_slr/u_request/u_launch/data_reg] 1 request_launch
equal [::vortex::slr::owner_for u_tmem_subsystem/g_output_slr_completion/done_q_reg] 1 output_completion
equal [::vortex::slr::owner_for u_VX_gemm_unit_v2/u_compute_core/g_slr_mxu_input_rx.payload_q_reg] 2 mxu_rx
equal [::vortex::slr::owner_for u_commands/g_slr/u_link/u_rx/read_q0] 0 lifted_command_read_pointer
equal [::vortex::slr::owner_for u_commands/g_slr/u_link/u_rx/write_q0_rep__1] 0 lifted_command_write_pointer_replica
fails {::vortex::slr::owner_for u_link/u_rx/read_q0} {*lost*ownership identity*}
fails {::vortex::slr::owner_for u_gemm_dma_transport/unknown/state_reg} {*unclassified DMA-control*}
equal [::vortex::slr::register_role {top/node/u_VX_gemm_unit_v2/u_compute_core/g_slr_mxu_input_tx.data_q_reg[0]}] tx mxu_preserved_data_role
equal [::vortex::slr::register_role {top/node/u_tmem_subsystem/u_weight_req_reservation/u_slr/u_response/g_slr/u_link/u_tx/g_payload[7].payload_tx_q_reg}] tx per_bit_tx_role
equal [::vortex::slr::link_group {top/node/u_tmem_subsystem/u_weight_req_reservation/u_slr/u_response/g_slr/u_link/u_tx/g_payload[7].payload_tx_q_reg}] top/node/u_tmem_subsystem/u_weight_req_reservation/u_slr/u_response/payload per_bit_tx_group
fails {::vortex::slr::owner_for u_tmem_subsystem/new_unknown/state_reg} {*unclassified TMEM*}
fixture 8
set ::mock_cells [lrange $::mock_cells 1 end]
fails {::vortex::slr::inventory} {*missing required group*}
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

# Mixed generate spellings identify one link, while net/pin queries and
# owner lookups must still use the two different original physical names.
set tx {top/node/u_gemm_dma_transport/u_commands/g_slr.u_link/u_tx/g_payload[7].payload_tx_q_reg_rep__2}
set rx {top/node/u_gemm_dma_transport/u_commands/g_slr/u_link/u_rx/g_payload[7].payload_rx_q_reg}
set ::mock_marked [list $tx $rx]
set ::vortex::slr::owners [dict create $tx 1 $rx 0]
dict set ::mock_pins mock_net [list "$tx/Q" "$rx/D"]
::vortex::slr::validate_links 0 $report_file
set report [open $report_file r]
set contents [read $report]
close $report
equal [expr {[string first $tx $contents] >= 0}] 1 original_dot_tx_in_report
equal [expr {[string first $rx $contents] >= 0}] 1 original_slash_rx_in_report
set unrelated_tx [string map {u_commands u_completions} $tx]
set ::mock_marked [list $unrelated_tx $rx]
set ::vortex::slr::owners [dict create $unrelated_tx 1 $rx 0]
dict set ::mock_pins mock_net [list "$unrelated_tx/Q" "$rx/D"]
fails {::vortex::slr::validate_links 0 $report_file} {*unexpected TX peer*}

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
puts "PASS: SLR ownership, structural direct/bank-select/pair inventory, direct FF pairs and Laguna checks"
puts "Fixture report (temporary): $report_file"
