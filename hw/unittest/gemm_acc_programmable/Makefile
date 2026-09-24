override UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
override TOP_MODULE := tb_VX_gemm_acc_programmable
override TB = $(VORTEX_HOME)/hw/unittest/gemm_acc_programmable/tb_VX_gemm_acc_programmable.sv

include ../gemm_unit_v2/Makefile

RTLS += $(RTL_DIR)/core/gemm/VX_gemm_acc_programmable.sv

# The parent compile target is parsed before the append above; add the adapter
# explicitly so source changes always invalidate the focused simv.
compile: $(RTL_DIR)/core/gemm/VX_gemm_acc_programmable.sv
