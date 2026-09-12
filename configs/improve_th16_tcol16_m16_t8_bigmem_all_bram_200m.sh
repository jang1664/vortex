# Same all-BRAM profile, with a 200 MHz frequency-exploration target.
source "$(dirname "${BASH_SOURCE[0]}")/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh"

# The historical CLOCK_FREQ_HZ variable is expressed in MHz.
CLOCK_FREQ_HZ=200
export CLOCK_FREQ_HZ
