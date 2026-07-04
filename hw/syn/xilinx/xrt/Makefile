ROOT_DIR := $(realpath ../../../..)
include $(ROOT_DIR)/config.mk

export VORTEX_HOME

ifneq ($(findstring Makefile, $(MAKEFILE_LIST)), Makefile)
help:
	$(ECHO) "Makefile Usage:"
	$(ECHO) "  make all TARGET=<hw/hw_emu> PLATFORM=<FPGA platform>"
	$(ECHO) "      Command to generate the design for specified Target and Device."
	$(ECHO) ""
	$(ECHO) "  make clean"
	$(ECHO) "      Command to remove the generated non-hardware files."
	$(ECHO) ""
endif

TARGET ?= hw
PLATFORM ?=

PREFIX ?= build$(XLEN)
MAX_JOBS ?= 8
CLOCK_FREQ_HZ ?= 300

SRC_DIR := $(VORTEX_HOME)/hw/syn/xilinx/xrt

RTL_DIR := $(VORTEX_HOME)/hw/rtl
DPI_DIR := $(VORTEX_HOME)/hw/dpi
AFU_DIR := $(RTL_DIR)/afu/xrt
SCRIPT_DIR := $(VORTEX_HOME)/hw/scripts

VIVADO := $(XILINX_VIVADO)/bin/vivado
VPP := $(XILINX_VITIS)/bin/v++

CP = cp -rf
RMDIR = rm -rf
ECHO = @echo

NCPUS := $(shell lscpu | grep "^Core(s) per socket:" | awk '{print $$4}')
JOBS ?= $(shell echo $$(( $(NCPUS) > $(MAX_JOBS) ? $(MAX_JOBS) : $(NCPUS) )))

PLATFORM_TO_XSA = $(strip $(patsubst %.xpfm, % , $(shell basename $(PLATFORM))))
XSA := $(call PLATFORM_TO_XSA, $(PLATFORM))

# Resolve short platform name to full .xpfm path to avoid platforminfo duplicate-path bug
PLATFORM_RESOLVED := $(if $(wildcard $(PLATFORM)),$(PLATFORM),$(wildcard /opt/xilinx/platforms/$(PLATFORM)/$(PLATFORM).xpfm))
ifeq ($(PLATFORM_RESOLVED),)
PLATFORM_RESOLVED := $(PLATFORM)
endif

DEV_ARCH := $(shell platforminfo -p $(PLATFORM_RESOLVED) | grep 'FPGA Family' | sed 's/.*://' | sed '/ai_engine/d' | sed 's/^[[:space:]]*//')
CPU_TYPE := $(shell platforminfo -p $(PLATFORM_RESOLVED) | grep 'CPU Type' | sed 's/.*://' | sed '/ai_engine/d' | sed 's/^[[:space:]]*//')
DEVICE_PART ?= $(strip $(shell platforminfo -p $(PLATFORM_RESOLVED) | sed -n 's/^Board Part:[[:space:]]*//p'))
ifeq ($(DEVICE_PART),)
DEVICE_PART := xcu55c-fsvh2892-2L-e
endif

BUILD_DIR := $(PREFIX)_$(XSA)_$(TARGET)
BIN_DIR := $(BUILD_DIR)/bin
CONFIG_STAMP := $(BUILD_DIR)/.config.stamp
XRT_BACKUP_DIR := $(BUILD_DIR)/xrt_backup
XRT_BACKUP_STAMP := $(XRT_BACKUP_DIR)/.stamp
XRT_BACKUP_FILES := $(sort $(SRC_DIR)/Makefile $(wildcard $(SRC_DIR)/*.mk $(SRC_DIR)/*.ini $(SRC_DIR)/*.tcl $(SRC_DIR)/*.in $(SRC_DIR)/*.sh $(SRC_DIR)/*.py))
XRT_RUN_DIR := $(abspath $(XRT_BACKUP_DIR))

CONFIG_FINGERPRINT = TARGET=$(TARGET) PLATFORM=$(PLATFORM) DEVICE_PART=$(DEVICE_PART) CLOCK_FREQ_HZ=$(CLOCK_FREQ_HZ) NUM_CORES=$(NUM_CORES) CONFIGS=$(CONFIGS) DEBUG=$(DEBUG) PERF=$(PERF) PROFILE=$(PROFILE) SCOPE=$(SCOPE)

XO_CONTAINER := $(BIN_DIR)/vortex_afu.xo
XCLBIN_CONTAINER := $(BIN_DIR)/vortex_afu.xclbin

# Control RTL debug tracing states
DBG_TRACE_FLAGS += -DDBG_TRACE_PIPELINE
DBG_TRACE_FLAGS += -DDBG_TRACE_MEM
DBG_TRACE_FLAGS += -DDBG_TRACE_CACHE
DBG_TRACE_FLAGS += -DDBG_TRACE_AFU
DBG_TRACE_FLAGS += -DDBG_TRACE_TEX
DBG_TRACE_FLAGS += -DDBG_TRACE_RASTER
DBG_TRACE_FLAGS += -DDBG_TRACE_OM
DBG_TRACE_FLAGS += -DDBG_TRACE_GBAR
DBG_TRACE_FLAGS += -DDBG_TRACE_TCU
DBG_TRACE_FLAGS += -DDBG_TRACE_GEMM
DBG_TRACE_FLAGS += -DDBG_TRACE_GEMM_FSM
DBG_TRACE_FLAGS += -DDBG_TRACE_GEMM_CTRL

# Control logic analyzer monitors
DBG_SCOPE_FLAGS += -DDBG_SCOPE_AFU
DBG_SCOPE_FLAGS += -DDBG_SCOPE_ISSUE
DBG_SCOPE_FLAGS += -DDBG_SCOPE_FETCH
DBG_SCOPE_FLAGS += -DDBG_SCOPE_LSU
DBG_SCOPE_FLAGS += -DDBG_SCOPE_COMMIT
DBG_SCOPE_FLAGS += -DDBG_SCOPE_GATHER
DBG_SCOPE_FLAGS += -DDBG_SCOPE_MEMSCHED
DBG_SCOPE_FLAGS += -DDBG_SCOPE_GEMM
DBG_SCOPE_FLAGS += -DDBG_SCOPE_SCHED
DBG_SCOPE_FLAGS += -DDBG_SCOPE_IBUFFER
DBG_SCOPE_FLAGS += -DDBG_SCOPE_SCOREBOARD
DBG_SCOPE_FLAGS += -DDBG_SCOPE_DISPATCH
DBG_SCOPE_FLAGS += -DDBG_SCOPE_FPU

ifdef NUM_CORES
# cluster configuration
CONFIGS_1c  := -DNUM_CLUSTERS=1 -DNUM_CORES=1
CONFIGS_2c  := -DNUM_CLUSTERS=1 -DNUM_CORES=2
CONFIGS_4c  := -DNUM_CLUSTERS=1 -DNUM_CORES=4
CONFIGS_8c	:= -DNUM_CLUSTERS=1 -DNUM_CORES=8
CONFIGS_16c	:= -DNUM_CLUSTERS=1 -DNUM_CORES=16
CONFIGS_32c := -DNUM_CLUSTERS=2 -DNUM_CORES=16
CONFIGS_64c := -DNUM_CLUSTERS=4 -DNUM_CORES=16
CONFIGS += $(CONFIGS_$(NUM_CORES)c)
endif

# include sources
RTL_PKGS = $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/fpu/VX_fpu_pkg.sv $(RTL_DIR)/verification/cf_math_util_pkg.sv $(RTL_DIR)/verification/VX_utils_pkg.sv $(RTL_DIR)/verification/utils.sv $(RTL_DIR)/VX_trace_pkg.sv
FPU_INCLUDE = -I$(RTL_DIR)/fpu
ifneq (,$(findstring -DFPU_FPNEW, $(CONFIGS)))
	RTL_PKGS += $(RTL_DIR)/fpu/patched_cvfpu/fpnew_pkg.sv $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/cf_math_pkg $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv
	RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/control_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv
	FPU_INCLUDE += -J$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/include -J$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src -J$(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl -J$(THIRD_PARTY_DIR)/cvfpu/src
endif
RTL_INCLUDE = -I$(RTL_DIR) -I$(RTL_DIR)/libs -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/core -I$(RTL_DIR)/core/gemm -I$(RTL_DIR)/mem -I$(RTL_DIR)/cache -I$(AFU_DIR)
RTL_INCLUDE += -I$(RTL_DIR)/verification
RTL_INCLUDE += $(FPU_INCLUDE)

# Add V extension sources
ifneq (,$(findstring -DEXT_V_ENABLE, $(CONFIGS)))
	RTL_PKGS += $(RTL_DIR)/vpu/VX_vpu_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/vpu
endif

# Add TCU extension sources
ifneq (,$(findstring -DEXT_TCU_ENABLE, $(CONFIGS)))
	RTL_PKGS += $(RTL_DIR)/tcu/VX_tcu_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/tcu
	RTL_INCLUDE += -I$(RTL_DIR)/tcu/bhf
	RTL_INCLUDE += -J$(THIRD_PARTY_DIR)/hardfloat/source/RISCV
	RTL_INCLUDE += -I$(THIRD_PARTY_DIR)/hardfloat/source
endif


# Kernel compiler global settings
VPP_FLAGS += --link --target $(TARGET) --platform $(PLATFORM) --save-temps --no_ip_cache --user_ip_repo_paths /home/data/xilinx_ip/clk_metadata_adapter
VPP_FLAGS += --vivado.synth.jobs $(JOBS) --vivado.impl.jobs $(JOBS)
VPP_FLAGS += --report_level 2

# load platform settings (sets CONFIGS and SP_FLAGS)
include $(SRC_DIR)/platforms.mk

# Generated vitis.ini replaces most --xp, --debug.*, --advanced.*, --profile_kernel flags.
# The script is invoked at build time; see the $(VITIS_INI) recipe below.
VITIS_INI := $(XRT_BACKUP_DIR)/vitis.gen.ini
VPP_FLAGS += --config $(abspath $(VITIS_INI))

# Arguments for gen_vitis_ini.py
VITIS_INI_ARGS  = -o $(abspath $(VITIS_INI))
VITIS_INI_ARGS += --target $(TARGET)
VITIS_INI_ARGS += --hook-dir $(XRT_RUN_DIR)
VITIS_INI_ARGS += --clock-freq $(CLOCK_FREQ_HZ)
ifdef DEBUG
VITIS_INI_ARGS += --debug $(DEBUG)
endif
ifdef PROFILE
VITIS_INI_ARGS += --profile
endif
# Forward per-platform --sp flags
VITIS_INI_ARGS += $(foreach sp,$(SP_FLAGS),--sp $(sp))

# Enable perf counters
ifdef PERF
	CFLAGS += -DPERF_ENABLE
endif

ifeq ($(TARGET), hw_emu)
	CFLAGS += -DSIMULATION -DXSIM
endif

# Debugging — only optimization level and CFLAGS remain here
ifdef DEBUG
# 	VPP_FLAGS += -g --optimize quick
	VPP_FLAGS += -g --optimize 0
	ifeq ($(TARGET), hw)
		CFLAGS += -DNDEBUG -DCHIPSCOPE $(DBG_SCOPE_FLAGS)
	else
		CFLAGS += -DDEBUG_LEVEL=$(DEBUG) $(DBG_TRACE_FLAGS)
	endif
else
# 	VPP_FLAGS += -g --optimize quick
	VPP_FLAGS += --optimize 3
	CFLAGS += -DNDEBUG
endif

# Enable scope analyzer
ifdef SCOPE
	CFLAGS += -DSCOPE $(DBG_SCOPE_FLAGS)
	SCOPE_JSON += $(BIN_DIR)/scope.json
endif

# compilation flags
CFLAGS += -DSYNTHESIS -DVIVADO
CFLAGS += -DXLEN_$(XLEN)
CFLAGS += $(CONFIGS)
CFLAGS += $(RTL_INCLUDE)

# ast dump flags
XML_CFLAGS = $(subst -J,-I,$(filter-out -DSYNTHESIS -DVIVADO, $(CFLAGS))) $(RTL_PKGS) -I$(DPI_DIR) -DSV_DPI

# RTL Kernel only supports Hardware and Hardware Emulation.
ifneq ($(TARGET),$(findstring $(TARGET), hw hw_emu))
	$(warning WARNING:Application supports only hw hw_emu TARGET. Please use the target for running the application)
endif

.PHONY: all clean gen-sources gen-ast preprocess emconfig check-devices backup-xrt force
.DEFAULT_GOAL := all

all: check-devices emconfig $(XCLBIN_CONTAINER) report

backup-xrt: $(XRT_BACKUP_STAMP)

$(XRT_BACKUP_STAMP): $(XRT_BACKUP_FILES) $(CONFIG_STAMP)
	mkdir -p $(XRT_BACKUP_DIR); \
	for file in $(XRT_BACKUP_FILES); do cp -f $$file $(XRT_BACKUP_DIR)/; done; \
	printf "%s\n" "$(CONFIG_FINGERPRINT)" > $(XRT_BACKUP_DIR)/config_fingerprint.txt; \
	touch $@

gen-sources: $(BUILD_DIR)/sources.txt
$(BUILD_DIR)/sources.txt: $(SRC_DIR)/Makefile $(SRC_DIR)/platforms.mk $(CONFIG_STAMP)
	mkdir -p $(BUILD_DIR); cd $(BUILD_DIR); $(SCRIPT_DIR)/gen_sources.sh -P $(CFLAGS) -Csrc -Osources.txt

$(CONFIG_STAMP):
	mkdir -p $(BUILD_DIR); \
	tmp_file=$@.tmp; \
	printf "%s\n" "$(CONFIG_FINGERPRINT)" > $$tmp_file; \
	if [ ! -f $@ ] || ! cmp -s $$tmp_file $@; then mv $$tmp_file $@; else rm -f $$tmp_file; fi

# Xilinx IP and ILA modules that need stubs for Verilator AST generation
STUB_XIL_FP := xil_fdiv xil_fma xil_fsqrt xil_fmul xil_fadd xil_f32add xil_f32mul xil_f16add xil_f16mul
STUB_ILA := ila_afu ila_fetch ila_issue ila_lsu ila_memsched \
            ila_gemm ila_gemm_unit ila_gemm_ctrl ila_gemm_dma_ctrl \
            ila_gemm_sync ila_dma_unit_misal ila_lmem_dma_misal

XILINX_STUBS := $(BUILD_DIR)/xilinx_stubs.sv

$(XILINX_STUBS): force
	@mkdir -p $(BUILD_DIR)
	@echo "// Auto-generated stubs for Verilator AST — do not edit" > $@
	@echo '/* verilator lint_off PINMISSING */' >> $@
	@for mod in $(STUB_XIL_FP); do \
		echo "module $${mod}(" >> $@; \
		echo "  input aclk, input aresetn, input aclken," >> $@; \
		echo "  input [4095:0] s_axis_a_tdata, input s_axis_a_tvalid, output s_axis_a_tready," >> $@; \
		echo "  input [4095:0] s_axis_b_tdata, input s_axis_b_tvalid, output s_axis_b_tready," >> $@; \
		echo "  input [4095:0] s_axis_c_tdata, input s_axis_c_tvalid, output s_axis_c_tready," >> $@; \
		echo "  output [4095:0] m_axis_result_tdata, output m_axis_result_tvalid, input m_axis_result_tready" >> $@; \
		echo "); endmodule" >> $@; \
	done
	@for mod in $(STUB_ILA); do \
		echo "module $${mod}(" >> $@; \
		echo "  input clk," >> $@; \
		echo "  input [4095:0] probe0, input [4095:0] probe1," >> $@; \
		echo "  input [4095:0] probe2, input [4095:0] probe3" >> $@; \
		echo "); endmodule" >> $@; \
	done

ILA_PARAMS := $(BUILD_DIR)/ila_params.tcl

gen-ast: $(ILA_PARAMS)

$(BUILD_DIR)/vortex.xml: $(XILINX_STUBS)
	cd $(BUILD_DIR); verilator --xml-only -Wno-fatal -O0 $(XML_CFLAGS) xilinx_stubs.sv vortex_afu.v --xml-output vortex.xml

$(ILA_PARAMS): $(BUILD_DIR)/vortex.xml
	python3 $(SRC_DIR)/gen_ila_params.py $< -o $@

PREPROCESS_DIR := $(BUILD_DIR)/preprocessed
PREPROCESS_SRCS := $(AFU_DIR)/VX_afu_wrap.sv $(RTL_DIR)/Vortex_axi.sv $(RTL_DIR)/Vortex.sv

preprocess: $(CONFIG_STAMP)
	@mkdir -p $(PREPROCESS_DIR)
	@for src in $(PREPROCESS_SRCS); do \
		base=$$(basename $$src .sv); \
		out=$(PREPROCESS_DIR)/$$base.pp.sv; \
		echo "Preprocessing $$src -> $$out"; \
		verilator -E -P -Wno-fatal $(CFLAGS) $$src > $$out || true; \
	done
	@echo "Generating config dump..."
	@python3 $(SRC_DIR)/gen_config_dump.py $(RTL_DIR)/VX_config.vh -o $(PREPROCESS_DIR)/_config_dump.sv
	@verilator -E -P -Wno-fatal $(CFLAGS) $(PREPROCESS_DIR)/_config_dump.sv > $(PREPROCESS_DIR)/VX_config.pp.sv || true
	$(ECHO) "Preprocessed files in $(PREPROCESS_DIR)/"

scope-json: $(BIN_DIR)/scope.json
$(BIN_DIR)/scope.json: $(BUILD_DIR)/vortex.xml
	mkdir -p $(BUILD_DIR); cd $(BUILD_DIR); $(SCRIPT_DIR)/scope.py vortex.xml -o bin/scope.json

gen-xo: $(XO_CONTAINER)
$(XO_CONTAINER): $(BUILD_DIR)/sources.txt $(XRT_BACKUP_STAMP) $(ILA_PARAMS)
	mkdir -p $(BUILD_DIR); cd $(BUILD_DIR);	TOOL_DIR=$(SCRIPT_DIR) $(VIVADO) -mode batch -source $(XRT_RUN_DIR)/gen_xo.tcl -tclargs ../$(XO_CONTAINER) vortex_afu sources.txt ../$(BUILD_DIR) $(DEVICE_PART)

$(VITIS_INI): $(SRC_DIR)/gen_vitis_ini.py $(XRT_BACKUP_STAMP)
	python3 $(SRC_DIR)/gen_vitis_ini.py $(VITIS_INI_ARGS)

gen-bin: $(XCLBIN_CONTAINER)
$(XCLBIN_CONTAINER): $(XO_CONTAINER) $(SCOPE_JSON) $(VITIS_INI)
	mkdir -p $(BIN_DIR); cd $(BUILD_DIR); TOOL_DIR=$(SCRIPT_DIR) $(VPP) $(VPP_FLAGS) -o ../$(XCLBIN_CONTAINER) ../$(XO_CONTAINER)

emconfig: $(BIN_DIR)/emconfig.json
$(BIN_DIR)/emconfig.json:
	mkdir -p $(BIN_DIR); cd $(BUILD_DIR); emconfigutil --platform $(PLATFORM) --od ../$(BIN_DIR)

report: $(XCLBIN_CONTAINER)
ifeq ($(TARGET), hw)
	-cp $(BUILD_DIR)/_x/logs/link/vivado.log $(BUILD_DIR)/bin
	-cp $(BUILD_DIR)/_x/logs/link/syn/ulp_vortex_afu_1_0_synth_1_runme.log $(BUILD_DIR)/bin
	-cp $(BUILD_DIR)/_x/reports/link/syn/ulp_vortex_afu_1_0_synth_1_ulp_vortex_afu_1_0_utilization_synth.rpt $(BUILD_DIR)/bin
	-cp $(BUILD_DIR)/_x/reports/link/imp/impl_1_hw_bb_locked_utilization_placed.rpt $(BUILD_DIR)/bin
	-cp $(BUILD_DIR)/_x/reports/link/imp/impl_1_hw_bb_locked_timing_summary_routed.rpt $(BUILD_DIR)/bin
	-cp $(BUILD_DIR)/_x/reports/link/imp/impl_1_kernel_util_synthed.rpt $(BUILD_DIR)/bin
	-cp $(BUILD_DIR)/_x/reports/link/imp/impl_1_kernel_util_routed.rpt $(BUILD_DIR)/bin
	-cp $(BUILD_DIR)/_x/reports/link/imp/impl_1_full_util_routed.rpt $(BUILD_DIR)/bin
	-cp $(BUILD_DIR)/_x/link/vivado/vpl/prj/prj.runs/impl_1/hier_utilization.rpt $(BUILD_DIR)/bin
endif

chipscope:
	debug_hw --vivado --host localhost --ltx_file $(BUILD_DIR)/bin/vortex_afu.ltx &

clean:
	$(RMDIR) $(BUILD_DIR)

# Check the devices avaiable
check-devices:
ifndef PLATFORM
	$(error PLATFORM not set. Please set the PLATFORM properly and rerun. Run "make help" for more details.)
endif
ifndef XILINX_VITIS
	$(error XILINX_VITIS variable is not set, please set correctly and rerun)
endif
