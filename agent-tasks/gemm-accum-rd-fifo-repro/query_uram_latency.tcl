if {$argc < 1} {
  puts "usage: vivado -mode batch -source query_uram_latency.tcl -tclargs <checkpoint.dcp>"
  exit 1
}

set dcp [lindex $argv 0]
puts "DCP $dcp"
open_checkpoint $dcp

set urams [get_cells -hier -filter {REF_NAME =~ URAM288*}]
puts "URAM_CELL_COUNT [llength $urams]"

array set hist {}
set props {
  IREG_PRE_A IREG_PRE_B
  OREG_A OREG_B
  OREG_ECC_A OREG_ECC_B
  REG_CAS_A REG_CAS_B
  CASCADE_ORDER_A CASCADE_ORDER_B
  CASCADE_ORDER_CTRL_A CASCADE_ORDER_CTRL_B
  CASCADE_ORDER_DATA_A CASCADE_ORDER_DATA_B
}

proc prop_or_na {cell prop} {
  if {[catch {get_property $prop $cell} value]} {
    return "<NA>"
  }
  if {$value eq ""} {
    return "<empty>"
  }
  return $value
}

foreach c $urams {
  set key ""
  foreach p $props {
    append key "$p=[prop_or_na $c $p];"
  }
  incr hist($key)
}

puts "URAM_PROPERTY_HISTOGRAM_BEGIN"
foreach k [lsort [array names hist]] {
  puts "COUNT $hist($k) $k"
}
puts "URAM_PROPERTY_HISTOGRAM_END"

set focus {}
foreach c $urams {
  if {[regexp -nocase {gemm|acc_mem|VX_sp_ram|u_VX_gemm_unit} $c]} {
    lappend focus $c
  }
}
puts "FOCUS_URAM_COUNT [llength $focus]"

if {[llength $focus] == 0} {
  set sample [lrange $urams 0 19]
  puts "FOCUS_EMPTY_SAMPLE_FIRST_20"
} else {
  set sample [lrange $focus 0 79]
  puts "FOCUS_SAMPLE_FIRST_80"
}

foreach c $sample {
  puts "CELL $c"
  puts "  REF_NAME=[get_property REF_NAME $c]"
  puts "  PARENT=[get_property PARENT $c]"
  puts "  LOC=[prop_or_na $c LOC]"
  puts "  BEL=[prop_or_na $c BEL]"
  foreach p $props {
    puts "  $p=[prop_or_na $c $p]"
  }
}

close_design
