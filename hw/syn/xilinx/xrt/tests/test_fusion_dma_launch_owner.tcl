source [file join [file dirname [info script]] test_lifted_owner.tcl]
# Reuse the existing pin-graph fixture; add its missing DIRECTION query only.
rename get_pins original_get_pins
proc get_pins {args} {
    set idx [lsearch -exact $args -filter]
    if {$idx < 0 || ![regexp {^DIRECTION == (IN|OUT)$} [lindex $args [expr {$idx+1}]] -> direction]} {
        return [original_get_pins {*}$args]
    }
    set result {}
    foreach object [arg_objects {*}$args] {
        if {![dict exists $::object_pins $object]} {continue}
        foreach pin [dict get $::object_pins $object] {
            if {[dict get $::props $pin DIRECTION] eq $direction} {lappend result $pin}
        }
    }
    return [lsort -unique $result]
}
proc launch_fixture {{input_relative u_VX_gemm_ctrl/queued_cmd} {sink_relative u_gemm_dma_transport/u_commands/u_launch/valid_reg}} {
    set ::env(VORTEX_GEMM_BACKEND) improve
    set ::props {}; set ::object_pins {}; set ::pin_nets {}; set ::net_ports {}
    set ::root {top/node[0]}
    set ::lut "$::root/u_gemm_dma_transport/unrelated_generated_name"
    set ::ff "$::root/$sink_relative"
    set ::source "$::root/$input_relative"
    add_cell $::lut LUT2
    add_cell $::ff FDRE
    add_cell $::source LUT4
    add_pin $::lut I0 IN input_net
    add_pin $::lut I1 IN feedback_net
    add_pin $::lut O OUT output_net
    add_pin $::source O OUT input_net
    add_pin $::ff Q OUT feedback_net
    add_pin $::ff D IN output_net
}
proc launch_recover {} {::vortex::slr::recover_fusion_dma_launch_owner $::lut $::root LUT2}
proc launch_check {expression label} {
    if {![uplevel 1 [list expr $expression]]} {error "FAIL: $label"}
    incr ::checks
}
foreach source_relative {u_VX_gemm_ctrl/queued_cmd u_gemm_dma_transport/u_commands/u_launch/data_ready u_gemm_dma_transport/u_commands/g_slr.u_link/u_tx/credit_decode u_gemm_dma_transport/u_commands/g_slr/u_link/u_tx/credit_decode} {
    foreach sink {u_gemm_dma_transport/u_commands/u_launch/g_eb2.stream_buffer/g_buffer.valid_in_r_reg u_gemm_dma_transport/u_commands/u_launch/g_eb2.stream_buffer/g_buffer.valid_in_r_reg_rep u_gemm_dma_transport/u_commands/u_launch/g_eb2.stream_buffer/g_buffer.valid_out_r_reg} {
        launch_fixture $source_relative $sink
        set proof [launch_recover]
        launch_check {[dict get $proof owner] == 1 && [dict get $proof endpoint] eq "$::ff/D"} "full local direct proof $source_relative $sink"
        launch_check {[catch {::vortex::slr::owner_for u_gemm_dma_transport/unrelated_generated_name}]} names_alone_still_rejected
    }
}
foreach setup {
    {set ::env(VORTEX_GEMM_BACKEND) naive}
    {dict set ::props $::lut USER_SLL_REG 1}
    {dict set ::props $::lut REF_NAME LUT3}
    {dict set ::object_pins $::lut [list $::lut/I0 $::lut/O]}
    {dict set ::net_ports input_net input_port}
    {dict set ::net_ports output_net output_port}
    {dict set ::pin_nets $::lut/I0 {}}
    {dict set ::pin_nets $::lut/O {}}
    {add_cell top/second LUT1; add_pin top/second O OUT input_net}
    {add_cell top/second LUT1; add_pin top/second O OUT output_net}
    {add_cell top/second FDRE; add_pin top/second D IN output_net}
    {dict set ::props $::ff USER_SLL_REG 1}
    {dict set ::props $::ff REF_NAME LUT1}
    {dict set ::props $::ff/D REF_PIN_NAME CE}
    {dict set ::props $::source REF_NAME RAMB36E2}
    {dict set ::props $::source/O REF_PIN_NAME Q}
    {dict set ::object_pins output_net [list $::lut/O]}
    {set ::root other/node}
} {
    launch_fixture
    eval $setup
    launch_check {[catch {launch_recover}]} "reject $setup"
}
foreach source_relative {u_gemm_dma_transport/u_commands/g_slr/u_link/u_rx/memory_side u_gemm_dma_transport/u_completions/g_slr/u_link/u_tx/memory_side u_tmem_subsystem/u_dma_engine/memory_side u_fusion_busy_export/busy_rx_q_reg u_unrelated/local_default} {
    launch_fixture $source_relative
    launch_check {[catch {launch_recover}]} "wrong input source $source_relative"
}
foreach sink {u_gemm_dma_transport/u_commands/g_slr/u_link/u_tx/payload_reg u_gemm_dma_transport/u_commands/g_slr/u_link/u_rx/payload_reg u_gemm_dma_transport/u_completions/u_launch/valid_reg u_VX_gemm_ctrl/state_reg} {
    launch_fixture u_VX_gemm_ctrl/queued_cmd $sink
    launch_check {[catch {launch_recover}]} "wrong sink $sink"
}
puts "PASS: $checks lifted DMA launch ownership checks including prior shared receiver checks"
