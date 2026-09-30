set_param general.maxThreads 4
open_checkpoint {/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/th32_c1_improve_m32_tcol32_pnr_slrfix_20260930_023759_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/ulp_vortex_afu_1_0_synth_1/ulp_vortex_afu_1_0.dcp}
set targets [get_cells -hierarchical -regexp {.*mem_unit/g_lmem_lane_dma_arb\[0\]\.lmem_membus_dma_arbiter/g_rsp_select\.rsp_switch/g_out_buf\[0\]\.out_buf/g_eb2\.stream_buffer/g_buffer\.valid_out_r_reg}]
puts "RESET_AUDIT target_count=[llength $targets]"
foreach cell $targets {
 puts "RESET_AUDIT cell=[get_property NAME $cell] ref=[get_property REF_NAME $cell]"
 foreach pin [get_pins -of_objects $cell -filter {DIRECTION == IN}] {
  set terminal [get_property REF_PIN_NAME $pin]
  set nets [get_nets -quiet -segments -of_objects $pin]
  set drivers [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]
  puts "RESET_AUDIT terminal=$terminal nets=$nets drivers=$drivers"
  foreach driver $drivers {
   set source [get_cells -of_objects $driver]
   puts "RESET_AUDIT driver_ref=[get_property REF_NAME $source] driver_pin=[get_property REF_PIN_NAME $driver]"
  }
 }
}
set reset_cells [get_cells -hierarchical -regexp {.*u_mxu/.*g_relay.*reset_r.*}]
puts "RESET_AUDIT mxu_reset_cell_count=[llength $reset_cells]"
foreach cell $reset_cells {
 puts "RESET_AUDIT mxu_reset=[get_property NAME $cell] ref=[get_property REF_NAME $cell]"
}
exit
