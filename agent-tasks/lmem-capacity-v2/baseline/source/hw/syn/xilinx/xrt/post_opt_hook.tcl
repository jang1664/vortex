# Refresh optimizer-created primitive ownership before normal place_design.
# This hook neither launches implementation nor retries a checkpoint.
set ::vortex_slr_definitions_only 1
source [file join [file dirname [file normalize [info script]]] floorplan.tcl]
unset ::vortex_slr_definitions_only
if {[catch {::vortex::slr::refresh_post_opt} vortex_slr_error vortex_slr_options]} {
    puts stderr "ERROR: SLR post_opt ownership hook failed: $vortex_slr_error"
    if {[dict exists $vortex_slr_options -errorinfo]} {
        puts stderr [dict get $vortex_slr_options -errorinfo]
    }
    return -options $vortex_slr_options $vortex_slr_error
}
