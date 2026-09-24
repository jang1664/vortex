if {$::argc != 2} {
    puts "Usage: inspect_ooc_nets.tcl <checkpoint> <output>"
    exit 1
}

set checkpoint [file normalize [lindex $::argv 0]]
set output_path [file normalize [lindex $::argv 1]]

open_checkpoint $checkpoint

set output_file [open $output_path w]
foreach pattern {
    *response_payload_ram*
    *slot_rsp_data*
    *ram_wr_slot_data*
    *dcache_req_data_w*
    *lmem_req_data_w*
} {
    set cells [lsort [get_cells -hier -quiet -filter "NAME =~ $pattern"]]
    set nets [lsort [get_nets -hier -quiet -filter "NAME =~ $pattern"]]
    puts $output_file "pattern=$pattern cells=[llength $cells] nets=[llength $nets]"
    foreach cell [lrange $cells 0 31] {
        puts $output_file "cell=$cell"
    }
    foreach net [lrange $nets 0 63] {
        puts $output_file "net=$net"
    }
}
close $output_file

exit 0
