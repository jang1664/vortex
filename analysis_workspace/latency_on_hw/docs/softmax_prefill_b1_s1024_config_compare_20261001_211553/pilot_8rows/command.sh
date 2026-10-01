set -e
source /tmp/vortex_softmax_compare_j_ndwifz/source/configs/tcu_th16_c1_v2.sh
ci/run_black.sh xrt-vcs-sim --app softmax --args '-batch 1 -heads 1 -seqq 8 -seqk 1024 -seqk-stride 1024 -mask 0'
