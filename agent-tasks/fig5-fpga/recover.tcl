if {$argc != 4} {error "Expected top part checkpoint output_dir"}
lassign $argv top part checkpoint out
set_param general.maxThreads 4
open_checkpoint $checkpoint
read_xdc "$out/clock.xdc"
if {[llength [get_clocks -quiet core_clock]] != 1} {error "Missing 100 MHz reference clock"}
source [file join [file dirname [info script]] report.tcl]
