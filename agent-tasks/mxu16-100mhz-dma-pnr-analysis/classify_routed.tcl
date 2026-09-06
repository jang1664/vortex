set task_dir "/home/jaeyongjang/project.local/vortex_base/agent-tasks/mxu16-100mhz-dma-pnr-analysis"
set dcp "/home/jaeyongjang/project.local/vortex_base/build/hw/syn/xilinx/xrt/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_postroute_physopt.dcp"

open_checkpoint $dcp

set scopes [dict create \
    gemm_node        {REF_NAME =~ *VX_gemm_node} \
    gemm_ctrl        {REF_NAME =~ *VX_gemm_ctrl} \
    tmem_dma_ctrl    {REF_NAME =~ *VX_gemm_tmem_dma_ctrl} \
    tmem_subsystem   {REF_NAME =~ *VX_tmem_subsystem} \
    hbm_dma_engine   {REF_NAME =~ *VX_dma_engine} \
    dma_pair_adapter {REF_NAME =~ *VX_tmem_dma_pair_adapter*} \
    local_dma        {REF_NAME =~ *VX_lmem_dma_*} \
    tmem_switch      {REF_NAME =~ *VX_tmem_switch* || REF_NAME =~ *VX_tmem_wide_read_switch*} \
    tmem_banks       {REF_NAME =~ *VX_tensor_mem_bank*} \
]

foreach scope [dict keys $scopes] {
    set filter [dict get $scopes $scope]
    set cells [get_cells -hierarchical -quiet -filter $filter]
    puts "REPORT_SCOPE $scope [llength $cells]"
    report_utilization -cells $cells -slr -hierarchical \
        -hierarchical_depth 1 \
        -file "$task_dir/util_${scope}_by_slr.rpt"
}

proc classify_name {name} {
    if {[string first "/gemm_node/u_tmem_subsystem/u_dma_engine/" $name] >= 0} {
        return "hbm_dma_engine"
    }
    if {[string first "/gemm_node/u_tmem_dma_ctrl/" $name] >= 0} {
        return "tmem_dma_ctrl"
    }
    if {[string first "/gemm_node/u_tmem_subsystem/u_ldma_" $name] >= 0} {
        return "local_dma"
    }
    if {[string first "/gemm_node/u_tmem_subsystem/g_dma_tmem_route" $name] >= 0} {
        return "dma_pair_adapter"
    }
    if {[string first "/gemm_node/u_tmem_subsystem/u_switch_" $name] >= 0} {
        return "tmem_switch"
    }
    if {[string first "/gemm_node/u_tmem_subsystem/g_bank" $name] >= 0} {
        return "tmem_banks"
    }
    if {[string first "/gemm_node/u_tmem_subsystem/" $name] >= 0} {
        return "tmem_subsystem_other"
    }
    if {[string first "/gemm_node/u_VX_gemm_ctrl/" $name] >= 0} {
        return "gemm_ctrl"
    }
    if {[string first "/gemm_node/u_VX_gemm_unit_v2/" $name] >= 0} {
        return "gemm_compute"
    }
    if {[string first "/gemm_node/" $name] >= 0} {
        return "gemm_other"
    }
    if {[string first "level0_i/ulp/hmss_0/" $name] == 0} {
        return "hmss"
    }
    if {[string first "level0_i/ulp/vortex_afu_1/" $name] == 0} {
        return "vortex_other"
    }
    return "shell_or_other"
}

set summary [open "$task_dir/failing_path_classification.txt" w]
set paths [get_timing_paths -quiet -delay_type max -slack_lesser_than 0.0 \
    -max_paths 50000 -nworst 1]
puts $summary "failing_paths [llength $paths]"

array set endpoint_counts {}
array set endpoint_worst {}
array set pair_counts {}
array set pair_worst {}
foreach path $paths {
    set endpoint_name [get_property NAME [get_property ENDPOINT_PIN $path]]
    set startpoint_name [get_property NAME [get_property STARTPOINT_PIN $path]]
    set endpoint_class [classify_name $endpoint_name]
    set startpoint_class [classify_name $startpoint_name]
    set slack [get_property SLACK $path]
    if {![info exists endpoint_counts($endpoint_class)]} {
        set endpoint_counts($endpoint_class) 0
        set endpoint_worst($endpoint_class) $slack
    }
    incr endpoint_counts($endpoint_class)
    if {$slack < $endpoint_worst($endpoint_class)} {
        set endpoint_worst($endpoint_class) $slack
    }
    set pair "${startpoint_class}->${endpoint_class}"
    if {![info exists pair_counts($pair)]} {
        set pair_counts($pair) 0
        set pair_worst($pair) $slack
    }
    incr pair_counts($pair)
    if {$slack < $pair_worst($pair)} {
        set pair_worst($pair) $slack
    }
}

puts $summary "\nendpoint_classes"
foreach key [lsort [array names endpoint_counts]] {
    puts $summary "$key count=$endpoint_counts($key) worst_slack=$endpoint_worst($key)"
}
puts $summary "\nstart_to_endpoint_classes"
foreach key [lsort [array names pair_counts]] {
    puts $summary "$key count=$pair_counts($key) worst_slack=$pair_worst($key)"
}
close $summary

close_design
exit
