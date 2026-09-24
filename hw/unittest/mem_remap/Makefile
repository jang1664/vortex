UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/mem_remap

SIM_EXEC ?= vlt
TOP_MODULE := tb_VX_mem_remap
TB := $(SRC_DIR)/tb_VX_mem_remap.sv
RTLS := $(RTL_DIR)/core/VX_mem_remap.sv

INCDIRS_ := $(ROOT_DIR)/hw $(RTL_DIR) $(RTL_DIR)/core
VL_INCDIRS := $(foreach dir,$(INCDIRS_),-I$(dir))

DEFINES_ := SIMULATION XLEN_64 PLATFORM_MEMORY_ADDR_WIDTH=34 \
            PLATFORM_MEMORY_NUM_BANKS=32 PLATFORM_MEMORY_INTERLEAVE=1 \
            PLATFORM_MEMORY_REMAP
CONFIG_DEFINES := $(patsubst -D%,%,$(CONFIGS))
DEFINES_ += $(CONFIG_DEFINES)
empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))

setup:
	mkdir -p logs

include $(SIM_EXEC).mk
