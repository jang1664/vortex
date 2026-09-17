set_param general.maxThreads 8
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
report_timing_summary -delay_type min_max -max_paths 10 -file ${out}/final_timing.rpt
report_utilization -file ${out}/final_utilization.rpt
report_utilization -hierarchical -file ${out}/final_hierarchy.rpt
report_clock_utilization -file ${out}/final_clocks.rpt
set kregs [get_cells -hier -regexp {.*gemm_node_naive/control/fsm/job_q_reg\[k\]\[[0-9]+\]$}]
set eventregs [get_cells -hier -regexp {.*gemm_node_naive/control/source_join/(closed_.*_q_reg|read_done_.*_q_reg).*}]
set owners [get_cells -hier -regexp {.*gemm_node_naive/control/source_join/owner_q_reg.*}]
puts "ANALYSIS_MATCHES k=[llength $kregs] events=[llength $eventregs] owners=[llength $owners]"
if {[llength $kregs] && [llength $eventregs]} {
    report_timing -from $kregs -to $eventregs -max_paths 10 -nworst 1 -path_type full_clock_expanded -input_pins -nets -file ${out}/k_to_event_ff.rpt
}
if {[llength $eventregs] && [llength $owners]} {
    report_timing -from $eventregs -to $owners -max_paths 10 -nworst 1 -path_type full_clock_expanded -input_pins -nets -file ${out}/event_ff_to_owner.rpt
}
report_timing -group clk_kernel_00_unbuffered_net -max_paths 20 -nworst 1 -path_type full_clock_expanded -input_pins -nets -file ${out}/worst_kernel_paths.rpt
set paths [get_timing_paths -group clk_kernel_00_unbuffered_net -max_paths 10000 -nworst 1 -slack_lesser_than 0]
set fh [open ${out}/violations.tsv w]
puts $fh "slack\tstart\tend\tdelay\tlevels"
foreach p $paths {
    puts $fh "[get_property SLACK $p]\t[get_property STARTPOINT_PIN $p]\t[get_property ENDPOINT_PIN $p]\t[get_property DATAPATH_DELAY $p]\t[get_property LOGIC_LEVELS $p]"
}
close $fh
puts "ANALYSIS_VIOLATIONS [llength $paths]"
close_design
exit
