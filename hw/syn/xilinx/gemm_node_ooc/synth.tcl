# Reproducible synthesis-only VX_gemm_node out-of-context flow.

if {$::argc != 7} {
  puts "ERROR: $::argv0 requires 7 arguments"
  puts "Usage: $::argv0 <top> <part> <source_manifest> <xdc> <output_dir> <jobs> <write_checkpoint>"
  exit 1
}

set top_module [lindex $::argv 0]
set device_part [lindex $::argv 1]
set source_manifest [file normalize [lindex $::argv 2]]
set xdc_file [file normalize [lindex $::argv 3]]
set output_dir [file normalize [lindex $::argv 4]]
set num_jobs [lindex $::argv 5]
set write_checkpoint [lindex $::argv 6]
set tool_dir $::env(TOOL_DIR)

set synth_strategy "Vivado Synthesis Defaults"
set synth_more_options "-mode out_of_context"

file mkdir $output_dir

source "${tool_dir}/parse_vcs_list.tcl"
set parsed_manifest [parse_vcs_list $source_manifest]
set source_files [lindex $parsed_manifest 0]
set include_dirs [lindex $parsed_manifest 1]
set verilog_defines [lindex $parsed_manifest 2]

create_project gemm_node_ooc "${output_dir}/project" -force -part $device_part
add_files -norecurse $source_files
set_property include_dirs $include_dirs [current_fileset]
set_property verilog_define $verilog_defines [current_fileset]
set_property top $top_module [current_fileset]
set_property source_mgmt_mode None [current_project]
read_xdc $xdc_file
update_compile_order -fileset sources_1

set_property strategy $synth_strategy [get_runs synth_1]
set_property \
    -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value $synth_more_options \
    -objects [get_runs synth_1]

launch_runs synth_1 -verbose -jobs $num_jobs
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
  error "OOC synthesis failed with status: $synth_status"
}

open_run synth_1

set ooc_clock [get_clocks core_clock]
set clock_period [get_property PERIOD $ooc_clock]
set data_inputs [get_ports -quiet -filter {
  DIRECTION == IN && NAME != clk && NAME != reset
}]
set data_outputs [get_ports -quiet -filter {DIRECTION == OUT}]
if {[llength $data_inputs] > 0} {
  set_input_delay 0.0 -clock $ooc_clock $data_inputs
}
if {[llength $data_outputs] > 0} {
  set_output_delay 0.0 -clock $ooc_clock $data_outputs
}

report_utilization \
    -hierarchical \
    -hierarchical_percentages \
    -file "${output_dir}/post_synth_utilization.rpt"
report_timing_summary \
    -delay_type max \
    -max_paths 100 \
    -report_unconstrained \
    -file "${output_dir}/post_synth_setup_timing_summary.rpt"
report_timing \
    -delay_type max \
    -sort_by slack \
    -max_paths 100 \
    -path_type full_clock_expanded \
    -file "${output_dir}/post_synth_setup_timing_paths.rpt"
report_methodology -file "${output_dir}/post_synth_methodology.rpt"

set worst_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set failing_paths [get_timing_paths -quiet -delay_type max -max_paths 100000 \
    -slack_lesser_than 0.0]
if {[llength $worst_paths] == 0} {
  set setup_wns "N/A"
} else {
  set setup_wns [get_property SLACK [lindex $worst_paths 0]]
}
set setup_tns 0.0
set failing_endpoints [dict create]
foreach timing_path $failing_paths {
  set path_slack [get_property SLACK $timing_path]
  set setup_tns [expr {$setup_tns + $path_slack}]
  dict set failing_endpoints [get_property ENDPOINT_PIN $timing_path] 1
}
set failing_endpoint_count [dict size $failing_endpoints]

set gate_file [open "${output_dir}/setup_gate.txt" w]
puts $gate_file "setup_wns_ns=$setup_wns"
puts $gate_file "setup_tns_ns=$setup_tns"
puts $gate_file "setup_failing_endpoints=$failing_endpoint_count"
close $gate_file

if {$write_checkpoint} {
  write_checkpoint -force "${output_dir}/post_synth.dcp"
}

set metadata_file [open "${output_dir}/vivado_metadata.txt" w]
puts $metadata_file "top=$top_module"
puts $metadata_file "requested_part=$device_part"
puts $metadata_file "elaborated_part=[get_property PART [current_design]]"
puts $metadata_file "clock_name=core_clock"
puts $metadata_file "clock_period_ns=$clock_period"
puts $metadata_file "vivado=[version -short]"
puts $metadata_file "design_mode=[get_property DESIGN_MODE [current_design]]"
puts $metadata_file "synthesis_status=$synth_status"
puts $metadata_file "synthesis_strategy=$synth_strategy"
puts $metadata_file "synthesis_more_options=$synth_more_options"
puts $metadata_file "source_mgmt_mode=[get_property SOURCE_MGMT_MODE [current_project]]"
puts $metadata_file "write_checkpoint=$write_checkpoint"
close $metadata_file

if {$setup_wns eq "N/A"} {
  error "No max-delay setup timing path was reported"
}
if {$setup_wns < 0.0 || $setup_tns < 0.0 || $failing_endpoint_count != 0} {
  error "Setup timing gate failed: WNS=$setup_wns ns, TNS=$setup_tns ns, failing endpoints=$failing_endpoint_count"
}

puts "VX_gemm_node OOC setup timing gate passed"
