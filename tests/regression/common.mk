ROOT_DIR := $(realpath ../../..)

TARGET ?= opaesim

XRT_SYN_DIR ?= $(VORTEX_HOME)/hw/syn/xilinx/xrt
XRT_DEVICE_INDEX ?= 0

VORTEX_RT_PATH ?= $(ROOT_DIR)/runtime
VORTEX_KN_PATH ?= $(ROOT_DIR)/kernel

ifeq ($(XLEN),64)
		ifneq (,$(findstring -DEXT_D_DISABLE,$(CONFIGS)))
			ifeq ($(EXT_V_ENABLE),1)
				VX_CFLAGS += -march=rv64imafv_zve64f -mabi=lp64f # vector extension
			else
				VX_CFLAGS += -march=rv64imaf -mabi=lp64f
			endif
	else
	ifeq ($(EXT_V_ENABLE),1)
		VX_CFLAGS += -march=rv64imafdv_zve64d -mabi=lp64d # vector extension
	else
		VX_CFLAGS += -march=rv64imafd -mabi=lp64d
	endif
	endif
	STARTUP_ADDR ?= 0x180000000
else
	ifeq ($(EXT_V_ENABLE),1)
		VX_CFLAGS += -march=rv32imafv_zve32f -mabi=ilp32f # vector extension
	else
		VX_CFLAGS += -march=rv32imaf -mabi=ilp32f
	endif
	STARTUP_ADDR ?= 0x80000000
endif

LLVM_CFLAGS += --sysroot=$(RISCV_SYSROOT)
LLVM_CFLAGS += --gcc-toolchain=$(RISCV_TOOLCHAIN_PATH)
LLVM_CFLAGS += -Xclang -target-feature -Xclang +vortex
LLVM_CFLAGS += -Xclang -target-feature -Xclang +zicond
LLVM_CFLAGS += -mllvm -disable-loop-idiom-all # disable memset/memcpy loop idiom
#LLVM_CFLAGS += -mllvm -vortex-branch-divergence=0
#LLVM_CFLAGS += -mllvm -debug -mllvm -print-after-all
#LLVM_CFLAGS += -I$(RISCV_SYSROOT)/include/c++/9.2.0/$(RISCV_PREFIX)
#LLVM_CFLAGS += -I$(RISCV_SYSROOT)/include/c++/9.2.0
#LLVM_CFLAGS += -Wl,-L$(RISCV_TOOLCHAIN_PATH)/lib/gcc/$(RISCV_PREFIX)/9.2.0
#LLVM_CFLAGS += --rtlib=libgcc

VX_CC  = $(LLVM_VORTEX)/bin/clang $(LLVM_CFLAGS)
VX_CXX = $(LLVM_VORTEX)/bin/clang++ $(LLVM_CFLAGS)
VX_DP  = $(LLVM_VORTEX)/bin/llvm-objdump
VX_CP  = $(LLVM_VORTEX)/bin/llvm-objcopy

#VX_CC  = $(RISCV_TOOLCHAIN_PATH)/bin/$(RISCV_PREFIX)-gcc
#VX_CXX = $(RISCV_TOOLCHAIN_PATH)/bin/$(RISCV_PREFIX)-g++
#VX_DP  = $(RISCV_TOOLCHAIN_PATH)/bin/$(RISCV_PREFIX)-objdump
#VX_CP  = $(RISCV_TOOLCHAIN_PATH)/bin/$(RISCV_PREFIX)-objcopy

VX_CFLAGS += -O3 -mcmodel=medany -fno-rtti -fno-exceptions -nostartfiles -nostdlib -fdata-sections -ffunction-sections
VX_CFLAGS += -I$(VORTEX_HOME)/kernel/include -I$(ROOT_DIR)/hw -I$(SW_COMMON_DIR)
VX_CFLAGS += -DXLEN_$(XLEN)
VX_CFLAGS += -DNDEBUG
VX_CFLAGS += $(CONFIGS)

VX_LIBS += -L$(LIBC_VORTEX)/lib -lm -lc

VX_LIBS += $(LIBCRT_VORTEX)/lib/baremetal/libclang_rt.builtins-riscv$(XLEN).a
#VX_LIBS += -lgcc

VX_LDFLAGS += -Wl,-Bstatic,--gc-sections,-T,$(VORTEX_HOME)/kernel/scripts/link$(XLEN).ld,--defsym=STARTUP_ADDR=$(STARTUP_ADDR) $(VORTEX_KN_PATH)/libvortex.a $(VX_LIBS)

CXXFLAGS += -std=c++17 -Wall -Wextra -pedantic -Wfatal-errors
CXXFLAGS += -I$(VORTEX_HOME)/runtime/include -I$(ROOT_DIR)/hw -I$(SW_COMMON_DIR)
CXXFLAGS += -DXLEN_$(XLEN)
CXXFLAGS += $(CONFIGS)

LDFLAGS += -L$(VORTEX_RT_PATH) -lvortex

# Debugging
ifdef DEBUG
	CXXFLAGS += -g -O0
else
	CXXFLAGS += -O2 -DNDEBUG
endif

ifeq ($(TARGET), fpga)
	OPAE_DRV_PATHS ?= libopae-c.so
else
ifeq ($(TARGET), asesim)
	OPAE_DRV_PATHS ?= libopae-c-ase.so
else
ifeq ($(TARGET), opaesim)
	OPAE_DRV_PATHS ?= libopae-c-sim.so
endif
endif
endif

all: $(PROJECT) kernel.vxbin kernel.dump

KERNEL_CONFIG_FILE := .kernel.flags.stamp

kernel.dump: kernel.elf
	$(VX_DP) -D $< > $@

kernel.vxbin: kernel.elf
	OBJCOPY=$(VX_CP) $(VORTEX_HOME)/kernel/scripts/vxbin.py $< $@

$(KERNEL_CONFIG_FILE): force
	@printf '%s\n' "$(VX_CFLAGS) $(VX_LDFLAGS)" > $@.tmp
	@if ! cmp -s $@.tmp $@; then \
	  mv $@.tmp $@; \
	else \
	  rm $@.tmp; \
	fi

kernel.elf: $(VX_SRCS) $(KERNEL_CONFIG_FILE)
	$(VX_CXX) $(VX_CFLAGS) $(VX_SRCS) $(VX_LDFLAGS) -o kernel.elf

$(PROJECT): $(SRCS)
	$(CXX) $(CXXFLAGS) $^ $(LDFLAGS) -o $@

run-simx: $(PROJECT) kernel.vxbin
	LD_LIBRARY_PATH=$(VORTEX_RT_PATH):$(LD_LIBRARY_PATH) VORTEX_DRIVER=simx ./$(PROJECT) $(OPTS)

run-rtlsim: $(PROJECT) kernel.vxbin
	LD_LIBRARY_PATH=$(VORTEX_RT_PATH):$(LD_LIBRARY_PATH) VORTEX_DRIVER=rtlsim ./$(PROJECT) $(OPTS)

run-opae: $(PROJECT) kernel.vxbin
	SCOPE_JSON_PATH=$(VORTEX_RT_PATH)/scope.json OPAE_DRV_PATHS=$(OPAE_DRV_PATHS) LD_LIBRARY_PATH=$(VORTEX_RT_PATH):$(LD_LIBRARY_PATH) VORTEX_DRIVER=opae ./$(PROJECT) $(OPTS)

VCS_SIMLIB_DIR ?= $(VORTEX_HOME)/build/vcs_simlib
# Collect every per-library subdir under VCS_SIMLIB_DIR (each holds one lib*.so).
VCS_SIMLIB_LD_PATH := $(shell ls -d $(VCS_SIMLIB_DIR)/*/ 2>/dev/null | sed 's|/$$||' | tr '\n' ':' | sed 's|:$$||')
# /usr/lib/x86_64-linux-gnu is prepended so simv picks up the system libstdc++
# (gcc-13) which has newer GLIBCXX symbols needed by system libprotobuf.so.32;
# the vg_gnu-bundled libstdc++ on simv's DT_RUNPATH is too old otherwise.
HW_EMU_LD_PATHS := /usr/lib/x86_64-linux-gnu:$(XILINX_XRT)/lib:$(XILINX_VIVADO)/lib/lnx64.o:$(VCS_SIMLIB_LD_PATH):$(VORTEX_RT_PATH):$(LD_LIBRARY_PATH)
# Vitis propagates xrt.ini's [Emulation] user_pre_sim_script to simv via the
# USER_PRE_SIM_SCRIPT env var for xsim, but NOT for VCS. Extract the path from
# the colocated xrt.ini and pass it through ourselves. VITIS_LAUNCH_WAVEFORM_BATCH
# enables the user_post_sim_script hook inside simulate.do too.
HW_EMU_PRE_SIM_SCRIPT := $(shell awk -F= '/^user_pre_sim_script/ {print $$2}' $(FPGA_BIN_DIR)/xrt.ini 2>/dev/null)
HW_EMU_ENV := $(if $(HW_EMU_PRE_SIM_SCRIPT),USER_PRE_SIM_SCRIPT=$(HW_EMU_PRE_SIM_SCRIPT)) VITIS_LAUNCH_WAVEFORM_BATCH=1

run-xrt: $(PROJECT) kernel.vxbin
ifeq ($(TARGET), hw)
	SCOPE_JSON_PATH=$(FPGA_BIN_DIR)/scope.json XRT_INI_PATH=$(VORTEX_RT_PATH)/xrt/xrt.ini EMCONFIG_PATH=$(FPGA_BIN_DIR) XRT_DEVICE_INDEX=$(XRT_DEVICE_INDEX) XRT_XCLBIN_PATH=$(FPGA_BIN_DIR)/vortex_afu.xclbin LD_LIBRARY_PATH=$(XILINX_XRT)/lib:$(VORTEX_RT_PATH):$(LD_LIBRARY_PATH) VORTEX_DRIVER=xrt ./$(PROJECT) $(OPTS)
else ifeq ($(TARGET), hw_emu)
	SCOPE_JSON_PATH=$(FPGA_BIN_DIR)/scope.json XCL_EMULATION_MODE=$(TARGET) XRT_INI_PATH=$(if $(wildcard $(FPGA_BIN_DIR)/xrt.ini),$(FPGA_BIN_DIR)/xrt.ini,$(VORTEX_RT_PATH)/xrt/xrt.ini) EMCONFIG_PATH=$(FPGA_BIN_DIR) XRT_DEVICE_INDEX=$(XRT_DEVICE_INDEX) XRT_XCLBIN_PATH=$(FPGA_BIN_DIR)/vortex_afu.xclbin LD_LIBRARY_PATH=$(HW_EMU_LD_PATHS) $(HW_EMU_ENV) VORTEX_DRIVER=xrt ./$(PROJECT) $(OPTS)
else
	SCOPE_JSON_PATH=$(VORTEX_RT_PATH)/scope.json LD_LIBRARY_PATH=$(XILINX_XRT)/lib:$(VORTEX_RT_PATH):$(LD_LIBRARY_PATH) VORTEX_DRIVER=xrt ./$(PROJECT) $(OPTS)
endif

.depend: $(SRCS)
	$(CXX) $(CXXFLAGS) -MM $^ > .depend;

clean-kernel:
	rm -rf *.elf *.vxbin *.dump

clean-host:
	rm -rf $(PROJECT) *.o *.log .depend

clean: clean-kernel clean-host

.PHONY: force
force:

ifneq ($(MAKECMDGOALS),clean)
    -include .depend
endif
