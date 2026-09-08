ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk
PROJECT := reference_gemm_detail
TASK_DIR := $(VORTEX_HOME)/agent-tasks/u55c-hbm-performance-calibration
SRC_DIR := $(TASK_DIR)/gemm_detail
SRCS := $(SRC_DIR)/phase_host.cpp
VX_SRCS := $(SRC_DIR)/phase_kernel.cpp
CXXFLAGS += -I$(VORTEX_HOME)/tests/regression/fpint_gemm_ffn_hw
VX_CFLAGS += -I$(VORTEX_HOME)/tests/regression/fpint_gemm_ffn_hw
STARTUP_ADDR := 0x80000000
include ../common.mk
