# Read-only inspection of the failed run's kernel synthesis checkpoint.
if {[catch {
    open_checkpoint [lindex $argv 0]
    set target {g_slr_mxu_weight_tx.payload_q[valid]_i_1}
    set lut {}
    set counts [dict create]
    set marked 0
    foreach cell [get_cells -hierarchical -quiet -filter {IS_PRIMITIVE == 1} *] {
        set name [get_property NAME $cell]
        if {![regexp {/g_slr_mxu_(input|weight|output)_(tx|rx)[/.]} $name -> stream half]} {continue}
        set ref [get_property REF_NAME $cell]
        dict incr counts ${stream}_${half}:$ref
        if {[string tolower [get_property USER_SLL_REG $cell]] in {1 true yes}} {incr marked}
        if {[string first $target $name] >= 0} {set lut $cell}
    }
    puts "DIAG: BANK_COUNTS $counts"
    puts "DIAG: MARKED_COUNT $marked"
    if {$lut eq {}} {error "Failed-run LUT not found in synthesis checkpoint"}
    puts "DIAG: LUT $lut REF=[get_property REF_NAME $lut] USER_SLL_REG=[get_property USER_SLL_REG $lut] INIT=[get_property INIT $lut]"
    foreach pin [get_pins -of_objects $lut] {
        set direction [get_property DIRECTION $pin]
        if {[get_property REF_PIN_NAME $pin] ne "O"} {continue}
        set nets [get_nets -segments -of_objects $pin]
        foreach peer [get_pins -leaf -of_objects $nets] {
            set cell [get_cells -of_objects $peer]
            puts "DIAG: LUT_OUTPUT_NET $peer REF=[get_property REF_NAME $cell] MARKED=[get_property USER_SLL_REG $cell]"
            if {[get_property REF_PIN_NAME $peer] ne "D" || ![string match FD* [get_property REF_NAME $cell]]} {continue}
            set tx $cell
            set q [get_pins -of_objects $tx -filter {REF_PIN_NAME == Q}]
            foreach endpoint [get_pins -leaf -of_objects [get_nets -segments -of_objects $q]] {
                set endcell [get_cells -of_objects $endpoint]
                puts "DIAG: TX_Q_NET $endpoint REF=[get_property REF_NAME $endcell] MARKED=[get_property USER_SLL_REG $endcell]"
            }
        }
    }
    puts "DIAG: PASS read-only inspection completed"
    close_design
} message options]} {
    puts stderr "DIAG: FAIL $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
