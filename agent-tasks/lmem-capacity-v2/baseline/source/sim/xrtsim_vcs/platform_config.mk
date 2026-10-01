# Always read authoritative source files, not stale configure-generated copies.
U55C_PLATFORM_DIR := $(VORTEX_HOME)/hw/syn/xilinx/xrt
XRT_VCS_PLATFORM ?= xilinx_u55c
XSA := $(XRT_VCS_PLATFORM)
DEV_ARCH := alveo
ifeq ($(findstring xilinx_u55c,$(XSA)),)
$(error xrt-vcs-sim HBM model requires an explicit xilinx_u55c platform identity)
endif

# Capture command-line CONFIGS before evaluating the shared additive platform file.
XRT_VCS_USER_CONFIGS := $(CONFIGS)
override undefine CONFIGS
CONFIGS := $(XRT_VCS_USER_CONFIGS)
include $(U55C_PLATFORM_DIR)/geometry.mk
include $(U55C_PLATFORM_DIR)/platforms.mk
XRT_VCS_EFFECTIVE_CONFIGS := $(CONFIGS)
CONFIGS := $(sort $(CONFIGS))

LOGIC_FREQ_HZ ?= 100000000
HBM_AXI_FREQ_HZ ?= 300000000

# Export data as environment values, avoiding shell interpolation of HDL literals.
export U55C_INPUT_DEFINES := $(XRT_VCS_USER_CONFIGS)
export U55C_EFFECTIVE_DEFINES := $(XRT_VCS_EFFECTIVE_CONFIGS)
export U55C_SP_FLAGS := $(SP_FLAGS)
export U55C_PLATFORM := $(XSA)
export U55C_LOGIC_FREQ_HZ := $(LOGIC_FREQ_HZ)
export U55C_HBM_AXI_FREQ_HZ := $(HBM_AXI_FREQ_HZ)
export U55C_PLATFORM_DIR

.PHONY: hbm-config hbm-config-force
hbm-config: $(DESTDIR)/u55c_model_config.h

# The generator compares contents before replacing files; configuration changes
# rebuild consumers, while identical invocations preserve their timestamps.
$(DESTDIR)/u55c_model_config.h: hbm-config-force $(SRC_DIR)/gen_hbm_config.py $(SRC_DIR)/platform_config.mk $(U55C_PLATFORM_DIR)/platforms.mk $(U55C_PLATFORM_DIR)/geometry.mk
	python3 $(SRC_DIR)/gen_hbm_config.py --output-dir $(DESTDIR)

$(DESTDIR)/u55c_model_config.svh $(DESTDIR)/u55c_model_manifest.json: $(DESTDIR)/u55c_model_config.h
	@test -f $@ || python3 $(SRC_DIR)/gen_hbm_config.py --output-dir $(DESTDIR)
