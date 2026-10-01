# OOC experiment: preserve deployed candidate defines; add FPGA build defines.
source "$(dirname "${BASH_SOURCE[0]}")/tcu_th16_c1.sh"
CONFIGS+=" -DSYNTHESIS -DNDEBUG -DXLEN_64 -DTCU_DSP -DPLATFORM_MEMORY_DATA_SIZE=64 -DPLATFORM_MEMORY_ID_WIDTH=32 -DPLATFORM_MERGED_MEMORY_INTERFACE"
export CONFIGS
