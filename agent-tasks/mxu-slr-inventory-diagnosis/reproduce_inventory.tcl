source {/home/jaeyongjang/project.local/vortex_fpint/hw/syn/xilinx/xrt/tests/test_mxu_slr_floorplan.tcl}
fixture
cell $::root/g_slr_mxu_weight_tx.payload_q_valid_i_1 LUT5
set code [catch {::vortex::mxu_slr::inventory} message]
if {$code != 1 || ![string match {*not a marked fabric FF*} $message]} {error "Expected current inventory to reject a local pre-TX LUT"}
puts "REPRODUCED: $message"
