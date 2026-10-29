# Fixture-only complete C4 endpoint inventory, independent of production
# fusion_lmem_stream_specs. Returns {retained_cell intended_owner} dictionary.
# Real Q-to-D topology/placement remains covered by the unchanged native checks.
proc r8_fixture_endpoints {core} {
    set endpoints {}
    foreach {stream tx_owner rx_owner} {request 0 1 response 1 0} {
        foreach half {tx rx} owner [list $tx_owner $rx_owner] {
            set reverse [expr {$half eq "tx" ? "rx" : "tx"}]
            set prefix "$core/mem_unit/u_fusion_lmem_vector/u_${stream}_${half}"
            foreach signal [list payload_${half} valid_${half} credit_${reverse}] {
                dict set endpoints "$prefix/${signal}_q_reg" $owner
            }
        }
    }
    for {set lane 8} {$lane < 16} {incr lane} {
        set root [format {%s/mem_unit/g_lmem_lane_dma_arb[%d]/lmem_membus_dma_arbiter/g_req_data_in[0]/g_fusion_lane_request} $core $lane]
        foreach half {tx rx} owner {1 2} {
            set reverse [expr {$half eq "tx" ? "rx" : "tx"}]
            foreach signal [list payload_${half} valid_${half} credit_${reverse}] {
                dict set endpoints "$root/u_$half/${signal}_q_reg" $owner
            }
        }
    }
    for {set bank 0} {$bank < 16} {incr bank} {
        set root [format {%s/mem_unit/local_mem/g_req_hier_valid/req_xbar/g_multi_inputs/g_multiple_outputs/g_xbar_arbs[%d]/xbar_arb/g_input_select/g_fanout/g_slice_arbs[1]/g_fusion_bank_link/u_transport} $core $bank]
        foreach half {tx rx} owner {2 1} {
            set reverse [expr {$half eq "tx" ? "rx" : "tx"}]
            foreach signal [list payload_${half} valid_${half} credit_${reverse}] {
                dict set endpoints "$root/u_$half/${signal}_q_reg" $owner
            }
        }
    }
    return $endpoints
}
