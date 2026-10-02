#!/bin/bash
set -e
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build
ci/run_black.sh hw --fpga-bin tcu_th16_c1_v2_rev2 --app eladd --args '-n 4096'
