# Pure Tcl proposed fixture. Parent verifier runs against candidate source.
# Usage: tclsh test_metadata_ownership.tcl /absolute/path/floorplan.tcl
if {[llength $argv] != 1} {error "expected candidate floorplan.tcl"}
set ::vortex_slr_definitions_only 1
set ::env(VORTEX_GEMM_BACKEND) improve
source [lindex $argv 0]
set checks 0
proc require {value description} {
    if {!$value} {error $description}
    incr ::checks
}
proc rejects {script pattern} {
    set code [catch {uplevel 1 $script} message]
    require [expr {$code == 1 && [string match $pattern $message]}] "expected error $pattern; got $code/$message"
}
set core top/core
set metadata [dict create]
for {set bank 0} {$bank < 16} {incr bank} {
    foreach bit {-1 0 1 2 3 4 5 6 7 8 9 10 11 12} {
        set tail [expr {$bit == -1 ? "last_wr_valid_reg" : [format {last_wr_addr_reg[%d]} $bit]}]
        set relative [format {mem_unit/local_mem/g_data_store[%d].%s} $bank $tail]
        set record [::vortex::slr::fusion_metadata_identity $relative FDRE]
        dict set metadata "$core/$relative" [dict merge $record [dict create core $core]]
    }
}
::vortex::slr::validate_fusion_metadata $metadata [list $core]
require [expr {[dict size $metadata] == 224}] "224 exact state leaves"
set first [lindex [dict keys $metadata] 0]
set missing $metadata; dict unset missing $first
rejects {::vortex::slr::validate_fusion_metadata $missing [list $core]} {*missing C4*}
set duplicate $metadata
set alias [string map {]. ]/} $first]
dict set duplicate $alias [dict get $metadata $first]
rejects {::vortex::slr::validate_fusion_metadata $duplicate [list $core]} {*duplicate bank metadata slot*}
foreach pair {
    {{mem_unit/local_mem/g_data_store[16].last_wr_valid_reg} FDRE}
    {{mem_unit/local_mem/g_data_store[0].last_wr_addr_reg[13]} FDRE}
    {{mem_unit/local_mem/g_data_store[0].last_wr_addr_reg[1]} FDSE}
    {{mem_unit/local_mem/g_data_store[0].last_wr_valid_reg} LUT2}
    {{mem_unit/local_mem/g_data_store[01].last_wr_valid_reg} FDRE}
    {{mem_unit/local_mem/g_data_store[0].last_wr_addr_reg[01]} FDRE}
    {{mem_unit/local_mem/g_data_store[0].last_wr_valid_reg_replica} FDRE}
    {{mem_unit/local_mem/g_data_store[0].last_wr_addr_renamed} FDRE}
} {
    lassign $pair relative ref
    rejects {::vortex::slr::fusion_metadata_identity $relative $ref} {*metadata*}
}
require [expr {[::vortex::slr::fusion_metadata_identity {mem_unit/local_mem/g_data_store[0].last_wr_valid_i_1} LUT2] eq {}}] "do not own arbitrary LUT"
require [expr {[::vortex::slr::fusion_metadata_identity {mem_unit/local_mem/g_data_store[0].lmem_store/ram_reg} RAMB36E2] eq {}}] "do not own RAM"
::vortex::slr::validate_fusion_metadata {} {}
rejects {::vortex::slr::validate_fusion_metadata {} [list $core]} {*missing C4*}
rejects {::vortex::slr::validate_fusion_metadata $metadata {other/core}} {*outside detected fusion core*}
set root $core/gemm_node
set child $root/u_local
set local_leaf $child/logic
set shared $core/mem_unit/local_mem/storage
set names [concat [list $local_leaf] [dict keys $metadata] [list $shared]]
set parents [list $child]; set refs [list LUT2]; set owners [dict create $local_leaf 1]
foreach name [dict keys $metadata] {
    lappend parents "$core/mem_unit/local_mem"; lappend refs FDRE; dict set owners $name 1
}
lappend parents "$core/mem_unit/local_mem"; lappend refs RAMB36E2
set result [::vortex::slr::select_homogeneous_anchors [list $root $child] [list $core $root] $names $parents $refs $owners [list $root] {} $metadata]
require [expr {[dict get $result groups 1] eq [list $child]}] "anchor only existing local hierarchy"
require [expr {[llength [dict get $result uncovered]] == 224}] "metadata is primitive-owned, never a shared-parent anchor"
require [expr {[dict size [dict get $result covered]] == 1}] "no RAM inheritance"
rejects {::vortex::slr::select_homogeneous_anchors [list $root $child] [list $core $root] $names $parents $refs $owners [list $root]} {*outside retained GEMM hierarchy*}
rejects {::vortex::slr::select_homogeneous_anchors [list $root $child] [list $core $root] $names $parents $refs $owners [list $root] [dict keys $metadata]} {*outside retained GEMM hierarchy*}
set off_names [list $local_leaf $shared]
set off_parents [list $child "$core/mem_unit/local_mem"]
set off_refs [list LUT2 RAMB36E2]
set off_owner [dict create $local_leaf 1]
set off_old [::vortex::slr::select_homogeneous_anchors [list $root $child] [list $core $root] $off_names $off_parents $off_refs $off_owner [list $root]]
set off_new [::vortex::slr::select_homogeneous_anchors [list $root $child] [list $core $root] $off_names $off_parents $off_refs $off_owner [list $root] {} {}]
require [expr {$off_old eq $off_new}] "feature-off empty metadata preserves anchor result"
puts "PASS: C4 metadata ownership fixture, $checks checks"
