# sandbox/vitis_minimal platforms.mk — simplified from Vortex's for U55C with
# a single AXI master (m_axi_mem_0). Keeps only the bindings the stub actually
# wires up.

SP_FLAGS :=
CONFIGS  += -DPLATFORM_MEMORY_DATA_SIZE=64
CONFIGS  += -DPLATFORM_MEMORY_ID_WIDTH=32

ifneq ($(findstring xilinx_u55c,$(XSA)),)
  CONFIGS += -DMEM_ADDR_WIDTH=34
  CONFIGS += -DPLATFORM_MEMORY_NUM_BANKS=32
  CONFIGS += -DPLATFORM_MEMORY_ADDR_WIDTH=34
  SP_FLAGS += vortex_afu_1.m_axi_mem_0:HBM[0:31]
else
  $(error only xilinx_u55c platform wired up in this sandbox)
endif
