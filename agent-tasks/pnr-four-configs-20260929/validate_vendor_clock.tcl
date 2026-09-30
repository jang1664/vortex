# Exercise the installed vendor procedures without running synthesis or PnR.
if {[catch {
    source /tool/Program/Xilinx/2025.1/Vitis/scripts/ocl/ocl_util.tcl
    source /home/jaeyongjang/project.local/vortex_fpint/hw/syn/xilinx/xrt/pre_init_hook.tcl
    create_project -in_memory -part xcu55c-fsvh2892-2L-e
    ::ocl_util::initialize_clkwiz_debug false xcu55c-fsvh2892-2L-e
    foreach requested {100 125 300} {
        ::ocl_util::set_clkwiz_prop 100 $requested
        set m [::ocl_util::get_clkwiz_prop ChosenM]
        set d [::ocl_util::get_clkwiz_prop ChosenD]
        set div0 [::ocl_util::get_clkwiz_prop ChosenDiv0]
        set actual [expr {100.0 * $m / ($d * $div0)}]
        if {abs($actual - $requested) > 0.001} {
            error "Requested $requested MHz but clock API selected $actual MHz"
        }
        puts "CLOCK_CHECK: requested=$requested actual=$actual MHz"
    }
    ::ocl_util::uninitialize_clkwiz_debug false xcu55c-fsvh2892-2L-e
    close_project
    puts "PASS: installed Vitis 2025.1 clock API accepts U55C part keys"
} message options]} {
    puts stderr "FAIL: $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
