# URAM TMEM, full-SLR pipeline/floorplan, and SLL-aware placement.
source "$(dirname "${BASH_SOURCE[0]}")/improve_th32_tcol32_m32_bigmem_hbm4_tmem8.sh"

CONFIGS+=" -DTMEM_USE_URAM=1"
PLACE_DESIGN_DIRECTIVE=SSI_SpreadSLLs
FAST_MODE=0
CONGESTION_FAIL_FAST=0

export CONFIGS PLACE_DESIGN_DIRECTIVE FAST_MODE CONGESTION_FAIL_FAST
