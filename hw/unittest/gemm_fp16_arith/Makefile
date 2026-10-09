# Run from a configured build's hw/unittest/gemm_fp16_arith directory.
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

.DEFAULT_GOAL := compile
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
ifneq ($(SIM_EXEC),vcs)
$(error This test requires mixed-language VCS and the actual Xilinx multiplier IP)
endif

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_fp16_arith
DESTDIR := $(CURDIR)
XILINX_IP_DIR ?= $(ROOT_DIR)/sim/xrtsim_vcs/xilinx_ip
include $(VORTEX_HOME)/sim/xrtsim_vcs/xilinx_fpu_vcs.mk
XILINX_FPU_IPS := xil_f16mul xil_f16mul_low_latency xil_f16mul_latency1

RTL_PKGS := $(RTL_DIR)/VX_gpu_pkg.sv
RTL_SRCS := $(RTL_DIR)/core/gemm/VX_stream_intf.sv
RTL_SRCS += $(RTL_DIR)/core/gemm/VX_fp16_mul.sv $(RTL_DIR)/core/gemm/VX_f32_to_f16.sv
SOFTFLOAT_LIB := $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a
INCDIRS := $(ROOT_DIR)/hw $(RTL_DIR) $(RTL_DIR)/fpu $(RTL_DIR)/libs $(RTL_DIR)/core/gemm
VLOGAN_FLAGS := -full64 -sverilog -timescale=1ns/1ps
VLOGAN_FLAGS += $(foreach dir,$(INCDIRS),+incdir+$(dir))
VLOGAN_FLAGS += -y $(RTL_DIR)/libs -y $(RTL_DIR)/core/gemm +libext+.sv+.v
VLOGAN_FLAGS += $(patsubst -D%,+define+%,$(CONFIGS)) +define+XLEN_$(XLEN) +define+SIMULATION

.PHONY: compile run
compile: $(XILINX_IP_VHDLAN_STAMP)
	mkdir -p logs
	vlogan $(VLOGAN_FLAGS) $(RTL_PKGS) $(RTL_SRCS) $(SRC_DIR)/tb_gemm_fp16_arith.sv -l logs/compile.log
	vcs -full64 -timescale=1ns/1ps $(XILINX_FPU_VCS_LIB_FLAGS) tb_gemm_fp16_arith_cfg \
		$(SRC_DIR)/softfloat_reference.cpp \
		-CFLAGS "-std=c++17 -I$(THIRD_PARTY_DIR)/softfloat/source/include" \
		-LDFLAGS "-Wl,--whole-archive $(SOFTFLOAT_LIB) -Wl,--no-whole-archive" -o simv -l logs/compile.log

run:
	./simv $(EXTRA_SIM_ARGS) -l logs/sim.log
