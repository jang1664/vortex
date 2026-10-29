# Reuse the source-backed primitive inventory and Vivado mocks. No FPGA tools.
source [file join [file dirname [info script]] .. test_slr_floorplan.tcl]
set support_checks 0
proc support_equal {actual expected label} {
    equal $actual $expected $label
    incr ::support_checks
}
proc support_fixture {spelling {enabled 1}} {
    fixture 8 mixed 4 16
    set cells {}
    foreach cell $::mock_cells {
        lappend cells [string map {top/node/ top/core/gemm_node/} $cell]
    }
    set ::mock_cells $cells
    if {$enabled} {lappend ::mock_cells top/core/gemm_node/u_sram_dma/state_reg}
    # Use the same mandatory C4 primitive identities as test_r8_floorplan.tcl.
    # Feature-off retains its previous cell set; these primitives are added only
    # with the fusion marker and remain separate from the 25 support roots.
    set ::support_metadata {};set ::support_rams {}
    for {set bank 0} {$bank < 16} {incr bank} {
        foreach bit {-1 0 1 2 3 4 5 6 7 8 9 10 11 12} {
            set tail [expr {$bit == -1 ? "last_wr_valid_reg" : [format {last_wr_addr_reg[%d]} $bit]}]
            set cell [format {top/core/mem_unit/local_mem/g_data_store[%d].%s} $bank $tail]
            lappend ::support_metadata $cell
            if {$enabled} {lappend ::mock_cells $cell;dict set ::mock_refs $cell FDRE}
        }
        for {set lane 0} {$lane < 8} {incr lane} {
            for {set depth 0} {$depth < 2} {incr depth} {
                set cell [format {top/core/mem_unit/local_mem/g_data_store[%d].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_%d_bram_%d} $bank $lane $depth]
                lappend ::support_rams $cell
                if {$enabled} {lappend ::mock_cells $cell;dict set ::mock_refs $cell RAMB36E2}
            }
        }
    }
    set ::expected_support {}
    foreach {root endpoint} {
        mem_unit/lmem_adapter lmem_adapter
        {mem_unit/g_lmem_lane_dma_arb[0]/lmem_membus_dma_arbiter} lmem_lane0
        {mem_unit/local_mem/g_rsp_hier_valid/rsp_xbar/g_multi_inputs/g_multiple_outputs/g_xbar_arbs[0]/xbar_arb} lmem_response_port0
    } {
        dict set ::expected_support $root [list 1 existing_shared $endpoint]
    }
    for {set bank 0} {$bank < 16} {incr bank} {
        set root [format {mem_unit/local_mem/g_req_hier_valid/req_xbar/g_multi_inputs/g_multiple_outputs/g_xbar_arbs[%d]/xbar_arb/g_input_select/g_fanout/fanout_join_arb} $bank]
        dict set ::expected_support $root {1 existing_shared lmem_bank_join}
    }
    foreach master {0 1} {
        foreach stream {gemm dma} {
            set root [format {mem_unit/g_lmem_switches[%d]/lmem_switch/req_%s_buf} $master $stream]
            dict set ::expected_support $root {0 existing_shared mmio_source_buffer}
        }
    }
    dict set ::expected_support mem_unit/u_fusion_publication_observer {0 feature publication_observer}
    dict set ::expected_support mem_unit/local_mem/u_fusion_commit_return {mixed feature commit_return}
    set actual {}
    dict for {root spec} $::expected_support {
        if {$spelling eq "dot"} {
            set root [string map {
                {g_lmem_lane_dma_arb[0]/} {g_lmem_lane_dma_arb[0].}
                g_rsp_hier_valid/ g_rsp_hier_valid. g_req_hier_valid/ g_req_hier_valid.
                g_multi_inputs/ g_multi_inputs. g_multiple_outputs/ g_multiple_outputs.
                g_input_select/ g_input_select. g_fanout/ g_fanout.
                g_arbiter/ g_arbiter. {g_out_buf[0]/} {g_out_buf[0].}
            } $root]
            regsub -all {(g_xbar_arbs\[[0-9]+\]|g_lmem_switches\[[0-9]+\])/} $root {\1.} root
        }
        dict set actual "top/core/$root" $spec
        if {[lindex $spec 2] eq "commit_return"} {
            # RX first exercises mixed-owner aggregation in either order.
            foreach leaf {count_rx_q_reg[0] count_tx_q_reg[0] event_decode} {
                lappend ::mock_cells "top/core/$root/$leaf"
            }
        } else {
            foreach leaf {state_reg payload_reg} {lappend ::mock_cells "top/core/$root/$leaf"}
        }
    }
    set ::expected_support $actual
    set ::excluded {
        top/core/mem_unit/lmem_adapter_extra/state_reg
        top/core/mem_unit/g_lmem_lane_dma_arb[1].lmem_membus_dma_arbiter/state_reg
        top/core/mem_unit/local_mem/g_rsp_hier_valid.rsp_xbar/g_multi_inputs.g_multiple_outputs.g_xbar_arbs[1].xbar_arb/state_reg
        top/core/mem_unit/g_lmem_switches[0].lmem_switch/req_lmem_buf/state_reg
        top/core/mem_unit/local_mem/lmem_arb/state_reg
        top/other_core/mem_unit/lmem_adapter/state_reg
    }
    lappend ::mock_cells {*}$::excluded
}
foreach spelling {slash dot} {
    support_fixture $spelling
    ::vortex::slr::inventory
    support_equal [dict size $::vortex::slr::fusion_support_roots] 25 complete_exact_support_roots
    support_equal [dict size $::vortex::slr::fusion_metadata] 224 mandatory_metadata_count
    support_equal [dict size $::vortex::slr::fusion_rams] 256 mandatory_RAM_count
    foreach cell [concat $::support_metadata $::support_rams] {
        support_equal [dict get $::vortex::slr::owners $cell] 1 mandatory_storage_owner
    }
    dict for {root spec} $::expected_support {
        set metadata [dict get $::vortex::slr::fusion_support_roots $root]
        foreach field {owner kind endpoint} value $spec {
            support_equal [dict get $metadata $field] $value "retained root $field"
        }
        foreach cell $::mock_cells {
            if {[string first "$root/" $cell] != 0} {continue}
            set expected [lindex $spec 0]
            if {$expected eq "mixed"} {
                set expected [expr {[string match count_rx* [file tail $cell]] ? 0 : 1}]
            }
            support_equal [dict get $::vortex::slr::owners $cell] $expected full_island_leaf_coverage
        }
    }
    foreach cell $::excluded {
        support_equal [dict exists $::vortex::slr::owners $cell] 0 unrelated_leaf_unowned
    }
    set report [open slr_fusion_support_roots.tsv r]
    set rows [split [string trim [read $report]] \n]
    close $report
    support_equal [lindex $rows 0] "root\towner\tkind\tendpoint" support_report_schema
    support_equal [expr {[llength $rows]-1}] 25 support_report_coverage
    foreach row [lrange $rows 1 end] {
        lassign [split $row \t] root owner kind endpoint
        support_equal [list $owner $kind $endpoint] [dict get $::expected_support $root] report_preserves_scope_identity
    }
    # No feature marker means no support takeover, even with matching names.
    support_fixture $spelling 0
    ::vortex::slr::inventory
    support_equal [dict size $::vortex::slr::fusion_support_roots] 0 feature_off_has_no_support_roots
    support_equal [dict size $::vortex::slr::fusion_metadata] 0 feature_off_has_no_metadata
    support_equal [dict size $::vortex::slr::fusion_rams] 0 feature_off_has_no_RAM
    foreach cell [concat $::support_metadata $::support_rams] {
        support_equal [dict exists $::vortex::slr::owners $cell] 0 feature_off_storage_unowned
    }
    dict for {root spec} $::expected_support {
        foreach cell $::mock_cells {
            if {[string first "$root/" $cell] == 0} {
                support_equal [dict exists $::vortex::slr::owners $cell] 0 feature_off_leaf_unchanged
            }
        }
    }
}
# Lifted publication arithmetic must fail instead of silently moving with a
# consumer buffer. This includes the bank-zero carry-chain observed in R5.
support_fixture slash
set escaped {top/core/mem_unit/local_mem/g_req_hier_valid/req_xbar/g_multi_inputs/g_multiple_outputs/g_xbar_arbs[0]/xbar_arb/g_input_select/g_fanout/fanout_join_arb/g_input_select/g_arbiter/g_out_buf[0]/out_buf/fusion_pending_stores_q_reg[7]_i_1}
lappend ::mock_cells $escaped
dict set ::mock_refs $escaped CARRY8
fails {::vortex::slr::inventory} {*publication arithmetic escaped*}
incr support_checks
puts "PASS: $support_checks exact fusion support inventory checks"
