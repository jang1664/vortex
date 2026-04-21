ROOT_DIR := $(realpath ../../..)

TARGET ?= opaesim

XRT_SYN_DIR ?= $(VORTEX_HOME)/hw/syn/xilinx/xrt
XRT_DEVICE_INDEX ?= 0

STARTUP_ADDR ?= 0x80000000

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
	POCL_CC_FLAGS += POCL_VORTEX_XLEN=64
else
	ifeq ($(EXT_V_ENABLE),1)
		VX_CFLAGS += -march=rv32imafv_zve32f -mabi=ilp32f # vector extension
	else
		VX_CFLAGS += -march=rv32imaf -mabi=ilp32f
	endif
	POCL_CC_FLAGS += POCL_VORTEX_XLEN=32
endif

VORTEX_RT_PATH ?= $(ROOT_DIR)/runtime
VORTEX_KN_PATH ?= $(ROOT_DIR)/kernel

POCL_PATH ?= $(TOOLDIR)/pocl

LLVM_POCL ?= $(TOOLDIR)/llvm-vortex

VX_LIBS += -L$(LIBC_VORTEX)/lib -lm -lc

VX_LIBS += $(LIBCRT_VORTEX)/lib/baremetal/libclang_rt.builtins-riscv$(XLEN).a
#VX_LIBS += -lgcc

VX_CFLAGS  += -O3 -mcmodel=medany --sysroot=$(RISCV_SYSROOT) --gcc-toolchain=$(RISCV_TOOLCHAIN_PATH)
VX_CFLAGS  += -fno-rtti -fno-exceptions -nostartfiles -nostdlib -fdata-sections -ffunction-sections
VX_CFLAGS  += -I$(ROOT_DIR)/hw -I$(VORTEX_HOME)/kernel/include -DXLEN_$(XLEN) -DNDEBUG $(CONFIGS)
VX_CFLAGS  += -Xclang -target-feature -Xclang +vortex
VX_CFLAGS  += -Xclang -target-feature -Xclang +zicond
VX_CFLAGS  += -mllvm -disable-loop-idiom-all	# disable memset/memcpy loop replacement
#VX_CFLAGS += -mllvm -vortex-branch-divergence=0
#VX_CFLAGS += -mllvm -debug -mllvm -print-after-all

VX_LDFLAGS += -Wl,-Bstatic,--gc-sections,-T$(VORTEX_HOME)/kernel/scripts/link$(XLEN).ld,--defsym=STARTUP_ADDR=$(STARTUP_ADDR) $(VORTEX_KN_PATH)/libvortex.a $(VX_LIBS)

VX_BINTOOL += OBJCOPY=$(LLVM_VORTEX)/bin/llvm-objcopy $(VORTEX_HOME)/kernel/scripts/vxbin.py

CXXFLAGS += -std=c++17 -Wall -Wextra -Wfatal-errors
CXXFLAGS += -Wno-deprecated-declarations -Wno-unused-parameter -Wno-narrowing
CXXFLAGS += -pthread
CXXFLAGS += -I$(POCL_PATH)/include
CXXFLAGS += $(CONFIGS)

POCL_CC_FLAGS += LLVM_PREFIX=$(LLVM_VORTEX) POCL_VORTEX_BINTOOL="$(VX_BINTOOL)" POCL_VORTEX_CFLAGS="$(VX_CFLAGS)" POCL_VORTEX_LDFLAGS="$(VX_LDFLAGS)"

# Debugging
ifdef DEBUG
	CXXFLAGS += -g -O0
	POCL_CC_FLAGS += POCL_DEBUG=all
else
	CXXFLAGS += -O2 -DNDEBUG
endif

LDFLAGS += -Wl,-rpath,$(LLVM_VORTEX)/lib

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

OBJS := $(addsuffix .o, $(notdir $(SRCS)))

all: $(PROJECT)

%.cc.o: $(SRC_DIR)/%.cc
	$(CXX) $(CXXFLAGS) -c $< -o $@

%.cpp.o: $(SRC_DIR)/%.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

%.c.o: $(SRC_DIR)/%.c
	$(CC) $(CXXFLAGS) -c $< -o $@

$(PROJECT): $(OBJS)
	$(CXX) $(CXXFLAGS) $(OBJS) $(LDFLAGS) -L$(VORTEX_RT_PATH) -lvortex -L$(POCL_PATH)/lib -lOpenCL -o $@

$(PROJECT).host: $(OBJS)
	$(CXX) $(CXXFLAGS) $(OBJS) $(LDFLAGS) -lOpenCL -o $@

run-gpu: $(PROJECT).host $(KERNEL_SRCS)
	./$(PROJECT).host $(OPTS)

run-simx: $(PROJECT) $(KERNEL_SRCS)
	LD_LIBRARY_PATH=$(POCL_PATH)/lib:$(VORTEX_RT_PATH):$(LLVM_VORTEX)/lib:$(LD_LIBRARY_PATH) $(POCL_CC_FLAGS) VORTEX_DRIVER=simx ./$(PROJECT) $(OPTS)

run-rtlsim: $(PROJECT) $(KERNEL_SRCS)
	LD_LIBRARY_PATH=$(POCL_PATH)/lib:$(VORTEX_RT_PATH):$(LLVM_VORTEX)/lib:$(LD_LIBRARY_PATH) $(POCL_CC_FLAGS) VORTEX_DRIVER=rtlsim ./$(PROJECT) $(OPTS)

run-opae: $(PROJECT) $(KERNEL_SRCS)
	SCOPE_JSON_PATH=$(VORTEX_RT_PATH)/scope.json OPAE_DRV_PATHS=$(OPAE_DRV_PATHS) LD_LIBRARY_PATH=$(POCL_PATH)/lib:$(VORTEX_RT_PATH):$(LLVM_VORTEX)/lib:$(LD_LIBRARY_PATH) $(POCL_CC_FLAGS) VORTEX_DRIVER=opae ./$(PROJECT) $(OPTS)

VCS_SIMLIB_DIR ?= $(VORTEX_HOME)/build/vcs_simlib
VCS_SIMLIB_LD_PATH := $(shell ls -d $(VCS_SIMLIB_DIR)/*/ 2>/dev/null | sed 's|/$$||' | tr '\n' ':' | sed 's|:$$||')
# /usr/lib/x86_64-linux-gnu is prepended so simv picks up the system libstdc++
# (gcc-13) which has newer GLIBCXX symbols needed by system libprotobuf.so.32;
# the vg_gnu-bundled libstdc++ on simv's DT_RUNPATH is too old otherwise.
HW_EMU_LD_PATHS := /usr/lib/x86_64-linux-gnu:$(XILINX_XRT)/lib:$(XILINX_VIVADO)/lib/lnx64.o:$(VCS_SIMLIB_LD_PATH):$(POCL_PATH)/lib:$(VORTEX_RT_PATH):$(LLVM_VORTEX)/lib:$(LD_LIBRARY_PATH)
# Vitis propagates xrt.ini's [Emulation] user_pre_sim_script to simv via the
# USER_PRE_SIM_SCRIPT env var for xsim, but NOT for VCS. Pass it manually.
HW_EMU_PRE_SIM_SCRIPT := $(shell awk -F= '/^user_pre_sim_script/ {print $$2}' $(FPGA_BIN_DIR)/xrt.ini 2>/dev/null)
HW_EMU_ENV := $(if $(HW_EMU_PRE_SIM_SCRIPT),USER_PRE_SIM_SCRIPT=$(HW_EMU_PRE_SIM_SCRIPT)) VITIS_LAUNCH_WAVEFORM_BATCH=1

run-xrt: $(PROJECT) $(KERNEL_SRCS)
ifeq ($(TARGET), hw)
	SCOPE_JSON_PATH=$(FPGA_BIN_DIR)/scope.json XRT_INI_PATH=$(VORTEX_RT_PATH)/xrt/xrt.ini EMCONFIG_PATH=$(FPGA_BIN_DIR) XRT_DEVICE_INDEX=$(XRT_DEVICE_INDEX) XRT_XCLBIN_PATH=$(FPGA_BIN_DIR)/vortex_afu.xclbin LD_LIBRARY_PATH=$(XILINX_XRT)/lib:$(POCL_PATH)/lib:$(VORTEX_RT_PATH):$(LLVM_VORTEX)/lib:$(LD_LIBRARY_PATH) $(POCL_CC_FLAGS) VORTEX_DRIVER=xrt ./$(PROJECT) $(OPTS)
else ifeq ($(TARGET), hw_emu)
	SCOPE_JSON_PATH=$(FPGA_BIN_DIR)/scope.json XCL_EMULATION_MODE=$(TARGET) XRT_INI_PATH=$(if $(wildcard $(FPGA_BIN_DIR)/xrt.ini),$(FPGA_BIN_DIR)/xrt.ini,$(VORTEX_RT_PATH)/xrt/xrt.ini) EMCONFIG_PATH=$(FPGA_BIN_DIR) XRT_DEVICE_INDEX=$(XRT_DEVICE_INDEX) XRT_XCLBIN_PATH=$(FPGA_BIN_DIR)/vortex_afu.xclbin LD_LIBRARY_PATH=$(HW_EMU_LD_PATHS) $(HW_EMU_ENV) $(POCL_CC_FLAGS) VORTEX_DRIVER=xrt ./$(PROJECT) $(OPTS)
else
	SCOPE_JSON_PATH=$(VORTEX_RT_PATH)/scope.json LD_LIBRARY_PATH=$(XILINX_XRT)/lib:$(POCL_PATH)/lib:$(VORTEX_RT_PATH):$(LLVM_VORTEX)/lib:$(LD_LIBRARY_PATH) $(POCL_CC_FLAGS) VORTEX_DRIVER=xrt ./$(PROJECT) $(OPTS)
endif

.depend: $(SRCS)
	$(CXX) $(CXXFLAGS) -MM $^ > .depend;

clean-kernel:
	rm -rf *.dump *.ll

clean-host:
	rm -rf $(PROJECT) $(PROJECT).host *.o *.log .depend

clean: clean-kernel clean-host

ifneq ($(MAKECMDGOALS),clean)
    -include .depend
endif
