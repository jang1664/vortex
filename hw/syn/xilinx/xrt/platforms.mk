# Platform specific configurations
# Add your platform specific configurations here

CONFIGS += -DPLATFORM_MEMORY_DATA_SIZE=64
# Mirror the vortex_afu.vh default so modules that reference the macro (e.g.
# VX_dma_engine's AXI_ID_WIDTH default) get the macro expanded by Verilator
# preprocessing. vortex_afu.vh wraps the define in `ifndef`, so this is safe.
CONFIGS += -DPLATFORM_MEMORY_ID_WIDTH=32

# SP_FLAGS collects memory connectivity specs for gen_vitis_ini.sh
SP_FLAGS :=

ifeq ($(DEV_ARCH), zynquplus)
# zynquplus
CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=1 -DPLATFORM_MEMORY_ADDR_WIDTH=32
else ifeq ($(DEV_ARCH), versal)
# versal
CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=1 -DPLATFORM_MEMORY_ADDR_WIDTH=32
ifneq ($(findstring xilinx_vck5000,$(XSA)),)
	CONFIGS += -DPLATFORM_MEMORY_OFFSET=40'hC000000000
endif
else
# alveo
ifneq ($(findstring xilinx_u55c,$(XSA)),)
  # 16 GB of HBM2 with 32 channels (512 MB per channel)
  # Keep core/global address width aligned with physical HBM aperture.
  CONFIGS += -DMEM_ADDR_WIDTH=34
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MEMORY_ADDR_WIDTH=34
  CONFIGS += -DPLATFORM_MERGED_MEMORY_INTERFACE
  # Each top-level AXI port can emit addresses across the full U55C HBM
  # aperture. Use one contiguous HBM range per port; repeated non-contiguous
  # sp lines for the same port are not preserved in the generated HMSS map.
  SP_FLAGS += vortex_afu_1.m_axi_mem_0:HBM[0:31]
  SP_FLAGS += vortex_afu_1.m_axi_mem_1:HBM[0:31]
  SP_FLAGS += vortex_afu_1.m_axi_mem_2:HBM[0:31]
  SP_FLAGS += vortex_afu_1.m_axi_mem_3:HBM[0:31]
  SP_FLAGS += vortex_afu_1.m_axi_mem_4:HBM[0:31]
  SP_FLAGS += vortex_afu_1.m_axi_mem_5:HBM[0:31]
  SP_FLAGS += vortex_afu_1.m_axi_mem_6:HBM[0:31]
  SP_FLAGS += vortex_afu_1.m_axi_mem_7:HBM[0:31]
else ifneq ($(findstring xilinx_u50,$(XSA)),)
  # 8 GB of HBM2 with 32 channels (256 MB per channel)
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MEMORY_ADDR_WIDTH=33
  SP_FLAGS += vortex_afu_1.m_axi_mem_0:HBM[0:31]
else ifneq ($(findstring xilinx_u280,$(XSA)),)
  # 8 GB of HBM2 with 32 channels (256 MB per channel)
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MEMORY_ADDR_WIDTH=33
  SP_FLAGS += vortex_afu_1.m_axi_mem_0:HBM[0:31]
else ifneq ($(findstring xilinx_u250,$(XSA)),)
  # 64 GB of DDR4 with 4 channels (16 GB per channel)
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=4 -DPLATFORM_MEMORY_ADDR_WIDTH=36
else ifneq ($(findstring xilinx_u200,$(XSA)),)
  # 64 GB of DDR4 with 4 channels (16 GB per channel)
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=4 -DPLATFORM_MEMORY_ADDR_WIDTH=36
else
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=1 -DPLATFORM_MEMORY_ADDR_WIDTH=32
endif
endif
