# Naive placement profile. Shared inventory, pblock, and FF checks live in
# floorplan.tcl; this file only defines the naive architectural ownership.
proc ::vortex::slr::naive_geometry {} {
    set result [dict create]
    foreach field {MXU_ROW MXU_COL MXU_COL_TILE LMEM_PORTS LMEM_BANKS LMEM_LOG_SIZE LSU_BLOCKS} {
        set key VORTEX_GEMM_$field
        if {![info exists ::env($key)] || ![regexp {^[1-9][0-9]*$} $::env($key)]} {
            error "naive SLR floorplan requires one positive source $key integer"
        }
        dict set result $field $::env($key)
    }
    set row [dict get $result MXU_ROW]
    set col [dict get $result MXU_COL]
    set lanes [dict get $result LMEM_PORTS]
    if {$row ni {16 32} || $row != $col || $col != [dict get $result MXU_COL_TILE]} {
        error "naive SLR requires square MXU16/MXU32 with one column tile"
    }
    if {$lanes != [dict get $result LMEM_BANKS] || !($lanes == $col || ($col == 16 && $lanes == 32))} {
        error "naive SLR requires LMEM ports == banks, with MXU-matched lanes or MXU16/LMEM32"
    }
    puts "INFO: naive SLR source geometry: $result"
    return $result
}

proc ::vortex::slr::naive_owner_for {path} {
    set path [logical_path $path]
    if {[string match {u_VX_dma_node/*} $path]} {return 0}
    if {[string match {mem_unit/*} $path]} {return 1}
    if {[string match {gemm_node_naive/*} $path]} {
        if {[string match {gemm_node_naive/u_VX_gemm_compute_core/u_mxu/*} $path]
            || [regexp {/g_slr_mxu_(input_rx|weight_rx|output_tx)[/.]} $path]} {return 2}
        return 1
    }
    if {[string match {u_naive_dma_slr/*} $path]} {
        if {[regexp {/(g_commit|g_perf)[/.]g_slr([01])[/.]} $path -> group slr]} {return $slr}
        if {[regexp {/g_commit[/.]g_bank\[} $path]} {return 1}
        if {[regexp {/g_mmio\[[0-9]+\][/.]u_(request|response)/g_slr/u_link/u_(tx|rx)/} $path -> direction half]} {
            return [expr {($direction eq "request") == ($half eq "tx") ? 1 : 0}]
        }
        if {[regexp {/(?:g_lmem\[[0-9]+\][/.]u_transport|u_global)/u_(request|response)/g_slr/u_link/u_(tx|rx)/} $path -> direction half]} {
            return [expr {($direction eq "request") == ($half eq "tx") ? 0 : 1}]
        }
        # Only named source-local completion reductions may survive outside
        # the transport endpoints. Never guess a lost endpoint's ownership.
        if {[regexp {^u_naive_dma_slr/(requests_drained|lmem_idle|lmem_offer|global_idle)[^/]*$} $path]} {return 0}
        error "unclassified naive DMA transport leaf: $path"
    }
    if {[regexp {^(u_link|g_slr[/.]|u_request/|u_response/)} $path]} {
        error "naive SLR link lost architectural ownership identity: $path"
    }
    # Other CPU/core logic remains unconstrained. Empty is not an SLR owner.
    return {}
}

# Required groups need one witness, not a materialized list of every matching
# leaf. The caller normalizes paths once before these native Tcl searches.
proc ::vortex::slr::naive_need_match {local expression label} {
    if {[lsearch -regexp $local $expression] < 0} {need {} $label}
}

proc ::vortex::slr::naive_require_groups {local geometry marked} {
    set normalized {}
    foreach path $local {lappend normalized [logical_path $path]}
    set local $normalized
    unset normalized
    if {!$marked} {
        foreach hierarchy {u_VX_dma_node mem_unit/local_mem gemm_node_naive/u_VX_gemm_compute_core/u_mxu} {
            naive_need_match $local "^$hierarchy/" "naive $hierarchy"
        }
        set acc_mem 0
        if {[info exists ::env(VORTEX_GEMM_NAIVE_USE_ACC_MEM)]} {
            set acc_mem $::env(VORTEX_GEMM_NAIVE_USE_ACC_MEM)
        }
        if {$acc_mem ni {0 1}} {error "VORTEX_GEMM_NAIVE_USE_ACC_MEM must be 0 or 1"}
        set accumulator [expr {$acc_mem ? "u_acc_internal" : "u_VX_gemm_acc_lmem"}]
        naive_need_match $local "^gemm_node_naive/$accumulator/" "naive gemm_node_naive/$accumulator"
        naive_need_match $local {/g_slr_mxu_local_ownership[/.]} "naive MXU local ownership"
    }
    foreach group {input_tx input_rx weight_tx weight_rx output_tx output_rx} {
        naive_need_match $local [format {^gemm_node_naive/u_VX_gemm_compute_core/g_slr_mxu_%s[/.]} $group] "naive MXU $group"
    }
    foreach half {tx rx} {
        naive_need_match $local [format {/g_slr_mxu_input_%s[/.]data_q_reg} $half] "naive MXU input data $half"
    }
    set lanes [dict get $geometry LMEM_PORTS]
    set masters [expr {[dict get $geometry LSU_BLOCKS] + 1}]
    set prefixes {^u_naive_dma_slr/u_global}
    for {set i 0} {$i < $lanes} {incr i} {
        lappend prefixes [format {^u_naive_dma_slr/g_lmem\[%d\][/.]u_transport} $i]
    }
    for {set i 0} {$i < $masters} {incr i} {
        lappend prefixes [format {^u_naive_dma_slr/g_mmio\[%d\]} $i]
    }
    foreach prefix $prefixes {
        foreach direction {request response} {
            foreach half {tx rx} {
                naive_need_match $local [format {%s[/.]u_%s/g_slr/u_link/u_%s/} $prefix $direction $half] "naive $prefix $direction $half"
            }
        }
    }
    foreach {slr half} {1 tx 0 rx} {
        naive_need_match $local [format {^u_naive_dma_slr/g_commit[/.]g_slr%s[/.]payload_%s_q_reg} $slr $half] "naive commit $half"
    }
    # PERF is optional; a partially surviving snapshot still needs both ends.
    if {[lsearch -regexp $local {^u_naive_dma_slr/g_perf[/.]}] >= 0} {
        foreach {slr half} {0 tx 1 rx} {
            naive_need_match $local [format {^u_naive_dma_slr/g_perf[/.]g_slr%s[/.]payload_%s_q_reg} $slr $half] "naive perf $half"
        }
    }
}

proc ::vortex::slr::naive_anchor_barrier {relative} {
    if {$relative in {{} gemm_node_naive gemm_node_naive/u_VX_gemm_compute_core u_naive_dma_slr}} {return 1}
    return [regexp {^u_naive_dma_slr/(g_mmio\[[0-9]+\]|g_lmem\[[0-9]+\]([/.]u_transport)?|u_global|g_commit|g_perf)$} $relative]
}

proc ::vortex::slr::naive_boundary {relative} {
    return [regexp {^(mem_unit|u_VX_dma_node|gemm_node_naive|gemm_node_naive/u_VX_gemm_compute_core/u_mxu|u_naive_dma_slr|u_naive_dma_slr/u_global|u_naive_dma_slr/g_lmem\[[0-9]+\][/.]u_transport|u_naive_dma_slr/g_mmio\[[0-9]+\][/.]u_(request|response))$} $relative]
}

proc ::vortex::slr::naive_validate_fp_coverage {coverage} {
    variable owners; variable primitive_names; variable primitive_refs
    array set owner_map $owners
    foreach cell $primitive_names ref $primitive_refs {
        if {![info exists owner_map($cell)] || ![string match FD* $ref]
            || ![regexp {/gemm_node_naive/u_VX_gemm_compute_core/.*xil_f(?:16|32)(?:add|mul)_inst/.*/HAS_ARESETN[.]sclr_i_reg$} $cell]} {continue}
        if {$owner_map($cell) != 1 || ![dict exists $coverage $cell]} {
            error "naive local FP reset lacks SLR1 hierarchy coverage: $cell"
        }
    }
}
