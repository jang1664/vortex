# Reuse the established Vivado mock API and run its improve regressions first.
source [file join [file dirname [info script]] .. test_slr_floorplan.tcl]
set ::env(VORTEX_GEMM_BACKEND) naive
set ::env(VORTEX_GEMM_NAIVE_USE_ACC_MEM) 0
foreach {field value} {MXU_ROW 16 MXU_COL 16 MXU_COL_TILE 16 LMEM_PORTS 16 LMEM_BANKS 16 LMEM_LOG_SIZE 20 LSU_BLOCKS 1} {
    set ::env(VORTEX_GEMM_$field) $value
}
proc naive_fixture {} {
    set local {}
    foreach hierarchy {u_VX_dma_node mem_unit/local_mem gemm_node_naive/u_VX_gemm_compute_core/u_mxu gemm_node_naive/u_VX_gemm_acc_lmem} {
        lappend local "$hierarchy/state_reg"
    }
    foreach group {input_tx input_rx weight_tx weight_rx output_tx output_rx local_ownership} {
        lappend local "gemm_node_naive/u_VX_gemm_compute_core/g_slr_mxu_$group.payload_q_reg"
    }
    foreach half {tx rx} {
        lappend local "gemm_node_naive/u_VX_gemm_compute_core/g_slr_mxu_input_$half.data_q_reg"
    }
    set prefixes {u_naive_dma_slr/u_global}
    for {set i 0} {$i < $::env(VORTEX_GEMM_LMEM_PORTS)} {incr i} {lappend prefixes [format {u_naive_dma_slr/g_lmem[%d].u_transport} $i]}
    for {set i 0} {$i < 2} {incr i} {lappend prefixes [format {u_naive_dma_slr/g_mmio[%d]} $i]}
    foreach prefix $prefixes {
        foreach direction {request response} {
            foreach half {tx rx} {lappend local "$prefix/u_$direction/g_slr/u_link/u_$half/payload_${half}_q_reg"}
        }
    }
    foreach {slr half} {1 tx 0 rx} {lappend local "u_naive_dma_slr/g_commit/g_slr$slr.payload_${half}_q_reg"}
    set result {}
    foreach name $local {lappend result "top/core/$name"}
    # Explicitly unassigned core logic must not enter the SLR1 fallback.
    lappend result top/core/execute/state_reg
    return $result
}
equal [::vortex::slr::link_group {top/core/u_naive_dma_slr/g_mmio[0].u_request/g_slr.u_link/u_tx/payload_tx_q_reg}] {top/core/u_naive_dma_slr/g_mmio[0]/u_request/payload} naive_mmio_dot_link_group
set ::mock_cells [naive_fixture]
set complete $::mock_cells
set ::mock_marked $complete
::vortex::slr::inventory
equal [dict size $::vortex::slr::owners] [expr {[llength $complete]-1}] naive_owned_coverage
equal [dict exists $::vortex::slr::owners top/core/execute/state_reg] 0 unassigned_core
::vortex::slr::require_marked_groups
set ::env(VORTEX_GEMM_NAIVE_USE_ACC_MEM) 1
fails {::vortex::slr::inventory} {*naive gemm_node_naive/u_acc_internal*}
set ::mock_cells [string map {u_VX_gemm_acc_lmem u_acc_internal} $complete]
set ::mock_marked $::mock_cells
::vortex::slr::inventory
::vortex::slr::require_marked_groups
equal [dict get $::vortex::slr::owners top/core/gemm_node_naive/u_acc_internal/state_reg] 1 acc_internal_slr1
set ::env(VORTEX_GEMM_NAIVE_USE_ACC_MEM) 0
fails {::vortex::slr::inventory} {*naive gemm_node_naive/u_VX_gemm_acc_lmem*}
set ::mock_cells $complete
set ::mock_marked $complete
::vortex::slr::inventory
foreach {path expected} {
    u_VX_dma_node/u_job_frontend/state_reg 0
    mem_unit/local_mem/bank/ram_reg 1
    gemm_node_naive/u_VX_gemm_compute_core/u_mxu/pe/reg 2
    gemm_node_naive/u_VX_gemm_compute_core/g_slr_mxu_input_tx.data_q_reg 1
    gemm_node_naive/u_VX_gemm_compute_core/g_slr_mxu_input_rx.data_q_reg 2
    gemm_node_naive/u_VX_gemm_compute_core/g_slr_mxu_output_tx.payload_q_reg 2
    gemm_node_naive/u_VX_gemm_compute_core/g_slr_mxu_output_rx.payload_q_reg 1
    u_naive_dma_slr/g_mmio[0].u_request/g_slr.u_link/u_tx/payload_tx_q_reg 1
    u_naive_dma_slr/g_mmio[0]/u_request/g_slr/u_link/u_rx/payload_rx_q_reg 0
    u_naive_dma_slr/g_lmem[15].u_transport/u_response/g_slr/u_link/u_tx/payload_tx_q_reg 1
    u_naive_dma_slr/u_global/u_request/g_slr/u_link/u_tx/payload_tx_q_reg 0
    u_naive_dma_slr/u_global/u_response/g_slr/u_link/u_rx/payload_rx_q_reg 0
    u_naive_dma_slr/g_commit/g_bank[0].decoded_i_1 1
    u_naive_dma_slr/g_commit/g_slr0.payload_rx_q_reg 0
    u_naive_dma_slr/g_perf/g_slr1.payload_rx_q_reg 1
    u_naive_dma_slr/requests_drained_INST_0 0
} {equal [::vortex::slr::owner_for $path] $expected "naive owner $path"}
fails {::vortex::slr::owner_for u_naive_dma_slr/u_link/unknown_reg} {*unclassified naive*}
fails {::vortex::slr::owner_for g_slr/u_link/u_rx/unknown_reg} {*lost architectural*}
set ::mock_cells [lsearch -all -inline -not -glob $complete *g_commit/g_slr0*]
fails {::vortex::slr::inventory} {*naive commit rx*}
set ::mock_cells [lsearch -all -inline -not -glob $complete *mem_unit/local_mem*]
fails {::vortex::slr::inventory} {*naive mem_unit/local_mem*}
set ::mock_cells [lsearch -all -inline -not -glob $complete *g_slr_mxu_input_rx.data*]
fails {::vortex::slr::inventory} {*naive MXU input data rx*}
set ::env(VORTEX_GEMM_LMEM_BANKS) 8
fails {::vortex::slr::geometry} {*ports == banks*}
set ::env(VORTEX_GEMM_LMEM_BANKS) 16
set ::env(VORTEX_GEMM_LMEM_PORTS) 32
fails {::vortex::slr::geometry} {*ports == banks*}
set ::env(VORTEX_GEMM_LMEM_BANKS) 32
set ::mock_cells [naive_fixture]
set ::mock_marked $::mock_cells
::vortex::slr::inventory
::vortex::slr::require_marked_groups
set ::mock_cells [lsearch -all -inline -not -glob $::mock_cells {*g_lmem\[31\]*}]
fails {::vortex::slr::inventory} {*g_lmem*31*}
set ::env(VORTEX_GEMM_LMEM_PORTS) 16
set ::env(VORTEX_GEMM_LMEM_BANKS) 16
set ::mock_cells $complete
set ::mock_marked $complete
set ::env(VORTEX_GEMM_MXU_COL_TILE) 8
fails {::vortex::slr::geometry} {*one column tile*}
set ::env(VORTEX_GEMM_MXU_COL_TILE) 16
set ::env(VORTEX_GEMM_LSU_BLOCKS) {1 1}
fails {::vortex::slr::geometry} {*one positive source*}
set ::env(VORTEX_GEMM_LSU_BLOCKS) 1
set ::env(VORTEX_GEMM_BACKEND) invalid
fails {::vortex::slr::backend} {*invalid VORTEX_GEMM_BACKEND*}
set ::env(VORTEX_GEMM_BACKEND) naive
foreach {group source destination} {g_commit 1 0 g_perf 0 1} {
    set tx top/core/u_naive_dma_slr/$group/g_slr$source.payload_tx_q_reg
    set rx top/core/u_naive_dma_slr/$group/g_slr$destination.payload_rx_q_reg
    set ::mock_marked [list $tx $rx]
    set ::vortex::slr::owners [dict create $tx $source $rx $destination]
    dict set ::mock_pins mock_net [list "$tx/Q" "$rx/D"]
    dict set ::mock_locations $tx SLICE_X0Y0
    dict set ::mock_locations $rx SLICE_X0Y1
    dict set ::mock_bels $tx AFF
    dict set ::mock_bels $rx AFF
    dict set ::mock_slrs $tx SLR$source
    dict set ::mock_slrs $rx SLR$destination
    ::vortex::slr::validate_links 0 $report_file
    ::vortex::slr::validate_links 1 $report_file
    dict set ::mock_slrs $rx SLR$source
    fails {::vortex::slr::validate_links 1 $report_file} {*actual SLRs*disagree with ownership*}
    dict set ::mock_pins mock_net [list top/unmarked_lut/O "$rx/D"]
    fails {::vortex::slr::validate_links 0 $report_file} {*direct driver*}
}
# Presence validation normalizes each input exactly once, even though this
# profile has more than ninety required groups. Dot-form MMIO/link scopes
# retain the same presence contract as slash-form scopes.
set presence_local {}
foreach path [naive_fixture] {
    set path [string range $path [string length top/core/] end]
    regsub -all {(g_mmio\[[0-9]+\])/u_} $path {\1.u_} path
    set path [string map {g_slr/u_link g_slr.u_link} $path]
    lappend presence_local $path
}
set presence_geometry [::vortex::slr::geometry]
rename ::vortex::slr::logical_path ::vortex::slr::presence_original_logical_path
set ::presence_normalizations 0
proc ::vortex::slr::logical_path {path} {
    incr ::presence_normalizations
    return [presence_original_logical_path $path]
}
::vortex::slr::naive_require_groups $presence_local $presence_geometry 0
equal $::presence_normalizations [llength $presence_local] naive_normalize_once
rename ::vortex::slr::logical_path {}
rename ::vortex::slr::presence_original_logical_path ::vortex::slr::logical_path
set perf_tx u_naive_dma_slr/g_perf.g_slr0.payload_tx_q_reg
set perf_rx u_naive_dma_slr/g_perf.g_slr1.payload_rx_q_reg
::vortex::slr::naive_require_groups [concat $presence_local [list $perf_tx $perf_rx]] $presence_geometry 0
fails {::vortex::slr::naive_require_groups [concat $presence_local [list $perf_tx]] $presence_geometry 0} {*naive perf rx*}
set missing_lane [lsearch -all -inline -not -regexp $presence_local {g_lmem\[15\].*u_response.*u_rx/}]
fails {::vortex::slr::naive_require_groups $missing_lane $presence_geometry 0} {*response rx*}
puts "PASS: naive ownership, required endpoints, unassigned CPU, and geometry checks"
