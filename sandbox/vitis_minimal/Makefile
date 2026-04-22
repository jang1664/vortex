# sandbox/vitis_minimal Makefile — minimal Vitis hw_emu kernel build that
# reuses Vortex's proven TCL pipeline with only vortex_afu.sv swapped for a
# stub. Built to observe end-to-end how vcs_fsdb_init.sv flows from
# sources.txt → kernel IP → hw_emu vlogan → simv, and where the
# ipx::package_project drop manifests.
#
# Targets:
#   make xo               – produce the kernel .xo only (~1 min). Inspect the
#                           resulting packaged_kernel/component.xml to see
#                           whether vcs_fsdb_init.sv survived packaging.
#   make xo FORCE_FSDB=1  – same, with the force_packaged_sources re-add
#                           enabled in package_kernel_min.tcl.
#   make xclbin           – continue through v++ --link hw_emu (~10 min).
#   make run              – launch the hw_emu simulation and check for FSDB.
#   make clean            – drop the build dir.

SHELL := /bin/bash
.SECONDEXPANSION:

# ---- paths ------------------------------------------------------------------
VORTEX_HOME ?= $(abspath ../..)
SANDBOX     := $(abspath .)
RTL_DIR     := $(SANDBOX)/rtl
SYN_DIR     := $(SANDBOX)/syn
SCRIPT_DIR  := $(SANDBOX)/scripts
HOST_DIR    := $(SANDBOX)/host
BUILD_DIR   := $(SANDBOX)/build
BIN_DIR     := $(BUILD_DIR)/bin

# ---- platform ---------------------------------------------------------------
PLATFORM ?= xilinx_u55c_gen3x16_xdma_3_202210_1
PLATFORM_PATH := $(shell platforminfo --json -p $(PLATFORM) 2>/dev/null | head -1; true)
XSA := $(PLATFORM)
DEV_ARCH := $(shell platforminfo -p $(PLATFORM) 2>/dev/null | grep 'FPGA Family' | sed 's/.*://' | sed 's/^[[:space:]]*//')
DEVICE_PART ?= xcu55c-fsvh2892-2L-e
CLOCK_FREQ_HZ ?= 300

# ---- mode -------------------------------------------------------------------
TARGET    ?= hw_emu
SIMULATOR ?= vcs
DEBUG     ?= 1
FORCE_FSDB ?= 0

# ---- VCS / Verdi env (mirrors Vortex's) ------------------------------------
VCS_INSTALL_DIR  ?= /tool/Program/synopsys/vcs/W-2024.09-SP1/bin
VCS_SIMLIB_DIR   ?= $(VORTEX_HOME)/build/vcs_simlib
VG_GNU_PACKAGE   ?= /tool/Program/synopsys/vcs_gnu/W-2024.09-SP1/linux
VCS_GCC_INSTALL_DIR ?= $(VG_GNU_PACKAGE)/gcc-9.2.0_64-shared/xbin
VERDI_HOME       ?= /tool/Program/synopsys/verdi/W-2024.09-SP1

# ---- platform sp= lines -----------------------------------------------------
CONFIGS :=
include $(SYN_DIR)/platforms.mk

# ---- derived file paths -----------------------------------------------------
XO_CONTAINER     := $(BIN_DIR)/vortex_afu.xo
XCLBIN_CONTAINER := $(BIN_DIR)/vortex_afu.xclbin
VITIS_INI        := $(BUILD_DIR)/vitis.gen.ini
SOURCES_TXT      := $(BUILD_DIR)/sources.txt

VIVADO := $(XILINX_VIVADO)/bin/vivado
VPP    := $(XILINX_VITIS)/bin/v++

# ---- sources.txt ------------------------------------------------------------
# Static 2-file list. The order matters only in that vcs_fsdb_init.sv's bind
# target (vortex_afu) must exist — vortex_afu.sv is compiled first in practice
# by Vivado since it's at the top.
$(SOURCES_TXT): $(RTL_DIR)/vortex_afu.sv $(RTL_DIR)/vcs_fsdb_init.sv
	@mkdir -p $(BUILD_DIR)
	@{ echo "$(RTL_DIR)/vortex_afu.sv"; \
	   echo "$(RTL_DIR)/vcs_fsdb_init.sv"; \
	 } > $@
	@echo "Generated sources.txt:"
	@cat $@ | sed 's/^/  /'

# ---- vitis.gen.ini ----------------------------------------------------------
$(VITIS_INI): $(SYN_DIR)/gen_vitis_ini.py $(SYN_DIR)/platforms.mk
	@mkdir -p $(BUILD_DIR)
	python3 $(SYN_DIR)/gen_vitis_ini.py \
	  -o $@ \
	  --target $(TARGET) \
	  --clock-freq $(CLOCK_FREQ_HZ) \
	  --simulator $(SIMULATOR) \
	  $(if $(filter vcs,$(SIMULATOR)),--vcs-install-dir $(VCS_INSTALL_DIR) --vcs-simlib-dir $(VCS_SIMLIB_DIR) --vcs-gcc-dir $(VCS_GCC_INSTALL_DIR)) \
	  $(if $(DEBUG),--debug $(DEBUG)) \
	  $(foreach sp,$(SP_FLAGS),--sp $(sp))
	@echo "--- vitis.gen.ini ---"
	@cat $@

# ---- gen XO -----------------------------------------------------------------
# TOOL_DIR exports are needed by package_kernel_min.tcl (for parse_vcs_list).
xo: $(XO_CONTAINER)

$(XO_CONTAINER): $(SOURCES_TXT) $(RTL_DIR)/vortex_afu.sv $(RTL_DIR)/vcs_fsdb_init.sv $(SYN_DIR)/gen_xo_min.tcl $(SYN_DIR)/package_kernel_min.tcl $(SCRIPT_DIR)/parse_vcs_list.tcl
	@mkdir -p $(BIN_DIR)
	cd $(BUILD_DIR); \
	  TOOL_DIR=$(SCRIPT_DIR) FORCE_FSDB_PACKAGE=$(FORCE_FSDB) \
	  $(VIVADO) -mode batch -nojournal -log vivado_gen_xo.log \
	    -source $(SYN_DIR)/gen_xo_min.tcl \
	    -tclargs $(XO_CONTAINER) vortex_afu $(SOURCES_TXT) $(BUILD_DIR) $(DEVICE_PART)

# ---- check XO contents ------------------------------------------------------
check-xo:
	@echo "=== packaged_kernel/src/ ==="
	@ls -la $(BUILD_DIR)/xo/packaged_kernel/src/ 2>&1 | grep -i "fsdb\|vortex_afu" || echo "(no matches)"
	@echo ""
	@echo "=== component.xml: vcs_fsdb_init in a file group? ==="
	@grep -c "vcs_fsdb_init" $(BUILD_DIR)/xo/packaged_kernel/component.xml 2>/dev/null || echo "0 (NOT in component.xml)"
	@echo ""
	@echo "=== IP_Flow 19-3833 drops mentioning vcs_fsdb ==="
	@grep -i "19-3833.*vcs_fsdb\|vcs_fsdb.*Unreferenced" $(BUILD_DIR)/vivado_gen_xo.log 2>&1 || echo "(no vcs_fsdb drop warnings)"

# ---- XCLBIN via v++ --link --------------------------------------------------
xclbin: $(XCLBIN_CONTAINER)

VPP_FLAGS := --link --target $(TARGET) --platform $(PLATFORM) --save-temps --no_ip_cache
VPP_FLAGS += --config $(VITIS_INI)
VPP_FLAGS += -g --optimize 0
VPP_ENV := PATH=$(VCS_INSTALL_DIR):$$PATH VG_GNU_PACKAGE=$(VG_GNU_PACKAGE) VCS_ARCH_OVERRIDE=linux

$(XCLBIN_CONTAINER): $(XO_CONTAINER) $(VITIS_INI)
	mkdir -p $(BIN_DIR); cd $(BUILD_DIR); \
	  $(VPP_ENV) $(VPP) $(VPP_FLAGS) -o $@ $(XO_CONTAINER)

# ---- emconfig ---------------------------------------------------------------
emconfig: $(BIN_DIR)/emconfig.json
$(BIN_DIR)/emconfig.json:
	mkdir -p $(BIN_DIR); cd $(BUILD_DIR); emconfigutil --platform $(PLATFORM) --od $(BIN_DIR)

# ---- xrt.ini (for simulator selection + FSDB) ------------------------------
$(BIN_DIR)/xrt.ini:
	@mkdir -p $(BIN_DIR)
	@{ echo "[Runtime]"; \
	   echo "runtime_log=./xrt.log"; \
	   echo "verbosity=7"; \
	   echo ""; \
	   echo "[Emulation]"; \
	   echo "debug_mode=batch"; \
	} > $@

# ---- host binary ------------------------------------------------------------
host: $(BIN_DIR)/host
$(BIN_DIR)/host: $(HOST_DIR)/host.cpp
	@mkdir -p $(BIN_DIR)
	g++ -std=c++17 -O2 -o $@ $< \
	  -I$(XILINX_XRT)/include \
	  -L$(XILINX_XRT)/lib -lxrt_coreutil -luuid -lpthread \
	  -Wl,-rpath,$(XILINX_XRT)/lib

# ---- run --------------------------------------------------------------------
all: $(XCLBIN_CONTAINER) $(BIN_DIR)/emconfig.json $(BIN_DIR)/xrt.ini $(BIN_DIR)/host

run: all
	cd $(BIN_DIR); XCL_EMULATION_MODE=hw_emu \
	  PATH=$(VCS_INSTALL_DIR):$$PATH \
	  VG_GNU_PACKAGE=$(VG_GNU_PACKAGE) \
	  VCS_ARCH_OVERRIDE=linux \
	  VERDI_HOME=$(VERDI_HOME) \
	  LD_LIBRARY_PATH=$(VERDI_HOME)/share/PLI/VCS/LINUX64:$(XILINX_VITIS)/lib/lnx64.o:$(XILINX_VIVADO)/lib/lnx64.o:$$LD_LIBRARY_PATH \
	  ./host vortex_afu.xclbin 2>&1 | tail -30
	@echo ""
	@echo "=== checking for FSDB in .run dirs ==="
	@find $(BIN_DIR)/.run -name "*.fsdb" 2>/dev/null | head -5 || echo "(no FSDB found)"

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all xo check-xo xclbin emconfig host run clean
