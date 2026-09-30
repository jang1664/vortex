# Run from a configured build with a GEMM config sourced.
# Usage: vivado -mode batch -source .../check_mxu_slr_placement.tcl -tclargs NEW_REPORT_DIR
set test_dir [file dirname [file normalize [info script]]]
if {[catch {
    if {[llength $argv] != 1} {error "Expected NEW_REPORT_DIR"}
    set reports [file normalize [lindex $argv 0]]
    if {[file exists $reports]} {error "Report directory already exists: $reports"}
    file mkdir $reports
    cd $reports
    set_param general.maxThreads 4
    create_project -in_memory -part xcu55c-fsvh2892-2L-e
    read_verilog -sv [file join $test_dir mxu_slr_placement_probe.sv]
    synth_design -mode out_of_context -top mxu_slr_placement_probe -part xcu55c-fsvh2892-2L-e
    create_clock -period 10 [get_ports clk_i]
    source [file join [file dirname $test_dir] mxu_slr_floorplan.tcl]
    set ::env(VORTEX_GEMM_MXU_SLR_FLOORPLAN) 1
    ::vortex::mxu_slr::apply post_init
    opt_design
    ::vortex::mxu_slr::apply post_opt
    place_design
    # Preserve physical evidence even if a post-place gate fails.
    write_checkpoint placement_probe.dcp
    ::vortex::mxu_slr::check_placed
    set alias [get_pins -quiet dut/u_VX_gemm_unit/u_mxu/reset_alias]
    if {[llength $alias] != 1} {error "Probe lost its nonstandard reset hierarchy pin"}
    set owned_reset 0; set external_reset 0
    foreach pin [::vortex::mxu_slr::net_pins $alias] {
        if {[get_property REF_PIN_NAME $pin] ne "R"} {continue}
        set name [get_property NAME [get_cells -of_objects $pin]]
        if {[dict exists $::vortex::mxu_slr::owners $name]} {incr owned_reset} else {incr external_reset}
    }
    if {!$owned_reset || !$external_reset} {error "Probe lacks shared owned/external reset sinks: $owned_reset/$external_reset"}
    puts "PLACEMENT_CHECK: reset alias dedicated sinks owned=$owned_reset external=$external_reset"
    set dsp [get_cells -hier -filter {REF_NAME == DSP48E2}]
    if {[llength $dsp] != 1} {error "Probe must retain exactly one DSP48E2"}
    set sites [get_sites -of_objects $dsp]
    set actual [get_slrs -of_objects $sites]
    if {[llength $sites] != 1 || $actual ne "SLR2"} {error "DSP site is not in SLR2: $sites $actual"}
    puts "PLACEMENT_CHECK: DSP sites=$sites physical_slr=$actual direct_macro_slr=[get_slrs -of_objects $dsp]"
    puts "PLACEMENT_CHECK: PASS (post-init, post-opt, actual placement, post-place links and DSP site)"
    close_project
} message options]} {
    puts stderr "PLACEMENT_CHECK: FAIL $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
