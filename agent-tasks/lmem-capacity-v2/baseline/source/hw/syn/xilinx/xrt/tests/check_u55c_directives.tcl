# Execute the selected implementation directives on a tiny XCU55C design.
# This catches options which are present in generic Vivado help but unsupported
# by the target part, without running the Vortex implementation flow.

if {$argc != 1} {
    puts stderr "usage: vivado -mode batch -source check_u55c_directives.tcl -tclargs VERILOG_SOURCE"
    exit 2
}

create_project -in_memory -part xcu55c-fsvh2892-2L-e
read_verilog [lindex $argv 0]
synth_design -top u55c_directive_smoke
create_clock -period 10.0 [get_ports clk]
opt_design
place_design -directive Explore
route_design -directive AlternateCLBRouting

if {[llength [get_nets -quiet -hier -filter {ROUTE_STATUS == CONFLICTS}]] != 0} {
    error "U55C directive smoke design contains routing conflicts"
}

puts "CHECK: XCU55C accepts place_design Explore"
puts "CHECK: XCU55C accepts route_design AlternateCLBRouting"
close_project
