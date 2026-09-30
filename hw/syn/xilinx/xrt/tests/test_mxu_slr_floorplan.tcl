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
    if {$idx >= 0} {
        set result {}
        foreach pin [lindex $args [expr {$idx+1}]] {lappend result [file dirname $pin]}
        return [lsort -unique $result]
    }
    if {[lsearch -exact $args -hierarchical] >= 0} {return $::primitives}
    set result {}
    foreach name [lindex $args end] {
        if {[dict exists $::props $name] || [dict exists $::ports $name]} {lappend result $name}
    }
    return $result
}
proc get_property {property object} {
    if {[llength $object] > 1} {
        set values {}
        foreach item $object {lappend values [get_property $property $item]}
        return $values
    }
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
    set result {}
    foreach object [lindex $args [expr {$idx+1}]] {
        if {[lsearch -exact $args -leaf] >= 0} {
            lappend result {*}[dict get $::nets $object]
        } elseif {[lsearch -exact $args -filter] >= 0} {
            lappend result $object/D
        } elseif {[dict exists $::ports $object]} {
            lappend result {*}[dict get $::ports $object]
        }
    }
    return [lsort -unique $result]
}
proc get_nets {args} {
    set result {}
    foreach object [lindex $args end] {
        if {[dict exists $::nets $object]} {lappend result $object}
    }
    return [lsort -unique $result]
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
    # Reproduce Vivado 2025.1's EXCLUDE_PLACEMENT setter side effect.
    if {$property eq "EXCLUDE_PLACEMENT" && $value in {false 0}} {
        dict set ::block_props $object IS_SOFT true
    }
}
proc add_cells_to_pblock {block cells} {
    foreach object $cells {
        if {[dict exists $::props $object]} {dict set ::props $object PBLOCK $block}
    }
}
# Match Vivado: a DSP48E2 MACRO contributes no direct cell-to-SLR result.
# Other physical cells in the ownership collection still report their SLRs.
proc get_slrs {args} {
    set result {}
    foreach object [lindex $args end] {
        if {[dict get $::props $object REF_NAME] eq "DSP48E2"} {continue}
        if {[dict exists $::props $object SLR]} {
            set actual [dict get $::props $object SLR]
        } else {
            set actual SLR[lindex [::vortex::mxu_slr::classify $object] 2]
        }
        if {$actual ne ""} {lappend result $actual}
    }
    return [lsort -unique $result]
}
proc report_utilization {args} {}
proc report_timing {args} {}
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
    rejects {::vortex::mxu_slr::check_placed} {*unexpected SLR(s)*}
}

fixture
set tx_lut $::root/g_slr_mxu_weight_tx.payload_q_valid_i_1
set rx_lut $::root/g_slr_mxu_weight_rx.local_reset_i_1
cell $tx_lut LUT5
cell $rx_lut LUT2
::vortex::mxu_slr::apply post_init
::vortex::mxu_slr::apply post_opt
::vortex::mxu_slr::check_placed
assert_equal [dict get $::props $tx_lut PBLOCK] pblock_mxu_slr1 "TX helper placement"
assert_equal [dict get $::props $rx_lut PBLOCK] pblock_mxu_slr2 "RX helper placement"
assert_equal [dict exists $::vortex::mxu_slr::endpoints $tx_lut] 0 "TX helper is not a crossing FF"
assert_equal [dict exists $::vortex::mxu_slr::endpoints $rx_lut] 0 "RX helper is not a crossing FF"
assert_equal [dict size $::vortex::mxu_slr::endpoints] 8 "Only actual FF endpoints counted"
dict set ::props $tx_lut PBLOCK {}
rejects {::vortex::mxu_slr::check_membership 0} {*missing user pblock membership*}
dict set ::props $tx_lut PBLOCK pblock_mxu_slr1
dict set ::props $tx_lut USER_SLL_REG 1
rejects {::vortex::mxu_slr::inventory} {*not a marked fabric FF*}

fixture
set missing $::root/g_slr_mxu_weight_tx.payload_q_reg\[0\]
set ::primitives [lsearch -all -inline -not -exact $::primitives $missing]
cell $::root/g_slr_mxu_weight_tx.payload_q_valid_i_1 LUT5
rejects {::vortex::mxu_slr::inventory} {*Missing MXU placement group*}

fixture
dict lappend ::ports $::root/u_mxu $::root/u_mxu/unused_o
::vortex::mxu_slr::apply post_init
assert_equal [dict size $::vortex::mxu_slr::endpoints] 8 "Unconnected port has no crossing"

fixture
set rx $::root/g_slr_mxu_weight_rx.payload_q_reg\[0\]
set illegal_lut $::root/g_slr_mxu_weight_tx.crossing_i_1
cell $illegal_lut LUT2
dict set ::nets $rx/D [list $illegal_lut/O $rx/D]
rejects {::vortex::mxu_slr::apply post_init} {*not directly driven*}

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
rejects {::vortex::mxu_slr::check_placed} {*expected IS_SOFT=false*}

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
dict set ::nets $::root/u_mxu/ifmap_i\[0\] [list $::root/g_local_prealign_blk_idx.data_q_reg\[0\]/Q $::root/u_mxu/mul_reg/D]
rejects {::vortex::mxu_slr::apply post_init} {*bypasses the SLR2 transport*}

fixture
::vortex::mxu_slr::apply post_init
rejects {::vortex::mxu_slr::apply post_init} {*Stale MXU pblock*}
dict set ::props $::root/u_mxu/mul_reg PBLOCK pblock_dma_conflict
rejects {::vortex::mxu_slr::apply post_opt} {*conflicting user pblock membership*}

# Placement creates reset aliases whose hierarchy pin names are not resetn_i.
# Match the original feat/gemv terminal allowlist, including DSP/RAM controls.
foreach terminal {C CLK CLKA CLKB CLKARDCLK CLKBWRCLK R S CLR PRE RST RSTA RSTB RSTRAMARSTRAM RSTRAMB RSTREGARSTREG RSTREGB} {
    fixture
    set alias $::root/u_mxu/g_relay.reset_r_repN_12_alias
    dict lappend ::ports $::root/u_mxu $alias
    dict set ::nets $alias [list $::root/g_local_prealign_blk_idx.data_q_reg\[0\]/Q $::root/u_mxu/mul_reg/$terminal design/unrelated/$terminal]
    ::vortex::mxu_slr::inventory
    ::vortex::mxu_slr::check_tree_ports
    incr ::checks
}
foreach terminal {D CE I0} {
    fixture
    set alias $::root/u_mxu/g_relay.reset_r_repN_12_alias
    dict lappend ::ports $::root/u_mxu $alias
    # A mixed reset/data net must still fail on its data destination.
    dict set ::nets $alias [list $::root/g_local_prealign_blk_idx.data_q_reg\[0\]/Q $::root/u_mxu/mul_reg/R $::root/u_mxu/mul_reg/$terminal]
    ::vortex::mxu_slr::inventory
    rejects {::vortex::mxu_slr::check_tree_ports} {*bypasses the SLR2 transport*}
}
fixture
set port $::root/u_mxu/ifmap_i\[0\]
dict set ::nets $port [list $::root/u_mxu/mul_reg/Q design/u_dma_engine/dma_reg/D]
::vortex::mxu_slr::inventory
::vortex::mxu_slr::check_tree_ports
set stream [open mxu_slr_external_nets.tsv r]
set external_text [read $stream]; close $stream
assert_equal [string match {*design/u_dma_engine/dma_reg/D*2*unassigned*} $external_text] 1 "external payload is audited as in feat/gemv"
# The spelling of an original clock/reset port is not a blanket exception.
foreach portname {clk_i resetn_i} {
    fixture
    dict set ::nets $::root/u_mxu/$portname [list $::root/g_local_prealign_blk_idx.data_q_reg\[0\]/Q $::root/u_mxu/mul_reg/D]
    ::vortex::mxu_slr::inventory
    rejects {::vortex::mxu_slr::check_tree_ports} {*bypasses the SLR2 transport*}
}
fixture
dict set ::nets $::root/u_mxu/ifmap_i\[0\] [list $::root/u_mxu/mul_reg/D]
::vortex::mxu_slr::inventory
::vortex::mxu_slr::check_tree_ports
set stream [open mxu_slr_external_nets.tsv r]
set external_text [read $stream]; close $stream
assert_equal [string match {*mul_reg/D*unassigned*2*} $external_text] 1 "top-input payload is audited"
fixture
dict set ::nets $::root/u_mxu/clk_i [list $::root/u_mxu/mul_reg/C design/u_dma_engine/dma_reg/C]
::vortex::mxu_slr::inventory
::vortex::mxu_slr::check_tree_ports
incr ::checks
fixture
dict set ::nets $::root/u_mxu/ifmap_i\[0\] [list design/u_dma_engine/dma_reg/Q $::root/u_mxu/mul_reg/Q $::root/u_mxu/mul_reg/D]
::vortex::mxu_slr::inventory
rejects {::vortex::mxu_slr::check_tree_ports} {*multiple leaf drivers*}

# Retain feat/gemv's marked Q->D crossing rule for assigned partitions.
fixture
set port $::root/u_mxu/ifmap_i\[0\]
set tx $::root/g_slr_mxu_input_tx.data_q_reg\[0\]
set rx $::root/g_slr_mxu_input_rx.data_q_reg\[0\]
dict set ::nets $port [list $tx/Q $rx/D]
::vortex::mxu_slr::inventory
::vortex::mxu_slr::check_tree_ports legal_boundary.tsv
incr ::checks
dict set ::props $tx USER_SLL_REG 0
rejects {::vortex::mxu_slr::check_tree_ports} {*bypasses the SLR2 transport*}
# A reset source inside MXU may fan out to a dedicated reset outside MXU.
fixture
dict set ::nets $::root/u_mxu/resetn_i [list $::root/u_mxu/mul_reg/Q design/u_dma_engine/dma_reg/R]
::vortex::mxu_slr::inventory
::vortex::mxu_slr::check_tree_ports
incr ::checks

# The actual hook must still run ownership validation with congestion off.
fixture
::vortex::mxu_slr::apply post_init
set ::env(VORTEX_CONGESTION_FAIL_FAST) 0
source [file join $xrt_dir post_place_hook.tcl]
dict set ::props $::root/u_mxu/mul_reg SLR SLR1
rejects {source [file join $xrt_dir post_place_hook.tcl]} {*unexpected SLR(s)*}
puts "PASSED: $checks MXU floorplan checks; reports in $out_dir"
