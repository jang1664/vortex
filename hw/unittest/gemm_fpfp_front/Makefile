# Run from a configured build directory after sourcing a naive FPFP config.
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

.DEFAULT_GOAL := compile
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
ifneq ($(SIM_EXEC),vcs)
$(error This test requires mixed-language VCS and actual Xilinx FP32 IP)
endif
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_fpfp_front
DESTDIR := $(CURDIR)
XILINX_IP_DIR ?= $(ROOT_DIR)/sim/xrtsim_vcs/xilinx_ip
include $(VORTEX_HOME)/sim/xrtsim_vcs/xilinx_fpu_vcs.mk
XILINX_FPU_IPS := xil_f32mul_latency1 xil_f32add_latency1
INCDIRS := $(ROOT_DIR)/hw $(RTL_DIR) $(RTL_DIR)/fpu $(RTL_DIR)/libs $(RTL_DIR)/core/gemm
VLOGAN_FLAGS := -full64 -sverilog -timescale=1ns/1ps
VLOGAN_FLAGS += $(foreach dir,$(INCDIRS),+incdir+$(dir))
VLOGAN_FLAGS += -y $(RTL_DIR)/libs -y $(RTL_DIR)/core/gemm +libext+.sv+.v
VLOGAN_FLAGS += $(patsubst -D%,+define+%,$(CONFIGS)) +define+XLEN_$(XLEN)
VLOGAN_FLAGS += +define+SIMULATION +define+VIVADO +define+GEMM_NAIVE_FP16_ENABLE

.PHONY: compile run
compile: $(XILINX_IP_VHDLAN_STAMP)
	mkdir -p logs
	vlogan $(VLOGAN_FLAGS) $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/mem/VX_mem_bus_if.sv \
		$(RTL_DIR)/core/gemm/VX_gemm_fpfp_front.sv $(SRC_DIR)/tb_gemm_fpfp_front.sv -l logs/compile.log
	vcs -full64 -timescale=1ns/1ps $(XILINX_FPU_VCS_LIB_FLAGS) tb_gemm_fpfp_front_cfg \
		-o simv -l logs/elaborate.log

run:
	./simv $(EXTRA_SIM_ARGS) -l logs/sim.log
