set task_dir "/home/jaeyongjang/project.local/vortex_fpint/agent-tasks/critical-path-th32-tcol32-dcache-try3"
set dcp_path "/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/improve_th32_tcol32_hwexp_dcache_try3_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_routed.dcp"

open_checkpoint $dcp_path
report_design_analysis -congestion -file "$task_dir/pnr_congestion.rpt"
report_design_analysis -complexity -file "$task_dir/pnr_complexity.rpt"

if {[catch {
    report_high_fanout_nets -timing -max_nets 200 -file "$task_dir/pnr_high_fanout.rpt"
} high_fanout_error]} {
    puts "HIGH_FANOUT_REPORT_ERROR: $high_fanout_error"
}

close_design
exit
