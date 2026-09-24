override UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
override TOP_MODULE := tb_VX_gemm_acc_lmem
override TB = $(VORTEX_HOME)/hw/unittest/gemm_acc_lmem/tb_VX_gemm_acc_lmem.sv

include ../gemm_unit_v2/Makefile

RTLS += $(RTL_DIR)/core/gemm/VX_gemm_acc_lmem.sv

# The inherited compile prerequisite list is expanded when parsed; retain an
# explicit dependency for this Phase-4 backend.
compile: $(RTL_DIR)/core/gemm/VX_gemm_acc_lmem.sv
