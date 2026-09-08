ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk
PROJECT := reference_gemm_phase
TASK_DIR := $(VORTEX_HOME)/agent-tasks/u55c-hbm-performance-calibration
SRC_DIR := $(TASK_DIR)/gemm_phase
SRCS := $(SRC_DIR)/phase_host.cpp
VX_SRCS := $(TASK_DIR)/phase_diag/phase_kernel.cpp
CXXFLAGS += -I$(VORTEX_HOME)/tests/regression/fpint_gemm_ffn_hw -I$(TASK_DIR)/phase_diag
VX_CFLAGS += -I$(VORTEX_HOME)/tests/regression/fpint_gemm_ffn_hw -I$(TASK_DIR)/phase_diag
STARTUP_ADDR := 0x80000000
include ../common.mk
