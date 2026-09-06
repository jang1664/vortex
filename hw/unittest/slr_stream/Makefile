UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/slr_stream
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
TB := $(SRC_DIR)/tb_slr_stream.sv
RTLS := $(RTL_DIR)/libs/VX_slr_stream.sv

.PHONY: setup run sim
setup:
	mkdir -p logs
compile: $(TB) $(RTLS) Makefile | setup
	vcs -sverilog -full64 -top tb_slr_stream -timescale=1ns/1ps \
	    +incdir+$(RTL_DIR) +define+SIMULATION+XLEN_64 \
	    $(RTLS) $(TB) -l logs/compile.log
	touch compile
run: compile
	./simv -l logs/sim.log
sim: run
