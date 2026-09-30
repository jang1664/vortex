set_param general.maxThreads 4
open_checkpoint {/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/th32_c1_improve_m32_tcol32_pnr_slrfix_20260930_023759_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_opt.dcp}
set target {level0_i/ulp/vortex_afu_1/inst/afu_wrap/vortex_axi/vortex/g_clusters[0].cluster/g_sockets[0].socket/g_cores[0].core/gemm_node/u_VX_gemm_unit/u_mxu/tile_col[0].gen_col_zero.u_pe/product[0][0]}
set c [get_cells -quiet [list $target]]
puts "DIAG target_count=[llength $c]"
report_property $c
puts "DIAG cells-in-target=[get_cells -quiet -of_objects $c]"
puts "DIAG slrs=[get_slrs -quiet -of_objects $c]"
puts "DIAG children=[get_cells -hier -filter {NAME =~ *u_mxu/tile_col[0].gen_col_zero.u_pe/product[0][0]/*}]"
exit
