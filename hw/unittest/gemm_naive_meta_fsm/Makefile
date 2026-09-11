UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_naive_meta_fsm
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
M ?= 4
K ?= 512
N ?= 512
QROW ?= 0
WTRANS ?= 0
MSTART ?= 0
NSTART ?= 0
EXTRA_SIM_ARGS ?=
ifneq ($(SIM_EXEC),vcs)
$(error This test requires VCS)
endif
CONFIG_DEFINES := $(patsubst -D%,+define+%,$(CONFIGS))
.PHONY: setup compile run
setup:
	mkdir -p logs
compile: setup
	vcs -full64 -sverilog -top tb_fsm -timescale=1ns/1ps \
	    -debug_access+all +incdir+$(RTL_DIR) +define+SIMULATION \
	    +define+XLEN_$(XLEN) +define+GEMM_NAIVE $(CONFIG_DEFINES) \
	    $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/core/VX_config_reg_if.sv \
	    $(RTL_DIR)/core/gemm/VX_gemm_fsm_naive_meta.sv \
	    $(SRC_DIR)/tb_fsm.sv -o simv -l logs/compile.log
run:
	./simv +M=$(M) +K=$(K) +N=$(N) +QROW=$(QROW) +WTRANS=$(WTRANS) \
	    +MSTART=$(MSTART) +NSTART=$(NSTART) $(EXTRA_SIM_ARGS) -l logs/sim.log
	python3 $(SRC_DIR)/check_stream.py --trace commands.jsonl --config case.json
