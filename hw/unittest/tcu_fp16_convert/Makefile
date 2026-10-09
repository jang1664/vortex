# Run from a configured build directory; tests the production TCU converter.
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/tcu_fp16_convert
SOFTFLOAT_LIB := $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a
DEFINES := $(patsubst -D%,+define+%,$(CONFIGS)) +define+XLEN_$(XLEN)

.PHONY: compile run
compile:
	mkdir -p logs
	vcs -full64 -sverilog -timescale=1ns/1ps -top tb_tcu_fp16_convert \
		$(DEFINES) +incdir+$(ROOT_DIR)/hw +incdir+$(RTL_DIR) +incdir+$(RTL_DIR)/libs \
		$(RTL_DIR)/tcu/VX_tcu_fedp_dsp.sv $(SRC_DIR)/tb_tcu_fp16_convert.sv \
		$(SRC_DIR)/reference.cpp \
		-CFLAGS "-std=c++17 -I$(THIRD_PARTY_DIR)/softfloat/source/include" \
		-LDFLAGS "-Wl,--whole-archive $(SOFTFLOAT_LIB) -Wl,--no-whole-archive" \
		-o simv -l logs/compile.log

run:
	./simv -l logs/sim.log
	grep -q '^PASSED: TCU FP16 widening' logs/sim.log
