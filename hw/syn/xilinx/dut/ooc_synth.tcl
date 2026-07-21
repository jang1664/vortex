# Synthesis-only Vivado out-of-context flow.

if { $::argc != 8 } {
  puts "ERROR: $::argv0 requires 8 arguments"
  puts "Usage: $::argv0 <top> <part> <vcs_file> <xdc_file> <output_dir> <jobs> <write_checkpoint> <top_generics>"
  exit 1
}

set top_module [lindex $::argv 0]
set device_part [lindex $::argv 1]
set vcs_file [file normalize [lindex $::argv 2]]
set xdc_file [file normalize [lindex $::argv 3]]
set output_dir [file normalize [lindex $::argv 4]]
set num_jobs [lindex $::argv 5]
set write_checkpoint [lindex $::argv 6]
set top_generics [lindex $::argv 7]
set tool_dir $::env(TOOL_DIR)

file mkdir $output_dir

puts "OOC top: $top_module"
puts "Device: $device_part"
puts "Source list: $vcs_file"
puts "Constraint: $xdc_file"
puts "Output: $output_dir"
puts "Jobs: $num_jobs"
puts "Write checkpoint: $write_checkpoint"
puts "Top generics: $top_generics"

source "${tool_dir}/parse_vcs_list.tcl"
set vlist [parse_vcs_list $vcs_file]
set vsources_list [lindex $vlist 0]
set vincludes_list [lindex $vlist 1]
set vdefines_list [lindex $vlist 2]

create_project dma_ooc "${output_dir}/project" -force -part $device_part
read_xdc $xdc_file
add_files -norecurse $vsources_list
set_property include_dirs $vincludes_list [current_fileset]
set_property verilog_define $vdefines_list [current_fileset]
update_compile_order -fileset sources_1
set_property top $top_module [current_fileset]
if {$top_generics ne ""} {
  set_property generic $top_generics [current_fileset]
}
set_property source_mgmt_mode None [current_project]
set_property \
    -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value {-mode out_of_context} \
    -objects [get_runs synth_1]

launch_runs synth_1 -verbose -jobs $num_jobs
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "Synthesis status: $synth_status"
if {![string match "*Complete*" $synth_status]} {
  error "OOC synthesis failed with status: $synth_status"
}

open_run synth_1

# The shared project XDC defines the OOC clock but intentionally has no board-
# level I/O delays. Constrain wrapper data ports at the report boundary so the
# timing summary does not silently omit input-to-register or register-to-output
# paths. Reset is asynchronous control and is excluded from timed data paths.
set ooc_clock [get_clocks core_clock]
set ooc_reset_ports [get_ports -quiet reset]
set ooc_data_inputs [get_ports -quiet -filter {
  DIRECTION == IN && NAME != clk && NAME != reset
}]
set ooc_data_outputs [get_ports -quiet -filter {DIRECTION == OUT}]
if {[llength $ooc_data_inputs] > 0} {
  set_input_delay 0.0 -clock $ooc_clock $ooc_data_inputs
}
if {[llength $ooc_data_outputs] > 0} {
  set_output_delay 0.0 -clock $ooc_clock $ooc_data_outputs
}
if {[llength $ooc_reset_ports] > 0} {
  set_false_path -from $ooc_reset_ports
}

report_utilization \
    -hierarchical \
    -hierarchical_percentages \
    -file "${output_dir}/post_synth_util.rpt"
report_timing_summary \
    -max_paths 100 \
    -report_unconstrained \
    -delay_type max \
    -file "${output_dir}/post_synth_timing_summary.rpt"
report_methodology -file "${output_dir}/post_synth_methodology.rpt"
if {$write_checkpoint} {
  write_checkpoint -force "${output_dir}/post_synth.dcp"
}

set metadata [open "${output_dir}/vivado_metadata.txt" w]
puts $metadata "top=$top_module"
puts $metadata "device=$device_part"
puts $metadata "part=[get_property PART [current_design]]"
puts $metadata "vivado=[version -short]"
puts $metadata "design_mode=[get_property DESIGN_MODE [current_design]]"
puts $metadata "synthesis_status=$synth_status"
puts $metadata "write_checkpoint=$write_checkpoint"
puts $metadata "top_generics=$top_generics"
close $metadata

puts "OOC synthesis reports written to $output_dir"
