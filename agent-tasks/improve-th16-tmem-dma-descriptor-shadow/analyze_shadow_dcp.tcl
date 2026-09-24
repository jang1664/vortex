if {$argc != 2} {
  puts stderr "usage: vivado -mode batch -source analyze_shadow_dcp.tcl -tclargs <dcp> <report-prefix>"
  exit 2
}

set dcp_path [lindex $argv 0]
set report_prefix [lindex $argv 1]
open_checkpoint $dcp_path

set out [open "${report_prefix}_shadow_structure.rpt" w]
puts $out "DCP $dcp_path"

set controllers [get_cells -quiet -hier -filter {NAME =~ *gemm_node/u_tmem_dma_ctrl}]
puts $out "CONTROLLER_COUNT [llength $controllers]"
foreach controller $controllers {
  puts $out "CONTROLLER $controller"
}

foreach pattern {
  *candidate_desc_q*
  *candidate_store_desc_q*
  *shadow_desc_q*
  *candidate_owner_q*
  *candidate_store_cursor_q*
  *candidate_store_remaining_q*
} {
  set matched [get_cells -quiet -hier -filter "NAME =~ $pattern"]
  puts $out "CELL_PATTERN $pattern COUNT [llength $matched]"
}

set controller_leaves [get_cells -quiet -hier -filter {NAME =~ *gemm_node/u_tmem_dma_ctrl/*}]
set lut_total 0
foreach ref_name {LUT1 LUT2 LUT3 LUT4 LUT5 LUT6} {
  set count [llength [filter $controller_leaves "REF_NAME == $ref_name"]]
  incr lut_total $count
  puts $out "CONTROLLER_REF $ref_name COUNT $count"
}
set ff_total 0
foreach ref_name {FDCE FDPE FDRE FDSE} {
  set count [llength [filter $controller_leaves "REF_NAME == $ref_name"]]
  incr ff_total $count
  puts $out "CONTROLLER_REF $ref_name COUNT $count"
}
puts $out "CONTROLLER_LUT_TOTAL $lut_total"
puts $out "CONTROLLER_FF_TOTAL $ff_total"

set fanout_rows {}
set controller_nets [get_nets -quiet -hier -filter {NAME =~ *gemm_node/u_tmem_dma_ctrl/*}]
foreach net $controller_nets {
  set loads [get_pins -quiet -of_objects $net -filter {DIRECTION == IN}]
  set fanout [llength $loads]
  if {$fanout > 0} {
    lappend fanout_rows [list $fanout $net]
  }
}
set fanout_rows [lsort -integer -decreasing -index 0 $fanout_rows]
set max_rows [expr {[llength $fanout_rows] < 50 ? [llength $fanout_rows] : 50}]
for {set i 0} {$i < $max_rows} {incr i} {
  set row [lindex $fanout_rows $i]
  puts $out "CONTROLLER_FANOUT [lindex $row 0] NET [lindex $row 1]"
}
close $out

if {[llength $controllers] == 1} {
  report_utilization -cells [lindex $controllers 0] -file "${report_prefix}_controller_utilization.rpt"
}
close_design
exit 0
