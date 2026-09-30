# Read-only full-kernel placed-DCP validation; never runs place/route or saves DCP.
if {[catch {
    lassign $argv checkpoint reports source_file
    file mkdir $reports
    cd $reports
    open_checkpoint $checkpoint
    source $source_file
    set ::env(VORTEX_GEMM_MXU_SLR_FLOORPLAN) 1
    ::vortex::mxu_slr::inventory
    ::vortex::mxu_slr::check_membership 1
    ::vortex::mxu_slr::check_links 1 post_place_mxu_slr_links.tsv
    ::vortex::mxu_slr::check_tree_ports post_place_mxu_slr_boundary_nets.tsv
    puts "PLACED_DCP_CHECK: PASS (SLR membership, FF links and boundary nets; congestion/timing not checked)"
    close_design
} message options]} {
    puts stderr "PLACED_DCP_CHECK: FAIL $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
