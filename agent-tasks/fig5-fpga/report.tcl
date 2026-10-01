# Apply the same async-RAM netlist fix as the production FPGA flow.
set task_dir [file dirname [file normalize [info script]]]
if {[llength [get_clocks -quiet core_clock]] != 1} {error "Missing 100 MHz reference clock"}
set rtl_root [file normalize "$task_dir/../.."]
if {[info exists ::env(FIG5_RTL_ROOT)]} {set rtl_root $::env(FIG5_RTL_ROOT)}
source "$rtl_root/hw/scripts/xilinx_async_bram_patch.tcl"
opt_design
set blackboxes [get_cells -hierarchical -quiet -filter {IS_BLACKBOX == 1}]
if {[llength $blackboxes]} {error "Unresolved black boxes: $blackboxes"}
report_utilization -file "$out/utilization.rpt"
report_utilization -hierarchical -hierarchical_depth 12 -file "$out/hierarchy.rpt"
# No post-synthesis delay is presented as implemented Fmax.
report_timing_summary -report_unconstrained -max_paths 10 -file "$out/timing_post_opt.rpt"
write_checkpoint -force "$out/post_opt.dcp"
set fh [open "$out/primitives.csv" w]
puts $fh "primitive,count"
foreach ref {LUT1 LUT2 LUT3 LUT4 LUT5 LUT6 LUT6_2 FDRE FDSE FDCE FDPE RAMB18E2 RAMB36E2 URAM288 DSP48E2} {
    puts $fh "$ref,[llength [get_cells -hier -filter "REF_NAME == $ref"]]"
}
close $fh
set fh [open "$out/summary.json" w]
puts $fh "{\"top\":\"$top\",\"part\":\"$part\",\"vivado\":\"[version -short]\",\"blackboxes\":0}"
close $fh
