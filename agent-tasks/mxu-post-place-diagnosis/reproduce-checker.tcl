open_checkpoint ../agent-tasks/mxu-post-place-diagnosis/dsp-probe-placed.dcp
source ../hw/syn/xilinx/xrt/mxu_slr_floorplan.tcl
set c [get_cells product]
set ::vortex::mxu_slr::cells [dict create product $c]
set ::vortex::mxu_slr::owners [dict create product 2]
foreach owner {1 2} {
 create_pblock pblock_mxu_slr$owner
 resize_pblock [get_pblocks pblock_mxu_slr$owner] -add SLR$owner
}
add_cells_to_pblock [get_pblocks pblock_mxu_slr2] $c
foreach owner {1 2} {
 foreach property {EXCLUDE_PLACEMENT CONTAIN_ROUTING IS_SOFT} {
  set_property $property false [get_pblocks pblock_mxu_slr$owner]
 }
}
set failed [catch {::vortex::mxu_slr::check_membership 1} message]
puts "REPRO old_checker_failed=$failed message=$message"
if {!$failed || ![string match {*wrong SLR*} $message]} {error "Expected old checker failure"}
set sites [get_sites -of_objects [get_cells product]]
set actual [get_slrs -of_objects $sites]
puts "REPRO sites=$sites actual=$actual expected=SLR2"
if {[llength $sites] != 1 || $actual ne "SLR2"} {error "Wrong physical placement"}
puts "PASS: existing checker rejects a DSP physically placed in SLR2"
exit
