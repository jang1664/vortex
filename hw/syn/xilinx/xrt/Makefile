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
CONGESTION_FAIL_FAST ?= 1

ifneq ($(CONGESTION_FAIL_FAST),0)
ifneq ($(CONGESTION_FAIL_FAST),1)
$(error CONGESTION_FAIL_FAST must be 0 or 1, got '$(CONGESTION_FAIL_FAST)')
endif
endif

PREFIX ?= build$(XLEN)
MAX_JOBS ?= 8
CLOCK_FREQ_HZ ?= 300

# RTL simulator for hw_emu. Default: VCS (Synopsys); set SIMULATOR=xsim for Vivado xsim.
SIMULATOR ?= xsim
# Local VCS installation. Override with env if a different version is preferred.
VCS_INSTALL_DIR ?= /tool/Program/synopsys/vcs/W-2024.09-SP1/bin
# Shared simlib cache — survives across configs, rebuilt only if missing or Vivado version changes.
VCS_SIMLIB_DIR ?= $(VORTEX_HOME)/build/vcs_simlib
# Synopsys vg_gnu bundle. Vivado's generated hw_emu compile.sh sources
#   $VG_GNU_PACKAGE/source_me_gcc920_64.sh
# to pin the GCC/binutils used for SystemC/C++ simlibs. This package ships the
# Ubuntu-aware gcc wrappers (under gcc-X.Y.Z_64-shared/xbin) that resolve the
# multiarch /usr/include/x86_64-linux-gnu/ path problem that vanilla Vivado-bundled
# gcc-9.3.0 cannot handle.
VG_GNU_PACKAGE ?= /tool/Program/synopsys/vcs_gnu/W-2024.09-SP1/linux
# GCC used by both compile_simlib and VCS at simv link time. Must match Vivado's
# precompiled SystemC simmodels at $XILINX_VIVADO/data/simmodels/vcs/<ver>/lnx64/9.2.0/
# (built with gcc-9.2.0). xbin/ is the Ubuntu-safe wrapper that the vg_gnu bundle ships.
VCS_GCC_INSTALL_DIR ?= $(VG_GNU_PACKAGE)/gcc-9.2.0_64-shared/xbin
# Launch Verdi/DVE interactively (opt-in; not coupled to DEBUG).
GUI ?=

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

DEV_ARCH := $(shell platforminfo -p $(PLATFORM) | grep 'FPGA Family' | sed 's/.*://' | sed '/ai_engine/d' | sed 's/^[[:space:]]*//')
CPU_TYPE := $(shell platforminfo -p $(PLATFORM) | grep 'CPU Type' | sed 's/.*://' | sed '/ai_engine/d' | sed 's/^[[:space:]]*//')
DEVICE_PART ?= $(strip $(shell platforminfo -p $(PLATFORM) | sed -n 's/^Board Part:[[:space:]]*//p'))
ifeq ($(DEVICE_PART),)
DEVICE_PART := xcu55c-fsvh2892-2L-e
endif

BUILD_DIR := $(PREFIX)_$(XSA)_$(TARGET)
BIN_DIR := $(BUILD_DIR)/bin
CONFIG_STAMP := $(BUILD_DIR)/.config.stamp
XRT_BACKUP_DIR := $(BUILD_DIR)/xrt_backup
XRT_BACKUP_STAMP := $(XRT_BACKUP_DIR)/.stamp
LINK_CONFIG_STAMP := $(XRT_BACKUP_DIR)/.link_config.stamp
XRT_BACKUP_FILES := $(sort $(SRC_DIR)/Makefile $(wildcard $(SRC_DIR)/*.mk $(SRC_DIR)/*.ini $(SRC_DIR)/*.tcl $(SRC_DIR)/*.in $(SRC_DIR)/*.sh $(SRC_DIR)/*.py))
XRT_RUN_DIR := $(abspath $(XRT_BACKUP_DIR))

CONFIG_FINGERPRINT = TARGET=$(TARGET) PLATFORM=$(PLATFORM) DEVICE_PART=$(DEVICE_PART) CLOCK_FREQ_HZ=$(CLOCK_FREQ_HZ) NUM_CORES=$(NUM_CORES) CONFIGS=$(CONFIGS) DEBUG=$(DEBUG) PERF=$(PERF) PROFILE=$(PROFILE) SCOPE=$(SCOPE) SIMULATOR=$(SIMULATOR) VCS_INSTALL_DIR=$(VCS_INSTALL_DIR) VCS_SIMLIB_DIR=$(VCS_SIMLIB_DIR) VCS_GCC_INSTALL_DIR=$(VCS_GCC_INSTALL_DIR) VG_GNU_PACKAGE=$(VG_GNU_PACKAGE) GUI=$(GUI)
LINK_CONFIG_FINGERPRINT = CONGESTION_FAIL_FAST=$(CONGESTION_FAIL_FAST)

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
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_ISSUE
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_FETCH
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_LSU
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_COMMIT
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_GATHER
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_MEMSCHED
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_GEMM
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_SCHED
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_IBUFFER
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_SCOREBOARD
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_DISPATCH
# DBG_SCOPE_FLAGS += -DDBG_SCOPE_FPU

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
RTL_PKGS = $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/fpu/VX_fpu_pkg.sv $(RTL_DIR)/verification/cf_math_util_pkg.sv $(RTL_DIR)/verification/VX_utils_pkg.sv $(RTL_DIR)/verification/utils.sv
FPU_INCLUDE = -I$(RTL_DIR)/fpu
ifneq (,$(findstring -DFPU_FPNEW, $(CONFIGS)))
	RTL_PKGS += $(RTL_DIR)/fpu/patched_cvfpu/fpnew_pkg.sv $(RTL_DIR)/fpu/patched_cvfpu/fpnew_opgroup_block.sv $(RTL_DIR)/fpu/patched_cvfpu/fpnew_opgroup_multifmt_slice.sv $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/cf_math_pkg $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv
	RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/control_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv
	FPU_INCLUDE += -J$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/include -J$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src -J$(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl -I$(THIRD_PARTY_DIR)/cvfpu/src -I$(RTL_DIR)/fpu/patched_cvfpu
endif
RTL_INCLUDE = -I$(RTL_DIR) -I$(RTL_DIR)/libs -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/core -I$(RTL_DIR)/core/gemm -I$(RTL_DIR)/mem -I$(RTL_DIR)/cache -I$(AFU_DIR)
RTL_INCLUDE += -I$(RTL_DIR)/verification
RTL_INCLUDE += $(FPU_INCLUDE)

# AXI third-party library (for axi_mux, axi_demux in Vortex_axi)
# Use -J so gen_sources.sh emits +incdir+ without pulling .v/.sv files.
# These include dirs only hold .svh files / subdirectories (axi/, common_cells/),
# so no sources are auto-discovered and cvfpu common_cells names are not duplicated.
AXI_DIR := $(THIRD_PARTY_DIR)/axi
AXI_COMMON_CELLS_DIR := $(AXI_DIR)/.bender/git/checkouts/common_cells-3e2fcccecd7aee7b
RTL_INCLUDE += -J$(AXI_DIR)/include
RTL_INCLUDE += -J$(AXI_COMMON_CELLS_DIR)/include

# Specific AXI sources needed by Vortex_axi (axi_mux, axi_demux, AXI_BUS interface).
# Must be listed explicitly: -J on $(AXI_DIR)/src or $(AXI_COMMON_CELLS_DIR)/src
# would pull ~100 files and collide with cvfpu's common_cells (lzc/counter/...).
AXI_SOURCES := $(AXI_DIR)/src/axi_pkg.sv
AXI_SOURCES += $(AXI_DIR)/src/axi_intf.sv
AXI_SOURCES += $(AXI_COMMON_CELLS_DIR)/src/fifo_v3.sv
AXI_SOURCES += $(AXI_COMMON_CELLS_DIR)/src/spill_register.sv
AXI_SOURCES += $(AXI_COMMON_CELLS_DIR)/src/spill_register_flushable.sv
AXI_SOURCES += $(AXI_COMMON_CELLS_DIR)/src/counter.sv
AXI_SOURCES += $(AXI_COMMON_CELLS_DIR)/src/delta_counter.sv
AXI_SOURCES += $(AXI_COMMON_CELLS_DIR)/src/onehot_to_bin.sv
AXI_SOURCES += $(AXI_COMMON_CELLS_DIR)/src/id_queue.sv
AXI_SOURCES += $(AXI_DIR)/src/axi_cut.sv
AXI_SOURCES += $(AXI_DIR)/src/axi_demux_simple.sv
AXI_SOURCES += $(AXI_DIR)/src/axi_demux.sv
AXI_SOURCES += $(AXI_DIR)/src/axi_id_prepend.sv
AXI_SOURCES += $(AXI_DIR)/src/axi_mux.sv

# cf_math_pkg, lzc, rr_arb_tree come from cvfpu when FPU_FPNEW; otherwise pull from axi common_cells.
ifeq (,$(findstring -DFPU_FPNEW, $(CONFIGS)))
AXI_SOURCES := $(AXI_COMMON_CELLS_DIR)/src/cf_math_pkg.sv \
               $(AXI_COMMON_CELLS_DIR)/src/lzc.sv \
               $(AXI_COMMON_CELLS_DIR)/src/rr_arb_tree.sv \
               $(AXI_SOURCES)
endif

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

# VCS hw_emu FSDB dump initializer. The SV file is added to sources.txt so it
# is packaged into the kernel .xo alongside the rest of the RTL. Its
# `bind vortex_afu` statement (guarded by `ifdef VCS_FSDB_DUMP`) activates at
# sim elaboration when gen_vitis_ini.py emits +define+VCS_FSDB_DUMP into vlogan
# (VCS+DEBUG branch). Under synth or non-DEBUG sim the file compiles to an
# empty translation unit.
SIM_FSDB_SOURCES :=
ifeq ($(SIMULATOR)-$(TARGET), vcs-hw_emu)
ifdef DEBUG
SIM_FSDB_SOURCES += $(VORTEX_HOME)/runtime/xrt/vcs_fsdb_init.sv
endif
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
VITIS_INI_ARGS += --simulator $(SIMULATOR)
ifeq ($(CONGESTION_FAIL_FAST),0)
VITIS_INI_ARGS += --disable-congestion-fail-fast
endif
ifeq ($(SIMULATOR), vcs)
VITIS_INI_ARGS += --vcs-install-dir $(VCS_INSTALL_DIR)
VITIS_INI_ARGS += --vcs-simlib-dir $(VCS_SIMLIB_DIR)
VITIS_INI_ARGS += --vcs-gcc-dir $(VCS_GCC_INSTALL_DIR)
endif
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
# 	VPP_FLAGS += -g --optimize 0
	VPP_FLAGS += -g --optimize 3
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
XML_CFLAGS = $(subst -J,-I,$(filter-out -DSYNTHESIS -DVIVADO -DCHIPSCOPE, $(CFLAGS))) $(RTL_PKGS) -I$(DPI_DIR) -DSV_DPI

# RTL Kernel only supports Hardware and Hardware Emulation.
ifneq ($(TARGET),$(findstring $(TARGET), hw hw_emu))
	$(warning WARNING:Application supports only hw hw_emu TARGET. Please use the target for running the application)
endif

.PHONY: all clean gen-sources gen-ast preprocess emconfig check-devices backup-xrt vcs-simlib FORCE_CONFIG_CHECK FORCE_LINK_CONFIG_CHECK
.DEFAULT_GOAL := all

all: check-devices emconfig $(XCLBIN_CONTAINER) $(BIN_DIR)/xrt.ini report

backup-xrt: $(XRT_BACKUP_STAMP)

$(XRT_BACKUP_STAMP): $(XRT_BACKUP_FILES) $(CONFIG_STAMP)
	mkdir -p $(XRT_BACKUP_DIR); \
	for file in $(XRT_BACKUP_FILES); do cp -f $$file $(XRT_BACKUP_DIR)/; done; \
	printf "%s\n" "$(CONFIG_FINGERPRINT)" > $(XRT_BACKUP_DIR)/config_fingerprint.txt; \
	touch $@

gen-sources: $(BUILD_DIR)/sources.txt
$(BUILD_DIR)/sources.txt: $(SRC_DIR)/Makefile $(SRC_DIR)/platforms.mk $(CONFIG_STAMP)
	mkdir -p $(BUILD_DIR); cd $(BUILD_DIR); $(SCRIPT_DIR)/gen_sources.sh -P $(CFLAGS) -Csrc -Osources.txt
	@for src in $(AXI_SOURCES); do echo "$$src" >> $(BUILD_DIR)/sources.txt; done
	@for src in $(SIM_FSDB_SOURCES); do echo "$$src" >> $(BUILD_DIR)/sources.txt; done

$(CONFIG_STAMP): FORCE_CONFIG_CHECK
	mkdir -p $(BUILD_DIR); \
	tmp_file=$@.tmp; \
	printf "%s\n" "$(CONFIG_FINGERPRINT)" > $$tmp_file; \
	if [ ! -f $@ ] || ! cmp -s $$tmp_file $@; then mv $$tmp_file $@; else rm -f $$tmp_file; fi

$(LINK_CONFIG_STAMP): FORCE_LINK_CONFIG_CHECK
	mkdir -p $(XRT_BACKUP_DIR); \
	tmp_file=$@.tmp; \
	printf "%s\n" "$(LINK_CONFIG_FINGERPRINT)" > $$tmp_file; \
	if [ ! -f $@ ] || ! cmp -s $$tmp_file $@; then mv $$tmp_file $@; else rm -f $$tmp_file; fi

gen-ast: $(BUILD_DIR)/vortex.xml
$(BUILD_DIR)/vortex.xml:
	mkdir -p $(BUILD_DIR); cd $(BUILD_DIR); verilator --xml-only -Wno-fatal -O0 $(XML_CFLAGS) vortex_afu.v --xml-output vortex.xml

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
$(XO_CONTAINER): $(BUILD_DIR)/sources.txt $(XRT_BACKUP_STAMP)
	mkdir -p $(BUILD_DIR); cd $(BUILD_DIR);	TOOL_DIR=$(SCRIPT_DIR) $(VIVADO) -mode batch -source $(XRT_RUN_DIR)/gen_xo.tcl -tclargs ../$(XO_CONTAINER) vortex_afu sources.txt ../$(BUILD_DIR) $(DEVICE_PART)

$(VITIS_INI): $(SRC_DIR)/gen_vitis_ini.py $(SRC_DIR)/platforms.mk $(XRT_BACKUP_STAMP) $(LINK_CONFIG_STAMP)
	python3 $(SRC_DIR)/gen_vitis_ini.py $(VITIS_INI_ARGS)

ifeq ($(SIMULATOR)-$(TARGET), vcs-hw_emu)
VCS_SIMLIB_STAMP := $(VCS_SIMLIB_DIR)/synopsys_sim.setup
XCLBIN_DEPS += $(VCS_SIMLIB_STAMP)
# Env for the v++ sub-flow:
#  - PATH: pin vlogan/vcs to the configured VCS install.
#  - VG_GNU_PACKAGE: Vivado's generated compile.sh unconditionally sources
#    "$VG_GNU_PACKAGE/source_me_gcc920_64.sh" to set up the SystemC/C++ toolchain.
#  - VCS_ARCH_OVERRIDE=linux: silences VCS's Ubuntu 24.04 "unsupported OS" warning.
VPP_PATH_PREFIX := PATH=$(VCS_INSTALL_DIR):$$PATH VG_GNU_PACKAGE=$(VG_GNU_PACKAGE) VCS_ARCH_OVERRIDE=linux
else
VPP_PATH_PREFIX :=
endif

vcs-simlib: $(VCS_SIMLIB_STAMP)

$(VCS_SIMLIB_DIR)/synopsys_sim.setup:
	@echo "Compiling Xilinx simulation libraries for VCS (one-time, ~20 min)..."
	@mkdir -p $(VCS_SIMLIB_DIR)
	cd $(VCS_SIMLIB_DIR) && PATH=$(VCS_INSTALL_DIR):$$PATH \
	  $(VIVADO) -mode batch -nolog -nojournal \
	    -source $(VORTEX_HOME)/sim/xrtsim_vcs/compile_vcs_simlib.tcl \
	    -tclargs $(VCS_SIMLIB_DIR) $(VCS_INSTALL_DIR) $(VCS_GCC_INSTALL_DIR) 0 all all

gen-bin: $(XCLBIN_CONTAINER)
$(XCLBIN_CONTAINER): $(XO_CONTAINER) $(SCOPE_JSON) $(VITIS_INI) $(XCLBIN_DEPS)
	mkdir -p $(BIN_DIR); cd $(BUILD_DIR); $(VPP_PATH_PREFIX) TOOL_DIR=$(SCRIPT_DIR) $(VPP) $(VPP_FLAGS) -o ../$(XCLBIN_CONTAINER) ../$(XO_CONTAINER)

# Colocated xrt.ini — simulator-aware. Test Makefiles prefer this over runtime/xrt/xrt.ini.
# Regenerated whenever the config fingerprint changes.
$(BIN_DIR)/xrt.ini: $(CONFIG_STAMP)
	@mkdir -p $(BIN_DIR)
	@{ \
	  echo "[Runtime]"; \
	  echo "runtime_log=./xrt.log"; \
	  echo "verbosity=7"; \
	  echo ""; \
	  echo "[Emulation]"; \
	  if [ -n "$(GUI)" ]; then echo "debug_mode=gui"; else echo "debug_mode=batch"; fi; \
	  if [ "$(SIMULATOR)" = "xsim" ]; then \
	    echo "user_pre_sim_script=$(VORTEX_HOME)/runtime/xrt/xsim.tcl"; \
	  fi; \
	  echo ""; \
	  echo "[Debug]"; \
	  echo "profile=true"; \
	  echo "timeline_trace=true"; \
	  echo "data_transfer_trace=fine"; \
	  echo "device_trace=fine"; \
	} > $@

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
