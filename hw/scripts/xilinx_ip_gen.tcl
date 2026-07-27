# Copyright © 2019-2023
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if { $::argc < 1 || $::argc > 2 } {
    puts "ERROR: Program \"$::argv0\" requires 1 or 2 arguments!\n"
    puts "Usage: $::argv0 <ip_dir> [<device_part>]\n"
    exit
}

set ip_dir [lindex $::argv 0]

# create_ip requires that a project is open in memory.
if { $::argc == 2 } {
    set device_part [lindex $::argv 1]
    create_project -in_memory -part $device_part
} else {
    # Create project without specifying a device part
    create_project -in_memory
}

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# IP folder does not exist. Create IP folder
file mkdir ${ip_dir}

proc ensure_floating_point_ip {ip_dir module_name} {
    set xci [file join ${ip_dir} ${module_name} "${module_name}.xci"]
    if {[file exists ${xci}]} {
        read_ip ${xci}
    } else {
        create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name ${module_name} -dir ${ip_dir}
    }
}

ensure_floating_point_ip ${ip_dir} xil_fdiv
set_property -dict [list CONFIG.Component_Name {xil_fdiv} CONFIG.Operation_Type {Divide} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_UNDERFLOW {true} CONFIG.C_Has_OVERFLOW {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.C_Has_DIVIDE_BY_ZERO {true} CONFIG.A_Precision_Type {Single} CONFIG.C_A_Exponent_Width {8} CONFIG.C_A_Fraction_Width {24} CONFIG.Result_Precision_Type {Single} CONFIG.C_Result_Exponent_Width {8} CONFIG.C_Result_Fraction_Width {24} CONFIG.C_Mult_Usage {No_Usage} CONFIG.Has_RESULT_TREADY {false} CONFIG.C_Latency {28} CONFIG.C_Rate {1}] [get_ips xil_fdiv]

ensure_floating_point_ip ${ip_dir} xil_fsqrt
set_property -dict [list CONFIG.Component_Name {xil_fsqrt} CONFIG.Operation_Type {Square_root} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.A_Precision_Type {Single} CONFIG.C_A_Exponent_Width {8} CONFIG.C_A_Fraction_Width {24} CONFIG.Result_Precision_Type {Single} CONFIG.C_Result_Exponent_Width {8} CONFIG.C_Result_Fraction_Width {24} CONFIG.C_Mult_Usage {No_Usage} CONFIG.Has_RESULT_TREADY {false} CONFIG.C_Latency {28} CONFIG.C_Rate {1}] [get_ips xil_fsqrt]

ensure_floating_point_ip ${ip_dir} xil_fma
set_property -dict [list CONFIG.Component_Name {xil_fma} CONFIG.Operation_Type {FMA} CONFIG.Add_Sub_Value {Add} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_UNDERFLOW {true} CONFIG.C_Has_OVERFLOW {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.Has_A_TUSER {false} CONFIG.A_Precision_Type {Single} CONFIG.C_A_Exponent_Width {8} CONFIG.C_A_Fraction_Width {24} CONFIG.Result_Precision_Type {Single} CONFIG.C_Result_Exponent_Width {8} CONFIG.C_Result_Fraction_Width {24} CONFIG.C_Mult_Usage {Medium_Usage} CONFIG.Has_RESULT_TREADY {false} CONFIG.C_Latency {16} CONFIG.C_Rate {1} CONFIG.A_TUSER_Width {1}] [get_ips xil_fma]

ensure_floating_point_ip ${ip_dir} xil_fma_lowL
set_property -dict [list CONFIG.Component_Name {xil_fma_lowL} CONFIG.Operation_Type {FMA} CONFIG.Add_Sub_Value {Add} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_UNDERFLOW {true} CONFIG.C_Has_OVERFLOW {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.Has_A_TUSER {false} CONFIG.A_Precision_Type {Single} CONFIG.C_A_Exponent_Width {8} CONFIG.C_A_Fraction_Width {24} CONFIG.Result_Precision_Type {Single} CONFIG.C_Result_Exponent_Width {8} CONFIG.C_Result_Fraction_Width {24} CONFIG.C_Mult_Usage {Medium_Usage} CONFIG.Has_RESULT_TREADY {false} CONFIG.Maximum_Latency {false} CONFIG.C_Latency {4} CONFIG.C_Rate {1} CONFIG.A_TUSER_Width {1}] [get_ips xil_fma_lowL]

ensure_floating_point_ip ${ip_dir} xil_fmul
set_property -dict [list CONFIG.Operation_Type {Multiply} CONFIG.A_Precision_Type {Single} CONFIG.Result_Precision_Type {Single} CONFIG.Has_RESULT_TREADY {false} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Rate {1} CONFIG.C_Mult_Usage {Full_Usage}] [get_ips xil_fmul]

ensure_floating_point_ip ${ip_dir} xil_fadd
set_property -dict [list CONFIG.Operation_Type {Add_Subtract} CONFIG.A_Precision_Type {Single} CONFIG.Result_Precision_Type {Single} CONFIG.Has_RESULT_TREADY {false} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Rate {1} CONFIG.C_Mult_Usage {Full_Usage}] [get_ips xil_fadd]

# ======================================================================================================
# FIGNA FP IPs
# ======================================================================================================
ensure_floating_point_ip ${ip_dir} xil_f32add
set_property -dict [list \
  CONFIG.Add_Sub_Value {Add} \
  CONFIG.Has_ACLKEN {true} \
  CONFIG.Has_ARESETn {true} \
] [get_ips xil_f32add]

ensure_floating_point_ip ${ip_dir} xil_f32add_lowL
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
] [get_ips xil_f32add_lowL]

ensure_floating_point_ip ${ip_dir} xil_f32mul
set_property -dict [list \
  CONFIG.A_Precision_Type {Single} \
  CONFIG.C_A_Exponent_Width {8} \
  CONFIG.C_A_Fraction_Width {24} \
  CONFIG.C_Latency {9} \
  CONFIG.C_Mult_Usage {Full_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {8} \
  CONFIG.C_Result_Fraction_Width {24} \
  CONFIG.Has_ACLKEN {true} \
  CONFIG.Has_ARESETn {true} \
  CONFIG.Operation_Type {Multiply} \
  CONFIG.Result_Precision_Type {Single} \
] [get_ips xil_f32mul]

ensure_floating_point_ip ${ip_dir} xil_f32mul_low_latency
set_property -dict [list \
  CONFIG.A_Precision_Type {Single} \
  CONFIG.C_A_Exponent_Width {8} \
  CONFIG.C_A_Fraction_Width {24} \
  CONFIG.Maximum_Latency {false} \
  CONFIG.C_Latency {2} \
  CONFIG.C_Mult_Usage {Full_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {8} \
  CONFIG.C_Result_Fraction_Width {24} \
  CONFIG.Has_ACLKEN {true} \
  CONFIG.Has_ARESETn {true} \
  CONFIG.Operation_Type {Multiply} \
  CONFIG.Result_Precision_Type {Single} \
] [get_ips xil_f32mul_low_latency]

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

ensure_floating_point_ip ${ip_dir} xil_f16add
set_property -dict [list \
  CONFIG.Has_ACLKEN {true} \
  CONFIG.Has_ARESETn {true} \
  CONFIG.A_Precision_Type {Half} \
  CONFIG.Add_Sub_Value {Add} \
  CONFIG.C_A_Exponent_Width {5} \
  CONFIG.C_A_Fraction_Width {11} \
  CONFIG.C_Accum_Input_Msb {15} \
  CONFIG.C_Accum_Lsb {-24} \
  CONFIG.C_Accum_Msb {32} \
  CONFIG.C_Latency {12} \
  CONFIG.C_Mult_Usage {Full_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {5} \
  CONFIG.C_Result_Fraction_Width {11} \
  CONFIG.Result_Precision_Type {Half} \
] [get_ips xil_f16add]

ensure_floating_point_ip ${ip_dir} xil_f16mul
set_property -dict [list \
  CONFIG.A_Precision_Type {Half} \
  CONFIG.C_A_Exponent_Width {5} \
  CONFIG.C_A_Fraction_Width {11} \
  CONFIG.C_Accum_Input_Msb {15} \
  CONFIG.C_Accum_Lsb {-24} \
  CONFIG.C_Accum_Msb {32} \
  CONFIG.C_Latency {7} \
  CONFIG.C_Mult_Usage {Full_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {5} \
  CONFIG.C_Result_Fraction_Width {11} \
  CONFIG.Has_ACLKEN {true} \
  CONFIG.Has_ARESETn {true} \
  CONFIG.Operation_Type {Multiply} \
  CONFIG.Result_Precision_Type {Half} \
] [get_ips xil_f16mul]

ensure_floating_point_ip ${ip_dir} xil_f16mul_low_latency
set_property -dict [list \
  CONFIG.A_Precision_Type {Half} \
  CONFIG.C_A_Exponent_Width {5} \
  CONFIG.C_A_Fraction_Width {11} \
  CONFIG.C_Accum_Input_Msb {15} \
  CONFIG.C_Accum_Lsb {-24} \
  CONFIG.C_Accum_Msb {32} \
  CONFIG.Maximum_Latency {false} \
  CONFIG.C_Latency {2} \
  CONFIG.C_Mult_Usage {Full_Usage} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {5} \
  CONFIG.C_Result_Fraction_Width {11} \
  CONFIG.Has_ACLKEN {true} \
  CONFIG.Has_ARESETn {true} \
  CONFIG.Operation_Type {Multiply} \
  CONFIG.Result_Precision_Type {Half} \
] [get_ips xil_f16mul_low_latency]

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

ensure_floating_point_ip ${ip_dir} xil_f32add_low_latency
set_property -dict [list \
  CONFIG.Add_Sub_Value {Add} \
  CONFIG.A_Precision_Type {Single} \
  CONFIG.C_A_Exponent_Width {8} \
  CONFIG.C_A_Fraction_Width {24} \
  CONFIG.Maximum_Latency {false} \
  CONFIG.C_Latency {2} \
  CONFIG.C_Optimization {Low_Latency} \
  CONFIG.C_Rate {1} \
  CONFIG.C_Result_Exponent_Width {8} \
  CONFIG.C_Result_Fraction_Width {24} \
  CONFIG.Has_ACLKEN {true} \
  CONFIG.Has_ARESETn {true} \
  CONFIG.Operation_Type {Add_Subtract} \
  CONFIG.Result_Precision_Type {Single} \
] [get_ips xil_f32add_low_latency]

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
ensure_floating_point_ip ${ip_dir} xil_f16_fma
set_property -dict [list CONFIG.Component_Name {xil_f16_fma} CONFIG.Operation_Type {FMA} CONFIG.Add_Sub_Value {Add} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_UNDERFLOW {true} CONFIG.C_Has_OVERFLOW {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.A_Precision_Type {Half} CONFIG.C_A_Exponent_Width {5} CONFIG.C_A_Fraction_Width {11} CONFIG.Result_Precision_Type {Half} CONFIG.C_Result_Exponent_Width {5} CONFIG.C_Result_Fraction_Width {11} CONFIG.C_Mult_Usage {Medium_Usage} CONFIG.Has_RESULT_TREADY {false} CONFIG.Maximum_Latency {false} CONFIG.C_Latency {4} CONFIG.C_Rate {1}] [get_ips xil_f16_fma]

ensure_floating_point_ip ${ip_dir} xil_f16_div
set_property -dict [list CONFIG.Component_Name {xil_f16_div} CONFIG.Operation_Type {Divide} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_UNDERFLOW {true} CONFIG.C_Has_OVERFLOW {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.C_Has_DIVIDE_BY_ZERO {true} CONFIG.A_Precision_Type {Half} CONFIG.C_A_Exponent_Width {5} CONFIG.C_A_Fraction_Width {11} CONFIG.Result_Precision_Type {Half} CONFIG.C_Result_Exponent_Width {5} CONFIG.C_Result_Fraction_Width {11} CONFIG.C_Mult_Usage {No_Usage} CONFIG.Has_RESULT_TREADY {false} CONFIG.Maximum_Latency {false} CONFIG.C_Latency {15} CONFIG.C_Rate {1}] [get_ips xil_f16_div]

ensure_floating_point_ip ${ip_dir} xil_f16_sqrt
set_property -dict [list CONFIG.Component_Name {xil_f16_sqrt} CONFIG.Operation_Type {Square_root} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.A_Precision_Type {Half} CONFIG.C_A_Exponent_Width {5} CONFIG.C_A_Fraction_Width {11} CONFIG.Result_Precision_Type {Half} CONFIG.C_Result_Exponent_Width {5} CONFIG.C_Result_Fraction_Width {11} CONFIG.C_Mult_Usage {No_Usage} CONFIG.Has_RESULT_TREADY {false} CONFIG.Maximum_Latency {false} CONFIG.C_Latency {15} CONFIG.C_Rate {1}] [get_ips xil_f16_sqrt]

ensure_floating_point_ip ${ip_dir} xil_f16_to_f32
set_property -dict [list CONFIG.Component_Name {xil_f16_to_f32} CONFIG.Operation_Type {Float_to_float} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_UNDERFLOW {true} CONFIG.C_Has_OVERFLOW {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.A_Precision_Type {Half} CONFIG.C_A_Exponent_Width {5} CONFIG.C_A_Fraction_Width {11} CONFIG.Result_Precision_Type {Single} CONFIG.C_Result_Exponent_Width {8} CONFIG.C_Result_Fraction_Width {24} CONFIG.Has_RESULT_TREADY {false} CONFIG.Maximum_Latency {false} CONFIG.C_Latency {2} CONFIG.C_Rate {1}] [get_ips xil_f16_to_f32]

ensure_floating_point_ip ${ip_dir} xil_f32_to_f16
set_property -dict [list CONFIG.Component_Name {xil_f32_to_f16} CONFIG.Operation_Type {Float_to_float} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_UNDERFLOW {true} CONFIG.C_Has_OVERFLOW {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.A_Precision_Type {Single} CONFIG.C_A_Exponent_Width {8} CONFIG.C_A_Fraction_Width {24} CONFIG.Result_Precision_Type {Half} CONFIG.C_Result_Exponent_Width {5} CONFIG.C_Result_Fraction_Width {11} CONFIG.Has_RESULT_TREADY {false} CONFIG.Maximum_Latency {false} CONFIG.C_Latency {3} CONFIG.C_Rate {1}] [get_ips xil_f32_to_f16]

generate_target all [get_ips]

close_project -delete
