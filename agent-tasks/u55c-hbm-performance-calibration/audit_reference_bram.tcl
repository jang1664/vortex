# Read-only inspection of an existing checkpoint. No synthesis or checkpoint writes.
if {$argc < 1 || $argc > 2} { error "Usage: audit_reference_bram.tcl checkpoint.dcp ?--keep-open?" }
set keep_open [expr {$argc == 2 && [lindex $argv 1] eq "--keep-open"}]
open_checkpoint [lindex $argv 0]
set matches [get_cells -hierarchical -filter {NAME =~ *icache*mem_req_queue*}]
puts "REFERENCE_BRAM_CELLS [llength $matches]"
foreach cell [lrange $matches 0 99] {
    puts "REFERENCE_BRAM_CELL $cell REF=[get_property REF_NAME $cell]"
    set ref [get_property REF_NAME $cell]
    if {[string match "RAMB*" $ref] || [string match "*raddr_next*" $cell]} {
        foreach pin [get_pins -of_objects $cell -filter {DIRECTION == IN}] {
            set pin_name [get_property REF_PIN_NAME $pin]
            if {![regexp {^(ADDR|EN|REGCE|CLK|RST|I[0-9])} $pin_name]} { continue }
            set nets [get_nets -segments -of_objects $pin]
            puts "REFERENCE_BRAM_SINK $pin"
            foreach driver_pin [get_pins -leaf -of_objects $nets -filter {DIRECTION == OUT}] {
                set driver_cell [get_cells -of_objects $driver_pin]
                puts "REFERENCE_BRAM_PIN_DRIVER $driver_pin REF=[get_property REF_NAME $driver_cell]"
            }
        }
        if {[string match "LUT*" $ref]} {
            puts "REFERENCE_BRAM_LUT $cell INIT=[get_property INIT $cell]"
        }
    }
}
# Optimization can flatten the VX_async_ram_patch module. Search preserved
# nets independently of REF_NAME and do not treat zero matches as success.
set found 0
foreach net [get_nets -hierarchical -filter {NAME =~ *icache*mem_req_queue*}] {
    if {![regexp {/(read_s|raddr_s|raddr_w|raddr_reset)(\[[0-9]+\])?$} $net]} { continue }
    incr found
    puts "REFERENCE_BRAM_NET $net"
    foreach pin [get_pins -leaf -of_objects $net -filter {DIRECTION == OUT}] {
        set driver [get_cells -of_objects $pin]
        puts "REFERENCE_BRAM_DRIVER $pin REF=[get_property REF_NAME $driver]"
    }
}
puts "REFERENCE_BRAM_NET_COUNT $found"
if {$found == 0} {
    puts "REFERENCE_BRAM_DISCOVERY [lrange [get_cells -hierarchical -filter {NAME =~ *icache*}] 0 19]"
    if {!$keep_open} { error "No patch nets found; audit incomplete" }
    puts "REFERENCE_BRAM_AUDIT_INCOMPLETE inspect primitive pins before acceptance"
}
if {!$keep_open} {
    close_design
    exit
}
puts "REFERENCE_BRAM_READY checkpoint retained for read-only queries"
