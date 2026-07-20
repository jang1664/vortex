open_checkpoint build/hw/syn/xilinx/xrt/improve_th32_tcol32_hwexp_dcache_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/post_place_fail_fast.dcp

set root "level0_i/ulp/vortex_afu_1/inst/afu_wrap/vortex_axi/vortex/g_clusters\[0\].cluster/g_sockets\[0\].socket/g_cores\[0\].core"
set targets [list \
  "$root/issue/g_slices\[0\].issue_slice/dispatch/g_buffers\[0\].buffer" \
  "$root/execute/fpu_unit" \
  "$root/mem_unit/g_lmem_switches\[0\].lmem_switch/req_global_buf" \
  "$root/gemm_node/u_VX_gemm_unit/u_prealigner" \
  "$root/gemm_node/u_VX_gemm_ctrl/u_VX_gemm_fsm" \
  "level0_i/ulp/vortex_afu_1/inst/afu_wrap/vortex_axi/vortex/g_clusters\[0\].cluster/l2cache"]

foreach target $targets {
  puts "TARGET_BEGIN $target"
  set cell [get_cells -quiet $target]
  puts "TARGET_MATCHES [llength $cell]"
  if {[llength $cell] == 1} {
    report_utilization -cells $cell -slr
  }
  puts "TARGET_END $target"
}

close_design
