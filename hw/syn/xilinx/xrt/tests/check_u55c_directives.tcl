# feat/gemv U55C smoke flow, using the directives exported by the sourced config.
# Run in a configured build tree after sourcing configs/<profile>.sh.
# Usage: vivado -mode batch -source check_u55c_directives.tcl
if {[catch {
    foreach name {PLACE_DESIGN_DIRECTIVE ROUTE_DESIGN_DIRECTIVE} {
        if {![info exists ::env($name)] || $::env($name) eq ""} {
            error "Source a config exporting $name before running this check"
        }
    }
    set source_file [file join [file dirname [file normalize [info script]]] u55c_directive_smoke.v]
    create_project -in_memory -part xcu55c-fsvh2892-2L-e
    read_verilog $source_file
    synth_design -top u55c_directive_smoke -mode out_of_context
    create_clock -period 10.0 [get_ports clk]
    opt_design
    place_design -directive $::env(PLACE_DESIGN_DIRECTIVE)
    route_design -directive $::env(ROUTE_DESIGN_DIRECTIVE)
    if {[llength [get_nets -quiet -hier -filter {ROUTE_STATUS == CONFLICTS}]] != 0} {
        error "U55C directive smoke design contains routing conflicts"
    }
    puts "DIRECTIVE_CHECK: PASS place=$::env(PLACE_DESIGN_DIRECTIVE) route=$::env(ROUTE_DESIGN_DIRECTIVE)"
    close_project
} message options]} {
    puts stderr "DIRECTIVE_CHECK: FAIL $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
