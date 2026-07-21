# Post place_design hook.
# Generates a deterministic congestion report and stops before routing when
# placer-final Global/Short congestion reaches the fixed fail-fast threshold.

set vortex_congestion_hook_dir [file dirname [file normalize [info script]]]
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
