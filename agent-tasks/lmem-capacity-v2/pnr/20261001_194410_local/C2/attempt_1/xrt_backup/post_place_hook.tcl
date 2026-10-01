# Post place_design hook.
# Generates a deterministic congestion report and stops before routing when
# placer-final Global/Short congestion reaches the fixed fail-fast threshold.

set vortex_congestion_hook_dir [file dirname [file normalize [info script]]]
set ::vortex_slr_definitions_only 1
source [file join $vortex_congestion_hook_dir floorplan.tcl]
unset ::vortex_slr_definitions_only
source [file join $vortex_congestion_hook_dir slr_floorplan_report.tcl]
if {[catch {::vortex::slr::post_place} vortex_slr_error vortex_slr_options]} {
    # VPL normally saves its placed checkpoint after this hook. Preserve a
    # failed validation's placed design for read-only diagnosis without ever
    # converting that failure into permission to route or retry a DCP.
    puts stderr "ERROR: SLR post_place validation failed: [string range $vortex_slr_error 0 2047]"
    set vortex_slr_snapshot [file normalize post_place_slr_failed.dcp]
    set vortex_slr_snapshot_index 0
    while {[file exists $vortex_slr_snapshot]} {
        incr vortex_slr_snapshot_index
        set vortex_slr_snapshot [file normalize "post_place_slr_failed_${vortex_slr_snapshot_index}.dcp"]
    }
    if {[catch {write_checkpoint $vortex_slr_snapshot} vortex_slr_snapshot_error]} {
        puts stderr "WARNING: failed to save SLR diagnostic checkpoint '$vortex_slr_snapshot': [string range $vortex_slr_snapshot_error 0 2047]"
    } else {
        puts stderr "INFO: SLR diagnostic placed checkpoint: $vortex_slr_snapshot"
    }
    return -options $vortex_slr_options $vortex_slr_error
}
set vortex_congestion_enabled 1
if {[info exists ::env(VORTEX_CONGESTION_FAIL_FAST)]} {
    set vortex_congestion_enabled $::env(VORTEX_CONGESTION_FAIL_FAST)
}
if {$vortex_congestion_enabled ni {0 1}} {
    error "VORTEX_CONGESTION_FAIL_FAST must be 0 or 1"
}
if {!$vortex_congestion_enabled} {
    puts "INFO: congestion fail-fast disabled; independent SLR checks completed"
    return [dict create decision disabled]
}
source [file join $vortex_congestion_hook_dir congestion_fail_fast.tcl]

set vortex_congestion_implementation_dir [file normalize [pwd]]
set vortex_congestion_result \
    [::vortex::congestion_fail_fast::run_post_place_gate \
        [file join $vortex_congestion_implementation_dir \
            post_place_congestion.rpt] \
        [file join $vortex_congestion_implementation_dir \
            post_place_fail_fast.dcp]]
unset vortex_congestion_hook_dir
unset vortex_congestion_implementation_dir
set vortex_congestion_result
