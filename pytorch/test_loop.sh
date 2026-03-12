#!/bin/bash
#SBATCH --job-name=vortex_repeat
#SBATCH --gres=fpga:u55c:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=12:00:00
#SBATCH --output=%x_%j.log

for i in {1..10}; do
  VORTEX_HOME=/home/jaeyongjang/project.local/vortex \
  VORTEX_DRIVER=xrt \
  FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/bin \
  XILINX_XRT=/opt/xilinx/xrt \
  LD_LIBRARY_PATH=$LD_LIBRARY_PATH:../build/runtime \
  python3 test/test_native_mm.py
done