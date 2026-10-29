source [file join [file dirname [info script]] test_fusion_support_inventory.tcl]
# Pin topology is checked in test_fusion_dma_launch_owner. This fixture checks
# that inventory invokes it only for an actual fusion root, never base improve.
rename ::vortex::slr::recover_fusion_dma_launch_owner ::vortex::slr::real_dma_recovery
proc ::vortex::slr::recover_fusion_dma_launch_owner {leaf root ref} {
    incr ::recovery_calls
    return [dict create owner 1 extra_cells {} endpoint "$root/u_gemm_dma_transport/u_commands/u_launch/state_reg/D" input_pin source/Q output_pin "$leaf/O"]
}
foreach enabled {0 1} {
    support_fixture slash $enabled
    set ::recovery_calls 0
    set leaf top/core/gemm_node/u_gemm_dma_transport/arbitrary_lifted_helper
    lappend ::mock_cells $leaf
    dict set ::mock_refs $leaf LUT4
    if {$enabled} {
        ::vortex::slr::inventory
        support_equal $::recovery_calls 1 actual_fusion_root_invokes_recovery
        support_equal [dict get $::vortex::slr::owners $leaf] 1 recovered_owner
        support_equal [expr {$leaf in $::vortex::slr::recovered_lut_names}] 1 explicit_recovery_receipt
    } else {
        fails {::vortex::slr::inventory} {*unclassified DMA-control transport leaf*}
        support_equal $::recovery_calls 0 feature_off_does_not_invoke_recovery
    }
}
puts "PASS: $support_checks support and feature-gated DMA inventory checks"
