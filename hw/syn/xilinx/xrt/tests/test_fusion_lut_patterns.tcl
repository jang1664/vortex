# Focused placement-pattern regression; no Vivado or RTL simulation.
set ::vortex_slr_definitions_only 1
source [file join [file dirname [info script]] .. floorplan.tcl]
set checks 0
proc expect_owner {name ref expected {sinks {}}} {
    incr ::checks
    set actual [::vortex::slr::fusion_lut_owner $name $ref $sinks]
    if {$actual ne $expected} {error "$name ($ref): expected '$expected', got '$actual'"}
}
set bank_prefix {mem_unit/local_mem/g_req_hier_valid.req_xbar/g_multi_inputs.g_multiple_outputs.g_xbar_arbs}
# All six observed misplaced bank LUTs, plus other bank/suffix spellings.
foreach bank {0 2 3 14 15} {
    set destination [format {%s[%d].xbar_arb/g_input_select.g_fanout.g_slice_arbs[1].fanout_slice_arb/g_buffer.valid_out_r_reg} $bank_prefix $bank]
    set local_destination [string map {{g_slice_arbs[1]} {g_slice_arbs[0]}} $destination]
    set join [format {%s[%d].xbar_arb/g_input_select.g_fanout.fanout_join_arb/g_buffer.valid_out_r_reg} $bank_prefix $bank]
    foreach direction {in out} {
        set name [format {%s[%d].xbar_arb/g_buffer.valid_%s_r_i_1__0} $bank_prefix $bank $direction]
        expect_owner $name LUT4 2 [list $destination]
        expect_owner $name LUT4 1 [list $join]
        expect_owner $name LUT4 1 [list $local_destination]
        expect_owner [string map {. /} $name] LUT4 1 [list [string map {. /} $local_destination]]
        expect_owner [string map {. /} $name] LUT5 2 [list [string map {. /} $destination]]
        expect_owner "${name}_replica_2" LUT4 2 [list $destination]
        expect_owner $name FDRE {}
    }
}
foreach suffix {2 3 12__0 1_replica_2} {
    expect_owner "mem_unit/g_lmem_switches\[0\].lmem_switch/u_fusion_busy_export_i_$suffix" LUT2 0
    expect_owner "mem_unit/g_lmem_switches\[0\]/lmem_switch/u_fusion_busy_export_i_$suffix" LUT2 0
}
foreach name [list \
    [format {%s[16].xbar_arb/g_buffer.valid_in_r_i_1} $bank_prefix] \
    [format {%s[2].xbar_arb/g_buffer.data_out_r_i_1} $bank_prefix] \
    [format {%s[2].xbar_arb/g_input_select.g_fanout.fanout_join_arb/g_buffer.valid_in_r_i_1} $bank_prefix] \
    {mem_unit/g_lmem_switches[0].lmem_switch/ordinary_valid_i_2} \
    {mem_unit/g_lmem_switches[0].lmem_switch/child/u_fusion_busy_export_i_2}] {
    expect_owner $name LUT4 {}
}
# Lifted leaves stay individually constrained; do not anchor the shared parent.
set core top/core
set leaf "$core/mem_unit/g_lmem_switches\[0\].lmem_switch/u_fusion_busy_export_i_2"
set record [dict create core $core owner 0 sinks {}]
set result [::vortex::slr::select_homogeneous_anchors \
    {top/core/gemm_node} {top/core} [list $leaf] [list [file dirname $leaf]] {LUT2} \
    [dict create $leaf 0] {top/core/gemm_node} {} {} {} [dict create $leaf $record]]
if {[dict size [dict get $result covered]] != 0} {error "lifted LUT incorrectly anchored shared hierarchy"}
incr checks
puts "PASS: $checks fusion LUT placement-pattern checks"
