# Run from a configured, config-sourced build directory with Vivado batch.
# This is a 32-bit BRAM boundary fixture, not a GEMM/core synthesis run.
set fixture_dir [file dirname [file normalize [info script]]]
create_project -in_memory -part xcu55c-fsvh2892-2L-e
read_verilog -sv [file join $fixture_dir naive_weight_slr_preserve.sv]
synth_design -top naive_weight_slr_preserve -part xcu55c-fsvh2892-2L-e
set brams [get_cells -hierarchical -filter {IS_PRIMITIVE && REF_NAME =~ RAMB*}]
if {![llength $brams]} {error "fixture did not infer a block RAM"}
set marked [get_cells -hierarchical -filter {IS_PRIMITIVE && USER_SLL_REG == 1}]
set tx_count 0; set rx_count 0
foreach cell $marked {
    set name [get_property NAME $cell]
    if {![string match FD* [get_property REF_NAME $cell]]} {
        error "marked boundary is not a fabric FF: $name"
    }
    if {[string match *g_slr_mxu_weight_tx* $name]} {
        incr tx_count
        if {[string tolower [get_property DONT_TOUCH $cell]] ni {true 1 yes}} {
            error "TX lost DONT_TOUCH: $name"
        }
    } elseif {[string match *g_slr_mxu_weight_rx* $name]} {
        incr rx_count
        set d [get_pins -of_objects $cell -filter {REF_PIN_NAME == D}]
        set nets [get_nets -segments -of_objects $d]
        set drivers [get_pins -leaf -of_objects $nets -filter {DIRECTION == OUT}]
        if {[llength $drivers] != 1 || [get_property REF_PIN_NAME $drivers] ne "Q"} {
            error "RX D does not have exactly one direct FF Q driver: $name ($drivers)"
        }
        set source [get_cells -of_objects $drivers]
        if {![string match FD* [get_property REF_NAME $source]]
            || ![string match *g_slr_mxu_weight_tx* [get_property NAME $source]]
            || [string tolower [get_property USER_SLL_REG $source]] ni {true 1 yes}} {
            error "RX is not driven by its marked weight TX FF: $name ($source)"
        }
    } else {error "unexpected marked cell: $name"}
}
if {$tx_count != 32 || $rx_count != 32} {
    error "expected 32 standalone TX/RX FF pairs, found $tx_count/$rx_count"
}
puts "PASSED: naive weight BRAM keeps 32 standalone direct SLR TX/RX FF pairs"
