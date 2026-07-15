#!/bin/bash
(
  cd $PROJ_HOME
  NUM_THREADS=16 \
  SYN_RUN_NAME=Vortex_axi_nt16 \
  SYN_RESULT_ROOT=$PWD/build/hw/syn/synopsys \
  python3 hw/syn/synopsys/run_syn_vortex_axi.py |& tee build/hw/syn/synopsys/Vortex_axi_nt16.run.log
)