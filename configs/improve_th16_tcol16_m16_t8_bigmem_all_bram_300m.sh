# Identical to the 100MHz all-BRAM profile except for the requested clock.
source "$(dirname "${BASH_SOURCE[0]}")/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh"

# The XRT flow's historical CLOCK_FREQ_HZ variable is expressed in MHz.
CLOCK_FREQ_HZ=300
export CLOCK_FREQ_HZ
