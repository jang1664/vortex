# Controlled Fig. 5 memory-fabric experiment; not a full-system candidate.
# Preserve the original ASIC sweep's widths/capacities and LMEM full-crossbar path. Cache retains this revision's mixed xbar/Omega RTL.
CONFIGS="-DSYNTHESIS -DNDEBUG -DVIVADO -DXLEN_64"
CONFIGS+=" -DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32"
CONFIGS+=" -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MERGED_MEMORY_INTERFACE"
CONFIGS+=" -DNUM_CLUSTERS=1 -DNUM_CORES=1 -DNUM_THREADS=8"
CONFIGS+=" -DLMEM_USE_URAM=0"
export CONFIGS
