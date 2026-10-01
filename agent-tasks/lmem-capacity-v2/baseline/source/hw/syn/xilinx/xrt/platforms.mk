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
  # VX_mem_remap packs bank_idx = port * (32 / NUM_HBM_PORTS) + local_bank.
  # Match those contiguous ranges to the actual external AXI port count,
  # independently of NUM_DMA_CHANNELS. Repeated non-contiguous sp lines for
  # the same port are not preserved in the generated HMSS map.
  # The shared extractor preserves malformed/duplicate values for rejection
  # and defaults to 8 only when NUM_HBM_PORTS is absent, as in VX_config.vh.
  U55C_HBM_PORTS := $(call gemm_geometry_value,NUM_HBM_PORTS,8)
ifeq ($(U55C_HBM_PORTS),4)
  SP_FLAGS += vortex_afu_1.m_axi_mem_0:HBM[0:7]
  SP_FLAGS += vortex_afu_1.m_axi_mem_1:HBM[8:15]
  SP_FLAGS += vortex_afu_1.m_axi_mem_2:HBM[16:23]
  SP_FLAGS += vortex_afu_1.m_axi_mem_3:HBM[24:31]
else ifeq ($(U55C_HBM_PORTS),8)
  SP_FLAGS += vortex_afu_1.m_axi_mem_0:HBM[0:3]
  SP_FLAGS += vortex_afu_1.m_axi_mem_1:HBM[4:7]
  SP_FLAGS += vortex_afu_1.m_axi_mem_2:HBM[8:11]
  SP_FLAGS += vortex_afu_1.m_axi_mem_3:HBM[12:15]
  SP_FLAGS += vortex_afu_1.m_axi_mem_4:HBM[16:19]
  SP_FLAGS += vortex_afu_1.m_axi_mem_5:HBM[20:23]
  SP_FLAGS += vortex_afu_1.m_axi_mem_6:HBM[24:27]
  SP_FLAGS += vortex_afu_1.m_axi_mem_7:HBM[28:31]
else
  $(error U55C connectivity requires NUM_HBM_PORTS=4 or 8, got '$(U55C_HBM_PORTS)')
endif
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
