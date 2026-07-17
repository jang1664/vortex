#!/bin/bash
export DISPLAY=:1

CWD=$(pwd)

bin_path=$1 
csv_path=${2:-${CWD}/build/util.csv}
vivado -mode gui -nolog -nojournal -notrace \
  -source hw/syn/xilinx/xrt/export_photo.tcl \
  -tclargs ${bin_path}/_x/link/vivado/vpl/prj/prj.xpr impl_1 $csv_path