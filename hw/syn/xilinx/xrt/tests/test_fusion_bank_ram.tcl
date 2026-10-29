# Conditional pure fixture; reuses all metadata assertions and test helpers.
# Parent verifier runs after assembling the staged source in an isolated tree.
# argv[0] is that tree's candidate floorplan.tcl, as in the metadata fixture.
source [file join [file dirname [info script]] test_fusion_bank_metadata.tcl]
set ram_checks_before $checks
set rams [dict create]
for {set bank 0} {$bank < 16} {incr bank} {
    for {set lane 0} {$lane < 8} {incr lane} {
        for {set depth 0} {$depth < 2} {incr depth} {
            set relative [format {mem_unit/local_mem/g_data_store[%d].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_%d_bram_%d} $bank $lane $depth]
            set identity [::vortex::slr::fusion_ram_identity $relative RAMB36E2]
            dict set rams "$core/$relative" [dict merge $identity [dict create core $core]]
        }
    }
}
::vortex::slr::validate_fusion_rams $rams [list $core]
require [expr {[dict size $rams] == 256}] "256 exact RAM leaves"
set first_ram [lindex [dict keys $rams] 0]
set missing_rams $rams;dict unset missing_rams $first_ram
rejects {::vortex::slr::validate_fusion_rams $missing_rams [list $core]} {*missing C4 bank RAM*}
set duplicate_rams $rams
set ram_alias [string map {]. ]/} $first_ram]
dict set duplicate_rams $ram_alias [dict get $rams $first_ram]
rejects {::vortex::slr::validate_fusion_rams $duplicate_rams [list $core]} {*duplicate bank RAM slot*}
foreach pair {
    {{mem_unit/local_mem/g_data_store[16].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_0_bram_0} RAMB36E2}
    {{mem_unit/local_mem/g_data_store[0].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_8_bram_0} RAMB36E2}
    {{mem_unit/local_mem/g_data_store[0].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_0_bram_2} RAMB36E2}
    {{mem_unit/local_mem/g_data_store[0].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_0_bram_0} RAMB18E2}
    {{mem_unit/local_mem/g_data_store[0].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_0_bram_0} FDRE}
    {{mem_unit/local_mem/g_data_store[0].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_0_bram_0} LUT2}
    {{mem_unit/local_mem/g_data_store[01].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_0_bram_0} RAMB36E2}
    {{mem_unit/local_mem/g_data_store[0].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_00_bram_0} RAMB36E2}
    {{mem_unit/local_mem/g_data_store[0].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_0_bram_00} RAMB36E2}
    {{mem_unit/local_mem/g_data_store[0].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_0_bram_0_replica} RAMB36E2}
    {{mem_unit/local_mem/g_data_store[0].lmem_store/unknown_storage_alias} RAMB36E2}
} {
    lassign $pair relative ref
    rejects {::vortex::slr::fusion_ram_identity $relative $ref} {*bank RAM*}
}
require [expr {[::vortex::slr::fusion_ram_identity {mem_unit/local_mem/g_data_store[0].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_7_bram_0_i_1} LUT2] eq {}}] "ordinary storage LUT remains unowned"
require [expr {[::vortex::slr::fusion_ram_identity {mem_unit/local_mem/g_data_store[0].last_wr_valid_reg} FDRE] eq {}}] "RAM class cannot consume metadata"
require [expr {[::vortex::slr::fusion_support_spec {mem_unit/local_mem/g_data_store[0].lmem_store/g_sync.g_bram.g_read_first.g_wren.ram_reg_0_bram_0}] eq {}}] "RAM does not become retained support hierarchy"
::vortex::slr::validate_fusion_rams {} {}
rejects {::vortex::slr::validate_fusion_rams {} [list $core]} {*missing C4 bank RAM*}
rejects {::vortex::slr::validate_fusion_rams $rams {other/core}} {*outside detected fusion core*}
set wrong_record $rams
dict set wrong_record $first_ram core other/core
rejects {::vortex::slr::validate_fusion_rams $wrong_record [list $core]} {*outside detected fusion core*}
set wrong_owner $rams;dict set wrong_owner $first_ram owner 2
rejects {::vortex::slr::validate_fusion_rams $wrong_owner [list $core]} {*inconsistent bank RAM identity*}
# Extend the existing metadata anchor fixture; shared RAM is still unowned.
set ram_names $names;set ram_parents $parents;set ram_refs $refs;set ram_owners $owners
foreach name [dict keys $rams] {
    lappend ram_names $name;lappend ram_parents [file dirname $name];lappend ram_refs RAMB36E2;dict set ram_owners $name 1
}
set combined [::vortex::slr::select_homogeneous_anchors [list $root $child] [list $core $root] $ram_names $ram_parents $ram_refs $ram_owners [list $root] {} $metadata $rams]
require [expr {[dict get $combined groups 1] eq [list $child]}] "RAM placement cannot anchor shared storage parents"
require [expr {[llength [dict get $combined uncovered]] == 480 && [dict size [dict get $combined covered]] == 1}] "224 metadata and256 RAMs remain exact primitive owners"
rejects {::vortex::slr::select_homogeneous_anchors [list $root $child] [list $core $root] $ram_names $ram_parents $ram_refs $ram_owners [list $root] {} $metadata} {*outside retained GEMM hierarchy*}
rejects {::vortex::slr::select_homogeneous_anchors [list $root $child] [list $core $root] $ram_names $ram_parents $ram_refs $ram_owners [list $root] [dict keys $rams] $metadata} {*outside retained GEMM hierarchy*}
set ram_off [::vortex::slr::select_homogeneous_anchors [list $root $child] [list $core $root] $off_names $off_parents $off_refs $off_owner [list $root] {} {} {}]
require [expr {$ram_off eq $off_old}] "feature-off empty RAM map preserves old anchors"
puts "PASS: conditional RAM ownership checks=[expr {$checks-$ram_checks_before}]; metadata checks retained; no physical acceptance"
