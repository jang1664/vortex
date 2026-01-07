# Include Vortex configuration
ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl

# Force use of gcc-11/g++-11 for C++20 features
export CC := /usr/bin/gcc-11
export CXX := /usr/bin/g++-11

TOP_MODULE := tb_VX_prealigner

setup:
	mkdir -p logs reports

compile: setup
	verilator -Wall --binary --trace-fst -Wno-fatal \
		-MAKEFLAGS "CXX=$(CXX) CC=$(CC)" \
		-I$(RTL_DIR) -I$(RTL_DIR)/libs \
		+define+SIMULATION \
		--top-module $(TOP_MODULE) \
		tb_VX_prealigner.sv \
		$(RTL_DIR)/core/gemm/VX_prealigner.sv \
		$(RTL_DIR)/core/gemm/VX_compare.sv \
		$(RTL_DIR)/core/gemm/VX_hidden.sv \
		$(RTL_DIR)/core/gemm/VX_shifter.sv \
		$(RTL_DIR)/libs/VX_find_first.sv \
		$(RTL_DIR)/libs/VX_lzc.sv \
		-pvalue+NUM_UNIT=4 \
		2>&1 | tee logs/build.log

sim: compile
	./obj_dir/V$(TOP_MODULE) 2>&1 | tee logs/sim.log

clean:
	rm -rf obj_dir reports logs