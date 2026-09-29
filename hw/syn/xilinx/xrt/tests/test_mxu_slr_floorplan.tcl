# Plain Tcl fixtures for ownership and exact FF links; no Vivado required.
set xrt_dir [file dirname [file dirname [file normalize [info script]]]]
source [file join $xrt_dir mxu_slr_floorplan.tcl]
set out_dir [file join /tmp vortex_mxu_slr_fixture_[pid]]
file mkdir $out_dir
cd $out_dir
set ::env(VORTEX_GEMM_MXU_SLR_FLOORPLAN) 1
set checks 0

proc cell {name ref {marked 0}} {
    dict set ::props $name [dict create NAME $name REF_NAME $ref USER_SLL_REG $marked PBLOCK {} LOC SLICE_X1Y1 BEL AFF]
    lappend ::primitives $name
}
proc pair {root stream field} {
    set tx ${root}/g_slr_mxu_${stream}_tx.${field}_reg\[0\]
    set rx ${root}/g_slr_mxu_${stream}_rx.${field}_reg\[0\]
    cell $tx FDRE 1; cell $rx FDRE 1
    dict set ::nets $rx/D [list $tx/Q $rx/D]
    dict set ::nets $tx/Q [list $tx/Q $rx/D]
}
proc fixture {{backend gemm_node_naive}} {
    set ::props [dict create]; set ::primitives {}; set ::nets [dict create]
    set ::blocks {}; set ::block_props [dict create]; set ::ports [dict create]
    set ::part xcu55c-fsvh2892-2L-e
    set ::root design/$backend/u_VX_gemm_unit
    cell $::root/u_mxu/mul_reg FDRE
    cell $::root/u_mxu/mul_dsp DSP48E2
    cell $::root/g_local_prealign_blk_idx.data_q_reg\[0\] FDRE
    pair $::root input data_q; pair $::root input control_q
    pair $::root weight payload_q; pair $::root output payload_q
    # The tree's input connects only to the SLR2 RX and an internal leaf.
    set port $::root/u_mxu/ifmap_i\[0\]
    dict set ::ports $::root/u_mxu [list $port $::root/u_mxu/clk_i $::root/u_mxu/resetn_i]
    dict set ::nets $port [list $::root/g_slr_mxu_input_rx.data_q_reg\[0\]/Q $::root/u_mxu/mul_reg/D]
    # Unrelated primitives must never become placement members.
    cell design/u_dma_engine/dma_reg FDRE
    cell $::root/gen_acc_mem/ram RAMB36E2
}
proc add_second_unit {} {
    set root design/core1/gemm_node/u_VX_gemm_unit
    cell $root/u_mxu/mul_reg FDRE
    cell $root/g_local_prealign_blk_idx.data_q_reg\[0\] FDRE
    pair $root input data_q; pair $root input control_q
    pair $root weight payload_q; pair $root output payload_q
    dict set ::ports $root/u_mxu {}
    return $root
}
proc current_design {} {return design}
proc get_cells {args} {
    set idx [lsearch -exact $args -of_objects]
    if {$idx >= 0} {return [list [file dirname [lindex $args [expr {$idx+1}]]]]}
    if {[lsearch -exact $args -hierarchical] >= 0} {return $::primitives}
    set name [lindex [lindex $args end] 0]
    if {[dict exists $::props $name] || [dict exists $::ports $name]} {return [list $name]}
    return {}
}
proc get_property {property object} {
    set object [lindex $object 0]
    if {$property eq "PART"} {return $::part}
    if {$property eq "NAME"} {return $object}
    if {$property eq "REF_PIN_NAME"} {return [file tail $object]}
    if {$property eq "DIRECTION"} {return [expr {[file tail $object] in {Q O G P} ? "OUT" : "IN"}]}
    if {[dict exists $::props $object $property]} {return [dict get $::props $object $property]}
    if {[dict exists $::block_props $object $property]} {return [dict get $::block_props $object $property]}
    return {}
}
proc get_pins {args} {
    set idx [lsearch -exact $args -of_objects]
    set object [lindex [lindex $args [expr {$idx+1}]] 0]
    if {[lsearch -exact $args -leaf] >= 0} {return [dict get $::nets $object]}
    if {[lsearch -exact $args -filter] >= 0} {return [list $object/D]}
    if {[dict exists $::ports $object]} {return [dict get $::ports $object]}
    return {}
}
proc get_nets {args} {
    set object [lindex [lindex $args end] 0]
    if {[dict exists $::nets $object]} {return [list $object]}
    return {}
}
proc get_pblocks {args} {
    set name [lindex $args end]
    return [expr {$name in $::blocks ? [list $name] : {}}]
}
proc create_pblock {name} {lappend ::blocks $name}
proc resize_pblock {block args} {
    dict set ::block_props $block RANGE [lindex $args end]
}
proc set_property {property value object} {
    dict set ::block_props $object $property $value
}
proc add_cells_to_pblock {block cells} {
    foreach object $cells {
        if {[dict exists $::props $object]} {dict set ::props $object PBLOCK $block}
    }
}
proc get_slrs {args} {
    set object [lindex [lindex $args end] 0]
    if {[dict exists $::props $object SLR]} {return [dict get $::props $object SLR]}
    return SLR[lindex [::vortex::mxu_slr::classify $object] 2]
}
proc assert_equal {actual expected label} {
    incr ::checks
    if {$actual ne $expected} {error "$label: expected '$expected', got '$actual'"}
}
proc rejects {script pattern} {
    incr ::checks
    if {![catch {uplevel 1 $script} message]} {error "expected rejection: $pattern"}
    if {![string match $pattern $message]} {error "unexpected rejection: $message (expected $pattern)"}
}

foreach backend {gemm_node_naive gemm_node} {
    fixture $backend
    ::vortex::mxu_slr::apply post_init
    ::vortex::mxu_slr::apply post_opt
    ::vortex::mxu_slr::check_placed
    assert_equal [dict get $::props design/u_dma_engine/dma_reg PBLOCK] {} "DMA unconstrained"
    assert_equal [dict get $::props $::root/gen_acc_mem/ram PBLOCK] {} "ACC unconstrained"
    assert_equal [dict get $::block_props pblock_mxu_slr2 RANGE] SLR2 "MXU target SLR"
    assert_equal [dict get $::block_props pblock_mxu_slr2 EXCLUDE_PLACEMENT] false "SLR2 not reserved"
    dict set ::props $::root/u_mxu/mul_reg SLR SLR1
    rejects {::vortex::mxu_slr::check_placed} {*wrong SLR*}
}

fixture
set ::env(VORTEX_GEMM_MXU_SLR_FLOORPLAN) 0
source [file join $xrt_dir floorplan.tcl]
assert_equal $::blocks {} "disabled floorplan"
set ::env(VORTEX_GEMM_MXU_SLR_FLOORPLAN) 2
rejects {::vortex::mxu_slr::apply post_init} {*must be 0 or 1*}
set ::env(VORTEX_GEMM_MXU_SLR_FLOORPLAN) 1
set ::part xcvu9p-test
rejects {::vortex::mxu_slr::apply post_init} {*XCU55C only*}

fixture
set second [add_second_unit]
source [file join $xrt_dir floorplan.tcl]
source [file join $xrt_dir post_opt_hook.tcl]
::vortex::mxu_slr::check_placed
assert_equal [llength $::vortex::mxu_slr::roots] 2 "multiple GEMM units"
dict set ::block_props pblock_mxu_slr2 IS_SOFT true
rejects {::vortex::mxu_slr::check_placed} {*requires IS_SOFT=false*}

fixture
set second [add_second_unit]
set rx $::root/g_slr_mxu_weight_rx.payload_q_reg\[0\]
set tx $second/g_slr_mxu_weight_tx.payload_q_reg\[0\]
dict set ::nets $rx/D [list $tx/Q $rx/D]
rejects {::vortex::mxu_slr::apply post_init} {*not directly driven*}

fixture
set missing $::root/g_slr_mxu_weight_rx.payload_q_reg\[0\]
set ::primitives [lsearch -all -inline -not -exact $::primitives $missing]
rejects {::vortex::mxu_slr::apply post_init} {*Missing MXU placement group*}

fixture
cell design/gnd GND
set rx $::root/g_slr_mxu_input_rx.control_q_reg\[7\]
cell $rx FDRE 1
dict set ::nets $rx/D [list design/gnd/G $rx/D]
dict set ::nets $::root/u_mxu/ifmap_i\[0\] [list design/gnd/G $::root/u_mxu/mul_reg/D design/unrelated/D]
::vortex::mxu_slr::apply post_init
set report [open post_init_mxu_slr_links.tsv r]
set report_text [read $report]
close $report
assert_equal [string match {*# constant*} $report_text] 1 "constant-folded metadata"

fixture
dict set ::props $::root/g_slr_mxu_input_tx.data_q_reg\[0\] USER_SLL_REG 0
rejects {::vortex::mxu_slr::apply post_init} {*not a marked fabric FF*}

fixture
set rx $::root/g_slr_mxu_weight_rx.payload_q_reg\[0\]
cell design/gating_lut LUT2
dict set ::nets $rx/D [list design/gating_lut/O $rx/D]
rejects {::vortex::mxu_slr::apply post_init} {*not directly driven*}

fixture
set rx $::root/g_slr_mxu_input_rx.control_q_reg\[0\]
set tx $::root/g_slr_mxu_input_tx.control_q_reg\[0\]
dict set ::nets $rx/D [list $tx/Q $rx/D $::root/g_local_prealign_blk_idx.data_q_reg\[0\]/D]
rejects {::vortex::mxu_slr::apply post_init} {*nonexclusive fanout*}

fixture
set rx $::root/g_slr_mxu_weight_rx.payload_q_reg\[0\]
set tx $::root/g_slr_mxu_input_tx.control_q_reg\[0\]
dict set ::nets $rx/D [list $tx/Q $rx/D]
rejects {::vortex::mxu_slr::apply post_init} {*not directly driven*}

fixture
dict set ::nets $::root/u_mxu/ifmap_i\[0\] [list design/u_dma_engine/dma_reg/Q $::root/u_mxu/mul_reg/D]
rejects {::vortex::mxu_slr::apply post_init} {*bypasses the SLR2 transport*}

fixture
::vortex::mxu_slr::apply post_init
rejects {::vortex::mxu_slr::apply post_init} {*Stale MXU pblock*}
dict set ::props $::root/u_mxu/mul_reg PBLOCK pblock_dma_conflict
rejects {::vortex::mxu_slr::apply post_opt} {*Conflicting pblock*}

# The actual hook must still run ownership validation with congestion off.
fixture
::vortex::mxu_slr::apply post_init
set ::env(VORTEX_CONGESTION_FAIL_FAST) 0
source [file join $xrt_dir post_place_hook.tcl]
dict set ::props $::root/u_mxu/mul_reg SLR SLR1
rejects {source [file join $xrt_dir post_place_hook.tcl]} {*wrong SLR*}
puts "PASSED: $checks MXU floorplan checks; reports in $out_dir"
