UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
.DEFAULT_GOAL := sim

ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/agen_unit

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs
TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_agen_unit
TB := $(SRC_DIR)/tb_VX_agen_unit.sv

XLEN ?= 64
NUM_WARPS ?= 2
NUM_THREADS ?= 8
SIMD_WIDTH ?= 4
ISSUE_WIDTH ?= 1

TEST ?= all
SEED ?= 1234
RANDOM_ITERS ?= 12
MAX_CYCLES ?= 30000

RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/interfaces/VX_dispatch_if.sv \
        $(RTL_DIR)/interfaces/VX_commit_if.sv \
        $(RTL_DIR)/core/VX_agen_unit.sv

INCDIRS_ := $(VORTEX_HOME)/hw \
            $(RTL_DIR) \
            $(RTL_DIR)/interfaces \
            $(RTL_DIR)/core \
            $(RTL_DIR)/libs

DEFINES_ := SIMULATION XLEN_$(XLEN) EXT_ADDR_GEN_ENABLE \
            NUM_WARPS=$(NUM_WARPS) NUM_THREADS=$(NUM_THREADS) \
            SIMD_WIDTH=$(SIMD_WIDTH) ISSUE_WIDTH=$(ISSUE_WIDTH)

COMPILE_LOG := logs/compile.log
SIM_LOG = logs/sim_$(TEST)_seed$(SEED).log

VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))
empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))
PARAMS :=
SIM_ARGS ?=
SIM_ARGS += +TEST=$(TEST) +RANDOM_ITERS=$(RANDOM_ITERS) +MAX_CYCLES=$(MAX_CYCLES)

setup:
	mkdir -p logs reports

include $(UNITTEST_DIR)/$(SIM_EXEC).mk

.PHONY: setup directed random smoke overpop sim clean

directed:
	$(MAKE) run TEST=directed

random:
	$(MAKE) run TEST=random

smoke:
	$(MAKE) run TEST=smoke

# This target expects the RTL empty-POP assertion and checks its diagnostic.
overpop: TEST=overpop
overpop: MAX_CYCLES=1000
overpop: compile
	@command -v rg >/dev/null || { echo "rg is required to check the diagnostic"; exit 1; }
	-./simv -no_save -reportstats +ntb_random_seed=$(SEED) $(SIM_ARGS) -l $(SIM_LOG)
	@rg -q -F "empty POP timeout" $(SIM_LOG)

clean:
	@command -v trash-put >/dev/null || { \
		echo "trash-put is required for recoverable cleanup"; exit 1; \
	}
	@for path in simv simv.daidir csrc compile ucli.key logs reports; do \
		if [ -e "$$path" ]; then trash-put -- "$$path"; fi; \
	done
