set ip_dir [file normalize [file join [pwd] ip]]
file mkdir $ip_dir
set_property target_language Verilog [current_project]
proc ensure_floating_point_ip {ip_dir module_name} {
    create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name $module_name -dir $ip_dir
}
ensure_floating_point_ip ${ip_dir} xil_f16mul_latency1
set_property -dict [list \
  CONFIG.A_Precision_Type {Half} \
  CONFIG.C_A_Exponent_Width {5} \
  CONFIG.C_A_Fraction_Width {11} \
  CONFIG.C_Accum_Input_Msb {15} \
  CONFIG.C_Accum_Lsb {-24} \
  CONFIG.C_Accum_Msb {32} \
  CONFIG.Maximum_Latency {false} \
  CONFIG.C_Latency {1} \
  CONFIG.C_Mult_Usage {Full_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {5} \
  CONFIG.C_Result_Fraction_Width {11} \
  CONFIG.Has_ACLKEN {true} \
  CONFIG.Has_ARESETn {true} \
  CONFIG.Operation_Type {Multiply} \
  CONFIG.Result_Precision_Type {Half} \
] [get_ips xil_f16mul_latency1]

ensure_floating_point_ip ${ip_dir} xil_f32mul_latency1
set_property -dict [list \
  CONFIG.A_Precision_Type {Single} \
  CONFIG.C_A_Exponent_Width {8} \
  CONFIG.C_A_Fraction_Width {24} \
  CONFIG.Maximum_Latency {false} \
  CONFIG.C_Latency {1} \
  CONFIG.C_Mult_Usage {Full_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {8} \
  CONFIG.C_Result_Fraction_Width {24} \
  CONFIG.Has_ACLKEN {true} \
  CONFIG.Has_ARESETn {true} \
  CONFIG.Operation_Type {Multiply} \
  CONFIG.Result_Precision_Type {Single} \
] [get_ips xil_f32mul_latency1]

ensure_floating_point_ip ${ip_dir} xil_f32add_latency1
set_property -dict [list \
  CONFIG.Add_Sub_Value {Add} \
  CONFIG.A_Precision_Type {Single} \
  CONFIG.C_A_Exponent_Width {8} \
  CONFIG.C_A_Fraction_Width {24} \
  CONFIG.Maximum_Latency {false} \
  CONFIG.C_Latency {1} \
  CONFIG.C_Optimization {Low_Latency} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {8} \
  CONFIG.C_Result_Fraction_Width {24} \
  CONFIG.Has_ACLKEN {true} \
  CONFIG.Has_ARESETn {true} \
  CONFIG.Operation_Type {Add_Subtract} \
  CONFIG.Result_Precision_Type {Single} \
] [get_ips xil_f32add_latency1]

# Scalar Zfh IPs.  These names are intentionally distinct from the tensor/GEMM
# half-precision add/multiply IPs above because their latency and interface
# contracts belong to the scalar FPU.

set_property generate_synth_checkpoint false [get_files *.xci]
generate_target all [get_ips]
