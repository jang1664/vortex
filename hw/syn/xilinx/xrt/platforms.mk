# Platform specific configurations
# Add your platform specific configurations here

CONFIGS += -DPLATFORM_MEMORY_DATA_SIZE=64

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
  SP_FLAGS += vortex_afu_1.m_axi_mem_0:HBM[0]
  SP_FLAGS += vortex_afu_1.m_axi_mem_0:HBM[8]
  SP_FLAGS += vortex_afu_1.m_axi_mem_0:HBM[16]
  SP_FLAGS += vortex_afu_1.m_axi_mem_0:HBM[24]
  SP_FLAGS += vortex_afu_1.m_axi_mem_1:HBM[1]
  SP_FLAGS += vortex_afu_1.m_axi_mem_1:HBM[9]
  SP_FLAGS += vortex_afu_1.m_axi_mem_1:HBM[17]
  SP_FLAGS += vortex_afu_1.m_axi_mem_1:HBM[25]
  SP_FLAGS += vortex_afu_1.m_axi_mem_2:HBM[2]
  SP_FLAGS += vortex_afu_1.m_axi_mem_2:HBM[10]
  SP_FLAGS += vortex_afu_1.m_axi_mem_2:HBM[18]
  SP_FLAGS += vortex_afu_1.m_axi_mem_2:HBM[26]
  SP_FLAGS += vortex_afu_1.m_axi_mem_3:HBM[3]
  SP_FLAGS += vortex_afu_1.m_axi_mem_3:HBM[11]
  SP_FLAGS += vortex_afu_1.m_axi_mem_3:HBM[19]
  SP_FLAGS += vortex_afu_1.m_axi_mem_3:HBM[27]
  SP_FLAGS += vortex_afu_1.m_axi_mem_4:HBM[4]
  SP_FLAGS += vortex_afu_1.m_axi_mem_4:HBM[12]
  SP_FLAGS += vortex_afu_1.m_axi_mem_4:HBM[20]
  SP_FLAGS += vortex_afu_1.m_axi_mem_4:HBM[28]
  SP_FLAGS += vortex_afu_1.m_axi_mem_5:HBM[5]
  SP_FLAGS += vortex_afu_1.m_axi_mem_5:HBM[13]
  SP_FLAGS += vortex_afu_1.m_axi_mem_5:HBM[21]
  SP_FLAGS += vortex_afu_1.m_axi_mem_5:HBM[29]
  SP_FLAGS += vortex_afu_1.m_axi_mem_6:HBM[6]
  SP_FLAGS += vortex_afu_1.m_axi_mem_6:HBM[14]
  SP_FLAGS += vortex_afu_1.m_axi_mem_6:HBM[22]
  SP_FLAGS += vortex_afu_1.m_axi_mem_6:HBM[30]
  SP_FLAGS += vortex_afu_1.m_axi_mem_7:HBM[7]
  SP_FLAGS += vortex_afu_1.m_axi_mem_7:HBM[15]
  SP_FLAGS += vortex_afu_1.m_axi_mem_7:HBM[23]
  SP_FLAGS += vortex_afu_1.m_axi_mem_7:HBM[31]
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
