set task_dir "/home/jaeyongjang/project.local/vortex_fpint/agent-tasks/diagnose-th16-bigmem-congestion"
set impl_dir "/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1"

open_checkpoint "$impl_dir/level0_wrapper_routed_error.dcp"

report_design_analysis -congestion \
    -file "$task_dir/route_error_congestion.rpt"
report_high_fanout_nets -timing -max_nets 300 \
    -file "$task_dir/route_error_high_fanout.rpt"

set scopes [dict create \
    vortex_axi      "*vortex_axi" \
    gemm_node       "*gemm_node" \
    gemm_ctrl       "*u_VX_gemm_ctrl" \
    compute_core    "*u_compute_core" \
    tmem_subsystem  "*u_tmem_subsystem" \
    tmem_dma_ctrl   "*u_tmem_dma_ctrl" \
    dma_engine      "*u_dma_engine" \
    issue           "*core/issue" \
    dispatch        "*core/issue/dispatch" \
]

foreach scope [dict keys $scopes] {
    set pattern [dict get $scopes $scope]
    set cells [get_cells -hierarchical -quiet -filter "NAME =~ $pattern"]
    if {[llength $cells] == 0} {
        puts "SCOPE_NOT_FOUND $scope $pattern"
        continue
    }
    puts "REPORT_SCOPE $scope [llength $cells]"
    report_utilization -cells $cells -slr -hierarchical \
        -hierarchical_depth 1 \
        -file "$task_dir/util_${scope}_by_slr.rpt"
}

close_design
exit
