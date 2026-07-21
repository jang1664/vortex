# Query the four selected performance-monitor endpoint groups in an existing
# Vivado checkpoint. This script is read-only and never runs implementation.

if {$argc < 1 || $argc > 2} {
    puts stderr "usage: vivado -mode batch -source query_perf_paths.tcl -tclargs <checkpoint.dcp> ?output_dir?"
    exit 2
}

set checkpoint [lindex $argv 0]
set output_dir [expr {$argc == 2 ? [lindex $argv 1] : "perf_path_reports"}]

file mkdir $output_dir
open_checkpoint $checkpoint

proc query_endpoint_group {name pin_regex output_dir} {
    set pins [get_pins -quiet -hier -regexp $pin_regex -filter {DIRECTION == IN}]
    set count [llength $pins]
    set report_path [file join $output_dir "${name}.rpt"]

    if {$count == 0} {
        set fd [open $report_path w]
        puts $fd "NO_PATH: name=${name} pattern=${pin_regex}"
        close $fd
        puts "PERF_PATH_RESULT name=${name} endpoint_count=0 status=NO_PATH pattern=${pin_regex}"
        return
    }

    report_timing -delay_type max -max_paths 1 -nworst 1 -path_type full \
        -to $pins -file $report_path
    puts "PERF_PATH_RESULT name=${name} endpoint_count=${count} status=REPORTED report=${report_path}"
}

query_endpoint_group cpu_dma_xfers \
    {.*perf_xfers_r.*\/(D|CE)$} $output_dir
query_endpoint_group dcache_pending_reads \
    {.*perf_dcache_pending_reads.*\/(D|CE)$|.*perf_dcache_pending_read_cycle_q.*\/D$} $output_dir
query_endpoint_group l3_reads \
    {.*perf_core_reads(_per_cycle_q)?.*\/(D|CE)$} $output_dir
query_endpoint_group global_mem_reads \
    {.*mem_perf.*reads.*\/(D|CE)$|.*perf_mem_reads_per_cycle_q.*\/D$} $output_dir

close_design
