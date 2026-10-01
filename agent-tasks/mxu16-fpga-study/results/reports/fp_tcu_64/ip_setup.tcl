set ip_dir [file normalize [file join [pwd] ip]]
file mkdir $ip_dir
set_property target_language Verilog [current_project]
proc ensure_floating_point_ip {ip_dir module_name} {
    create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name $module_name -dir $ip_dir
}
ensure_floating_point_ip ${ip_dir} xil_fmul
set_property -dict [list CONFIG.Operation_Type {Multiply} CONFIG.A_Precision_Type {Single} CONFIG.Result_Precision_Type {Single} CONFIG.Has_RESULT_TREADY {false} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Rate {1} CONFIG.C_Mult_Usage {Full_Usage}] [get_ips xil_fmul]

ensure_floating_point_ip ${ip_dir} xil_fadd
set_property -dict [list CONFIG.Operation_Type {Add_Subtract} CONFIG.A_Precision_Type {Single} CONFIG.Result_Precision_Type {Single} CONFIG.Has_RESULT_TREADY {false} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Rate {1} CONFIG.C_Mult_Usage {Full_Usage}] [get_ips xil_fadd]

# ======================================================================================================
# FIGNA FP IPs
# ======================================================================================================

set_property generate_synth_checkpoint false [get_files *.xci]
generate_target all [get_ips]
