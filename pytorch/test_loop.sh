for i in {1..10}; do
  VORTEX_HOME=/home/jaeyongjang/project.local/vortex \
  VORTEX_DRIVER=xrt \
  FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/bin \
  XILINX_XRT=/opt/xilinx/xrt \
  LD_LIBRARY_PATH=$LD_LIBRARY_PATH:../build/runtime \
  python3 test/test_native_mm.py
done