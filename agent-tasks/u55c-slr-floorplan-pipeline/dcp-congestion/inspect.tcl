# Read-only inspection. Never change properties, placement, routing or checkpoint.
# Run in Tcl mode so further diagnostic queries can reuse the loaded design.
set dcp [file normalize [lindex $argv 0]]
set outdir [file normalize [lindex $argv 1]]
file mkdir $outdir
cd $outdir
set_param general.maxThreads 8
proc props {obj fields} {
    set result {}
    foreach field $fields {
        if {![catch {get_property $field $obj} value]} {
            lappend result "$field=$value"
        }
    }
    return [join $result { | }]
}
proc emit {message} {puts $::evidence_out $message; flush $::evidence_out}
proc cell_info {cell} {
    emit "CELL $cell [props $cell {REF_NAME LOC BEL IS_LOC_FIXED IS_BEL_FIXED DONT_TOUCH USER_SLL_REG IS_RECONFIGURABLE}]"
    emit "  SLR=[get_slrs -quiet -of_objects $cell] CR=[get_clock_regions -quiet -of_objects $cell] PBLOCK=[get_pblocks -quiet -of_objects $cell]"
    foreach pin [get_pins -quiet -of_objects $cell] {
        emit "  PIN $pin [props $pin {DIRECTION REF_PIN_NAME}] NET=[get_nets -quiet -of_objects $pin]"
    }
}
proc net_info {net} {
    emit "NET $net [props $net {ROUTE_STATUS IS_ROUTE_FIXED IS_FIXED IS_CLOCK DONT_TOUCH}]"
    set segments [get_nets -quiet -segments $net]
    set pins [get_pins -quiet -leaf -of_objects $segments]
    emit "SEGMENTS $segments"
    foreach pin $pins {
        emit "ENDPOINT $pin [props $pin {DIRECTION REF_PIN_NAME}]"
        foreach cell [get_cells -quiet -of_objects $pin] {cell_info $cell}
    }
    set nodes [get_nodes -quiet -of_objects $net]
    emit "ROUTING nodes=[llength $nodes] pips=[llength [get_pips -quiet -of_objects $net]]"
    foreach node $nodes {
        if {[regexp {LAG|UBUMP} $node]} {
            emit "LAGNODE $node [props $node {INTENT_CODE IS_USED}]"
            emit "  USERS=[get_nets -quiet -of_objects $node]"
        }
    }
}
if {![llength [get_designs -quiet]]} {open_checkpoint $dcp}
puts "DCP_LOADED [current_design] PART=[get_property PART [current_design]]"
set hmss_name {level0_i/ulp/hmss_0/inst/path_12/slice0_12/inst/w15.w_multi/triple_slr.fwd.slr_middle/Q[122]}
set gemm_name {level0_i/ulp/vortex_afu_1/inst/afu_wrap/vortex_axi/vortex/g_clusters[0].cluster/g_sockets[0].socket/g_cores[0].core/gemm_node/u_tmem_subsystem/u_input_req_reservation/u_slr/u_response/g_slr.u_link/u_tx/D[243]}
set hmss [get_nets -quiet -hierarchical -filter [list NAME == $hmss_name]]
set gemm [get_nets -quiet -hierarchical -filter [list NAME == $gemm_name]]
puts "TARGET_COUNTS hmss=[llength $hmss] gemm=[llength $gemm]"
if {[llength $hmss] != 1 || [llength $gemm] != 1} {error "Target net resolution failed"}
set evidence_out [open endpoint_inspection.txt w]
    net_info $hmss
    net_info $gemm
    foreach pb [get_pblocks -quiet] {
        emit "PBLOCK $pb [props $pb {GRID_RANGES IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT PARENT SNAPPING_MODE}]"
    }
close $evidence_out
report_route_status -file route_status.rpt
puts "INITIAL_INSPECTION_COMPLETE"
