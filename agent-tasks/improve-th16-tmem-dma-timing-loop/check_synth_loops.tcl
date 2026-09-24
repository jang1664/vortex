# Synthesize the packaged Vortex kernel and emit loop-specific methodology and
# DRC reports. Usage:
#   vivado -mode batch -source check_synth_loops.tcl \
#     -tclargs <kernel_pack.xpr> <report_dir>

if {$argc != 2} {
  puts stderr "usage: check_synth_loops.tcl <kernel_pack.xpr> <report_dir>"
  exit 2
}

set project_file [file normalize [lindex $argv 0]]
set report_dir [file normalize [lindex $argv 1]]
file mkdir $report_dir

open_project $project_file
set ip_objects [get_ips -quiet]
if {[llength $ip_objects] != 0} {
  generate_target all $ip_objects
  synth_ip $ip_objects
}
synth_design -top vortex_afu -part xcu55c-fsvh2892-2L-e \
  -flatten_hierarchy rebuilt

report_methodology -file [file join $report_dir post_synth_methodology.rpt]
report_drc -checks {LUTLP-1} -file [file join $report_dir post_synth_lutlp.rpt]
check_timing -verbose -file [file join $report_dir post_synth_check_timing.rpt]
write_checkpoint -force [file join $report_dir vortex_afu_post_synth.dcp]

close_project
