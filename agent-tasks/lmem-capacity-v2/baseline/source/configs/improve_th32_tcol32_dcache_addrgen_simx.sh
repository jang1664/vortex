# TH32 simx configuration for the fused softmax address-generator experiment.
# Keep this separate from the fixed rev2 baseline configuration so baseline
# measurements can also be repeated without the optional extension compiled in.
source configs/improve_th32_tcol32_dcache_simx.sh
CONFIGS+=" -DEXT_ADDR_GEN_ENABLE"
export CONFIGS
