# Synthesis-only adaptation of hw/syn/xilinx/dut/ooc_synth.tcl.
if {$argc != 5} {error "Expected top part source_list output_dir generics"}
lassign $argv top part sources out generics
set_param general.maxThreads 4
create_project fig5_ooc "$out/project" -force -part $part
if {[info exists ::env(FIG5_IP_TCL)]} {source $::env(FIG5_IP_TCL)}
set fh [open $sources r]
set files [split [string trim [read $fh]] "\n"]
close $fh
add_files -norecurse $files
set_property top $top [current_fileset]
if {$generics ne ""} {set_property generic $generics [current_fileset]}
set_property source_mgmt_mode None [current_project]
update_compile_order -fileset sources_1
set xdc [open "$out/clock.xdc" w]
puts $xdc {create_clock -name core_clock -period 10.000 [get_ports clk]}
close $xdc
read_xdc "$out/clock.xdc"
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $status]} {error "Synthesis failed: $status"}
open_run synth_1
source [file join [file dirname [info script]] report.tcl]
