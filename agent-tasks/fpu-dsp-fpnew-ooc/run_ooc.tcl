if {$::argc != 3} { error "Usage: run_ooc.tcl <top> <out_dir> <mode>" }
set top [lindex $::argv 0]
set out_dir [file normalize [lindex $::argv 1]]
set mode [lindex $::argv 2]
set repo [file normalize [file join [file dirname [info script]] ../..]]
set part xcu55c-fsvh2892-2L-e
file mkdir $out_dir
create_project fpu_ooc [file join $out_dir project] -force -part $part
set_property source_mgmt_mode None [current_project]
set incs [list \
  [file join $repo hw/rtl] [file join $repo hw/rtl/fpu] [file join $repo hw/rtl/libs] \
  [file join $repo hw/rtl/interfaces] [file join $repo hw/rtl/core] \
  [file join $repo third_party/cvfpu/src] \
  [file join $repo third_party/cvfpu/src/common_cells/include] \
  [file join $repo third_party/cvfpu/src/common_cells/src] \
  [file join $repo third_party/cvfpu/src/fpu_div_sqrt_mvp/hdl]]
set files [list [file join $repo agent-tasks/fpu-dsp-fpnew-ooc/fpu_ooc_wrappers.sv]]
lappend files [file join $repo hw/rtl/fpu/patched_cvfpu/fpnew_pkg.sv]
if {$mode eq "dsp"} {
  lappend files [file join $repo hw/rtl/VX_gpu_pkg.sv]
  lappend files [file join $repo hw/rtl/fpu/VX_fpu_pkg.sv]
  lappend files [file join $repo hw/rtl/fpu/VX_fpu_fma.sv]
  lappend files [file join $repo hw/rtl/libs/VX_pe_serializer.sv]
  lappend files [file join $repo hw/rtl/libs/VX_shift_register.sv]
  lappend files [file join $repo hw/rtl/libs/VX_pipe_register.sv]
  lappend files [file join $repo hw/rtl/libs/VX_elastic_buffer.sv]
  lappend files [file join $repo hw/rtl/libs/VX_stream_buffer.sv]
  lappend files [file join $repo hw/rtl/libs/VX_pipe_buffer.sv]
  set defs {FPU_DSP VIVADO XLEN_32 EXT_F_ENABLE FMA_PE_RATIO=1 LATENCY_FMA=4}
  set ip_dir [file normalize [lindex [glob -nocomplain -types d [file join $repo build/hw/syn/xilinx/xrt/*/ip]] 0]]
  if {$ip_dir eq ""} { error "Generated Xilinx IP directory not found" }
  add_files -norecurse [file join $ip_dir xil_fma_lowL/xil_fma_lowL.xci]
} else {
  lappend files [file join $repo hw/rtl/fpu/patched_cvfpu/fpnew_opgroup_block.sv]
  lappend files [file join $repo hw/rtl/fpu/patched_cvfpu/fpnew_opgroup_multifmt_slice.sv]
  foreach f [glob -nocomplain [file join $repo third_party/cvfpu/src/*.sv]] {
    if {[lsearch -exact {fpnew_pkg.sv fpnew_opgroup_block.sv fpnew_opgroup_multifmt_slice.sv} [file tail $f]] < 0} {
      lappend files $f
    }
  }
  foreach f [glob -nocomplain [file join $repo third_party/cvfpu/src/common_cells/src/*.sv]] { lappend files $f }
  foreach f [glob -nocomplain [file join $repo third_party/cvfpu/src/fpu_div_sqrt_mvp/hdl/*.sv]] { lappend files $f }
  set defs {FPU_FPNEW XLEN_32 EXT_F_ENABLE}
}
add_files -norecurse $files
set_property include_dirs $incs [current_fileset]
set_property verilog_define $defs [current_fileset]
update_compile_order -fileset sources_1
set_property top $top [current_fileset]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]
set xdc [file join $out_dir constraints.xdc]
set fh [open $xdc w]
puts $fh {create_clock -name clk -period 5.0 [get_ports clk]}
puts $fh {set_input_delay 0.0 -clock clk [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != reset}]}
puts $fh {set_output_delay 0.0 -clock clk [get_ports -filter {DIRECTION == OUT}]}
puts $fh {set_false_path -from [get_ports reset]}
close $fh
read_xdc $xdc
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} { error "synthesis failed" }
open_run synth_1
report_utilization -hierarchical -hierarchical_percentages -file [file join $out_dir utilization.rpt]
report_timing_summary -max_paths 20 -delay_type max -file [file join $out_dir timing.rpt]
write_checkpoint -force [file join $out_dir post_synth.dcp]
close_project
